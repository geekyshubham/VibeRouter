package executor

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/config"
	cliproxyauth "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/auth"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/executor"
	sdktranslator "github.com/router-for-me/CLIProxyAPI/v7/sdk/translator"
)

func TestClaudeProtocolPassthroughPreservesSafetyContextAndVerdicts(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "json", true: "stream"}[stream], func(t *testing.T) {
			payload := []byte(`{"model":"claude-sonnet-4-6","max_tokens":64,"system":[{"type":"text","text":"x-anthropic-billing-header: keep-original;","cache_control":{"type":"ephemeral","ttl":"1h"}}],"tools":[{"name":"shell_exec","input_schema":{"type":"object"}}],"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_keep","name":"shell_exec","input":{"command":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_keep","content":"/fixture","cache_control":{"type":"ephemeral"}}]}],"safeguards":[{"type":"dangerous_tool_use","context":{"rules":{"deny":[]},"future_context":true}}],"future_field":{"preserve":true}}`)
			verdict := `{"type":"dangerous_tool_use","status":{"type":"available","tool_uses":{"toolu_keep":{"type":"evaluated","outcome":"allowed"}}}}`
			response := []byte(`{"id":"msg_keep","type":"message","role":"assistant","content":[],"safeguard_results":[` + verdict + `],"future_response":true,"usage":{"input_tokens":1,"output_tokens":1}}`)
			if stream {
				response = []byte("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_keep\",\"content\":[],\"usage\":{\"input_tokens\":1}}}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_keep\",\"name\":\"shell_exec\",\"input\":{}}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"safeguard_results\":[" + verdict + "],\"future_event\":true,\"usage\":{\"output_tokens\":1}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
			}
			incoming := http.Header{
				"User-Agent":        {"claude-cli/2.1.295 (external, cli)"},
				"Anthropic-Beta":    {"dangerous-tool-use-test,future-feature-test,oauth-2025-04-20"},
				"Anthropic-Version": {"2023-06-01"}, "Anthropic-Future-Header": {"preserve"},
				"X-Claude-Code-Prompt-Id": {"prompt_keep"}, "X-Claude-Code-Future-Hint": {"new"},
				"Authorization": {"Bearer gateway-only-secret"}, "X-Api-Key": {"gateway-only-secret"},
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				if !bytes.Equal(body, payload) {
					t.Errorf("native body was modified:\n%s", body)
				}
				for _, name := range []string{"Anthropic-Beta", "Anthropic-Version", "Anthropic-Future-Header", "X-Claude-Code-Prompt-Id", "X-Claude-Code-Future-Hint"} {
					if r.Header.Get(name) != incoming.Get(name) {
						t.Errorf("%s was changed", name)
					}
				}
				if r.Header.Get("Authorization") != "Bearer sk-ant-oat-fixture" || r.Header.Get("X-Api-Key") != "" {
					t.Error("gateway credential leaked or upstream credential was lost")
				}
				w.Header().Set("Anthropic-Ratelimit-Unified-5h-Utilization", "0.25")
				w.Header().Set("Retry-After", "60")
				w.Header().Set("Content-Type", map[bool]string{false: "application/json", true: "text/event-stream"}[stream])
				_, _ = w.Write(response)
			}))
			defer server.Close()
			gin.SetMode(gin.TestMode)
			gc, _ := gin.CreateTestContext(httptest.NewRecorder())
			gc.Request = httptest.NewRequest("POST", "/v1/messages?beta=true", bytes.NewReader(payload))
			gc.Request.Header = incoming
			ctx := context.WithValue(context.Background(), "gin", gc)
			auth := &cliproxyauth.Auth{Attributes: map[string]string{"base_url": server.URL}, Metadata: map[string]any{"access_token": "sk-ant-oat-fixture"}}
			exec := NewClaudeExecutor(&config.Config{})
			request := cliproxyexecutor.Request{Model: "claude-sonnet-4-6", Payload: payload}
			opts := cliproxyexecutor.Options{SourceFormat: sdktranslator.FromString("claude")}
			var result []byte
			var headers http.Header
			if stream {
				out, err := exec.ExecuteStream(ctx, auth, request, opts)
				if err != nil {
					t.Fatal(err)
				}
				headers = out.Headers
				for chunk := range out.Chunks {
					if chunk.Err != nil {
						t.Fatal(chunk.Err)
					}
					result = append(result, chunk.Payload...)
				}
			} else {
				out, err := exec.Execute(ctx, auth, request, opts)
				if err != nil {
					t.Fatal(err)
				}
				result, headers = out.Payload, out.Headers
			}
			if !bytes.Equal(result, response) {
				t.Errorf("verdict/events changed:\n%s", result)
			}
			if headers.Get("Anthropic-Ratelimit-Unified-5h-Utilization") != "0.25" || headers.Get("Retry-After") != "60" {
				t.Error("upstream headers lost")
			}
		})
	}
}

func TestClaudeProtocolPassthroughRecognizesFutureNativeRequests(t *testing.T) {
	request := newClaudeHeaderTestRequest(t, http.Header{"User-Agent": {"claude-cli/2.1.295"}})
	if !preserveClaudeProtocol(request.Context(), []byte(`{"future_field":true}`)) {
		t.Fatal("native future fields must pass through")
	}
	if !preserveClaudeProtocol(context.Background(), []byte(`{"safeguards":[]}`)) {
		t.Fatal("safeguards must work for custom clients too")
	}
	if preserveClaudeProtocol(context.Background(), []byte(`{"messages":[]}`)) {
		t.Fatal("legacy adapters should retain their normal transforms")
	}
}
