package auth

import (
	"bytes"
	"context"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/registry"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/executor"
)

// Exercise the same manager used for Claude Code's translated Codex requests.
// Only the upstream response is simulated; account selection, cooldowns and
// stream bootstrap recovery use the production implementations.
type codexContinuityExecutor struct {
	authFallbackExecutor
	t             *testing.T
	payload       []byte
	httpStream429 bool
}

func (e *codexContinuityExecutor) checkRequest(req cliproxyexecutor.Request, opts cliproxyexecutor.Options) {
	e.t.Helper()
	if !bytes.Equal(req.Payload, e.payload) || !bytes.Equal(opts.OriginalRequest, e.payload) {
		e.t.Fatal("account switch changed conversation history or tools")
	}
	if opts.Headers.Get("X-Session-ID") != "same-claude-code-session" {
		e.t.Fatal("account switch lost session identity")
	}
}

func (e *codexContinuityExecutor) Execute(ctx context.Context, a *Auth, req cliproxyexecutor.Request, opts cliproxyexecutor.Options) (cliproxyexecutor.Response, error) {
	e.checkRequest(req, opts)
	return e.authFallbackExecutor.Execute(ctx, a, req, opts)
}

func (e *codexContinuityExecutor) ExecuteStream(ctx context.Context, a *Auth, req cliproxyexecutor.Request, opts cliproxyexecutor.Options) (*cliproxyexecutor.StreamResult, error) {
	e.checkRequest(req, opts)
	if e.httpStream429 {
		if err := e.streamFirstErrors[a.ID]; err != nil {
			e.mu.Lock()
			e.streamCalls = append(e.streamCalls, a.ID)
			e.mu.Unlock()
			return nil, err
		}
	}
	return e.authFallbackExecutor.ExecuteStream(ctx, a, req, opts)
}

func TestCodexThreeAccountsContinueSameSessionAfterRateLimits(t *testing.T) {
	for _, mode := range []string{"non-streaming", "streaming-http-429", "streaming-bootstrap-429"} {
		t.Run(mode, func(t *testing.T) {
			m := NewManager(nil, &FillFirstSelector{}, nil)
			// Zero credential cap means every available account is tried. The
			// account switch must succeed even with cooldown retries disabled.
			m.SetRetryConfig(0, 0, 0)
			prefix := uuid.NewString()
			ids := []string{prefix + "-a", prefix + "-b", prefix + "-c"}
			model := "gpt-test-three-account-failover-" + prefix
			payload := []byte(`{"messages":[{"role":"user","content":"Continue fixing the project"},{"role":"assistant","content":[{"type":"tool_use","id":"call-1","name":"Read","input":{"file_path":"app.swift"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-1","content":"file contents"}]}],"tools":[{"name":"Read","input_schema":{"type":"object"}}]}`)
			rateLimit := &retryAfterStatusError{status: http.StatusTooManyRequests, message: "usage_limit_reached", retryAfter: time.Hour}
			e := &codexContinuityExecutor{
				authFallbackExecutor: authFallbackExecutor{
					id: "codex", executeErrors: map[string]error{ids[0]: rateLimit, ids[1]: rateLimit},
					streamFirstErrors: map[string]error{ids[0]: rateLimit, ids[1]: rateLimit},
				},
				t: t, payload: payload, httpStream429: mode == "streaming-http-429",
			}
			m.RegisterExecutor(e)
			reg := registry.GetGlobalRegistry()
			for _, id := range ids {
				reg.RegisterClient(id, "codex", []*registry.ModelInfo{{ID: model, OwnedBy: "openai"}})
				t.Cleanup(func() { reg.UnregisterClient(id) })
				if _, err := m.Register(context.Background(), &Auth{ID: id, Provider: "codex", Status: StatusActive}); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			req := cliproxyexecutor.Request{Model: model, Payload: payload}
			opts := cliproxyexecutor.Options{OriginalRequest: payload, Headers: http.Header{"X-Session-Id": {"same-claude-code-session"}}}
			for turn := 0; turn < 2; turn++ {
				var response []byte
				if mode == "non-streaming" {
					result, err := m.Execute(ctx, []string{"codex"}, req, opts)
					if err != nil {
						t.Fatal(err)
					}
					response = result.Payload
				} else {
					result, err := m.ExecuteStream(ctx, []string{"codex"}, req, opts)
					if err != nil {
						t.Fatal(err)
					}
					for chunk := range result.Chunks {
						if chunk.Err != nil {
							t.Fatalf("rate limit escaped to Claude Code: %v", chunk.Err)
						}
						response = append(response, chunk.Payload...)
					}
				}
				if string(response) != ids[2] {
					t.Fatalf("turn %d: expected third account, got %q", turn, response)
				}
			}
			calls := e.ExecuteCalls()
			if mode != "non-streaming" {
				calls = e.StreamCalls()
			}
			if want := []string{ids[0], ids[1], ids[2], ids[2]}; !reflect.DeepEqual(calls, want) {
				t.Fatalf("account rotation or cooldown incorrect: got %v, want %v", calls, want)
			}
			for _, id := range ids[:2] {
				a, ok := m.GetByID(id)
				if !ok || a.ModelStates[model] == nil || !a.ModelStates[model].Quota.Exceeded || !a.ModelStates[model].NextRetryAfter.After(time.Now()) {
					t.Fatalf("rate-limited account %q was not cooled down", id)
				}
			}
		})
	}
}
