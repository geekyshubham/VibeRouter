package executor

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/config"
	cliproxyauth "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/auth"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/executor"
	sdktranslator "github.com/router-for-me/CLIProxyAPI/v7/sdk/translator"
	"github.com/tidwall/gjson"
)

func TestCodexClaudeCompactionReturnsBeforeUpstreamCloses(t *testing.T) {
	for _, streaming := range []bool{false, true} {
		for _, terminal := range []string{"completed", "incomplete", "failed"} {
			name := terminal
			if streaming {
				name += "-streaming"
			}
			t.Run(name, func(t *testing.T) {
				bodyCh := make(chan []byte, 1)
				release := make(chan struct{})
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					body, _ := io.ReadAll(r.Body)
					bodyCh <- body
					w.Header().Set("Content-Type", "text/event-stream")
					if terminal == "completed" {
						io.WriteString(w, "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Summary retained\"}]}}\n\n")
						io.WriteString(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_compact\",\"model\":\"gpt-6.1-sol\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":250000,\"output_tokens\":20}}}\n\n")
					} else if terminal == "incomplete" {
						io.WriteString(w, "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n")
					} else {
						io.WriteString(w, "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Input too long\"}}}\n\n")
					}
					w.(http.Flusher).Flush()
					// Simulate an SSE connection that remains open after a terminal event.
					select {
					case <-r.Context().Done():
					case <-release:
					}
				}))
				defer server.Close()
				defer close(release)
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				e := NewCodexExecutor(&config.Config{})
				auth := &cliproxyauth.Auth{Attributes: map[string]string{"base_url": server.URL, "api_key": "test"}}
				req := cliproxyexecutor.Request{Model: "gpt-6.1-sol", Payload: []byte(`{"model":"gpt-6.1-sol","thinking":{"type":"adaptive"},"output_config":{"effort":"high"},"messages":[{"role":"user","content":"Summarize the conversation"}]}`)}
				opts := cliproxyexecutor.Options{SourceFormat: sdktranslator.FormatClaude, Stream: streaming, Headers: http.Header{"X-Claude-Code-Request-Class": []string{"compaction"}}}
				var result []byte
				var err error
				if streaming {
					var stream *cliproxyexecutor.StreamResult
					stream, err = e.ExecuteStream(ctx, auth, req, opts)
					if err == nil {
						for chunk := range stream.Chunks {
							if chunk.Err != nil {
								err = chunk.Err
							}
							result = append(result, chunk.Payload...)
						}
					}
				} else {
					var response cliproxyexecutor.Response
					response, err = e.Execute(ctx, auth, req, opts)
					result = response.Payload
				}
				if ctx.Err() != nil {
					t.Fatalf("waited for upstream EOF instead of terminal event: %v", err)
				}
				if terminal == "completed" {
					if err != nil {
						t.Fatal(err)
					}
					if !strings.Contains(string(result), "Summary retained") {
						t.Fatalf("summary missing: %s", result)
					}
					if streaming && !strings.Contains(string(result), "message_stop") {
						t.Fatalf("Claude completion missing: %s", result)
					}
				} else if err == nil {
					t.Fatal("incomplete/failed response reported as success")
				}
				body := <-bodyCh
				if got := gjson.GetBytes(body, "reasoning.effort").String(); got != "low" {
					t.Fatalf("compaction effort = %q", got)
				}
				if got := gjson.GetBytes(body, "text.verbosity").String(); got != "low" {
					t.Fatalf("compaction verbosity = %q", got)
				}
			})
		}
	}
}

func TestCodexIncompleteIsNotAGatewayError(t *testing.T) {
	event := []byte(`{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}`)
	err, _, ok := codexTerminalStreamErr(event)
	if !ok {
		t.Fatal("expected a terminal error")
	}
	if err.StatusCode() >= 500 {
		t.Fatalf("incomplete status = %d, want a non-transient status", err.StatusCode())
	}
}

func TestCodexClaudeCompactionEffortDoesNotChangeCodingRequests(t *testing.T) {
	for _, tc := range []struct {
		source              sdktranslator.Format
		class, effort, want string
	}{
		{sdktranslator.FormatClaude, "compaction", "high", "low"},
		{sdktranslator.FormatClaude, "compaction", "xhigh", "low"},
		{sdktranslator.FormatClaude, "compaction", "medium", "low"},
		{sdktranslator.FormatClaude, "compaction", "none", "none"},
		{sdktranslator.FormatClaude, "compaction", "minimal", "minimal"},
		{sdktranslator.FormatClaude, "compaction", "low", "low"},
		{sdktranslator.FormatClaude, "main", "high", "high"},
		{sdktranslator.FormatClaude, "", "high", "high"},
		{sdktranslator.FromString("openai-response"), "compaction", "high", "high"},
	} {
		body := []byte(`{"reasoning":{"effort":"` + tc.effort + `"},"input":[{"role":"user","content":"Summarize the conversation"}]}`)
		result := applyCodexClaudeCompactionEffort(tc.source, http.Header{"X-Claude-Code-Request-Class": []string{tc.class}}, body)
		if got := gjson.GetBytes(result, "reasoning.effort").String(); got != tc.want {
			t.Fatalf("%s %s %s: got %s, want %s", tc.source, tc.class, tc.effort, got, tc.want)
		}
		if gjson.GetBytes(result, "input").Raw != gjson.GetBytes(body, "input").Raw {
			t.Fatal("conversation changed")
		}
		if gjson.GetBytes(result, "text.verbosity").Exists() {
			t.Fatal("added unsupported verbosity to a model without a GPT-5/6 ID")
		}
	}
}

func TestCodexStreamRejectsEOFWithoutCompletion(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_truncated\"}}\n\n")
	}))
	defer server.Close()
	e := NewCodexExecutor(&config.Config{})
	auth := &cliproxyauth.Auth{Attributes: map[string]string{"base_url": server.URL, "api_key": "test"}}
	stream, err := e.ExecuteStream(context.Background(), auth, cliproxyexecutor.Request{Model: "gpt-6.1-sol", Payload: []byte(`{"input":"hello"}`)}, cliproxyexecutor.Options{SourceFormat: sdktranslator.FromString("openai-response"), Stream: true})
	if err != nil {
		t.Fatal(err)
	}
	var streamErr error
	for chunk := range stream.Chunks {
		if chunk.Err != nil {
			streamErr = chunk.Err
		}
	}
	if streamErr == nil || !strings.Contains(streamErr.Error(), "before response.completed") {
		t.Fatalf("missing interrupted-stream error: %v", streamErr)
	}
}
