package auth

import (
	"context"
	"fmt"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/registry"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/executor"
)

// All Go-backed providers use this manager. Cover HTTP billing/rate-limit
// errors and stream bootstrap errors without making live provider requests.
func TestProviderAccountsFailOverWithoutLosingConversation(t *testing.T) {
	for _, provider := range []string{"codex", "claude", "gemini", "antigravity", "xai", "openai-compatibility"} {
		for _, status := range []int{401, 402, 403, 429, 503} {
			for _, mode := range []string{"plain", "stream-http", "stream-bootstrap"} {
				t.Run(fmt.Sprintf("%s/%d/%s", provider, status, mode), func(t *testing.T) {
					manager := NewManager(nil, &FillFirstSelector{}, nil)
					manager.SetRetryConfig(0, 0, 0)
					prefix := uuid.NewString()
					ids := []string{prefix + "-a", prefix + "-b", prefix + "-c", prefix + "-disabled"}
					model := "provider-failover-" + prefix
					payload := []byte(`{"messages":[{"role":"user","content":"Continue the same project"}],"tools":[{"name":"Read","input_schema":{"type":"object"}}]}`)
					failure := &retryAfterStatusError{status: status, message: "account unavailable", retryAfter: time.Hour}
					executor := &codexContinuityExecutor{
						authFallbackExecutor: authFallbackExecutor{
							id: provider, executeErrors: map[string]error{ids[0]: failure, ids[1]: failure},
							streamFirstErrors: map[string]error{ids[0]: failure, ids[1]: failure},
						}, t: t, payload: payload, httpStream429: mode == "stream-http",
					}
					manager.RegisterExecutor(executor)
					reg := registry.GetGlobalRegistry()
					for i, id := range ids {
						reg.RegisterClient(id, provider, []*registry.ModelInfo{{ID: model}})
						t.Cleanup(func() { reg.UnregisterClient(id) })
						if _, err := manager.Register(context.Background(), &Auth{ID: id, Provider: provider, Status: StatusActive, Disabled: i == 3}); err != nil {
							t.Fatal(err)
						}
					}
					ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
					defer cancel()
					req := cliproxyexecutor.Request{Model: model, Payload: payload}
					opts := cliproxyexecutor.Options{OriginalRequest: payload, Headers: http.Header{"X-Session-Id": {"same-claude-code-session"}}}
					for turn := 0; turn < 2; turn++ {
						var response []byte
						if mode == "plain" {
							result, err := manager.Execute(ctx, []string{provider}, req, opts)
							if err != nil {
								t.Fatal(err)
							}
							response = result.Payload
						} else {
							result, err := manager.ExecuteStream(ctx, []string{provider}, req, opts)
							if err != nil {
								t.Fatal(err)
							}
							for chunk := range result.Chunks {
								if chunk.Err != nil {
									t.Fatal(chunk.Err)
								}
								response = append(response, chunk.Payload...)
							}
						}
						if string(response) != ids[2] {
							t.Fatalf("turn %d: got %q, want %s", turn, response, ids[2])
						}
					}
					calls := executor.ExecuteCalls()
					if mode != "plain" {
						calls = executor.StreamCalls()
					}
					if want := []string{ids[0], ids[1], ids[2], ids[2]}; !reflect.DeepEqual(calls, want) {
						t.Fatalf("failover/cooldown calls = %v, want %v", calls, want)
					}
				})
			}
		}
	}
}
