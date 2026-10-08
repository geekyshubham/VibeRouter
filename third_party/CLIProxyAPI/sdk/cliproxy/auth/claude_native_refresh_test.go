package auth

import (
	"testing"
	"time"
)

func TestClaudeNativeAccessOnlyIsNotScheduledForRefresh(t *testing.T) {
	now := time.Now()
	lead := 15 * time.Minute
	setRefreshLeadFactory(t, "claude", func() *time.Duration { return &lead })
	for _, token := range []any{nil, "", "  "} {
		a := &Auth{ID: "native-claude", Provider: "claude", Metadata: map[string]any{
			"expired": now.Add(-time.Minute).Format(time.RFC3339), "refresh_token": token,
		}}
		if _, scheduled := nextRefreshCheckAt(now, a, time.Minute); scheduled {
			t.Fatal("access-token-only Claude session must be refreshed by native Claude Code")
		}
	}
	a := &Auth{ID: "independent-claude", Provider: "claude", Metadata: map[string]any{
		"expired": now.Add(-time.Minute).Format(time.RFC3339), "refresh_token": "independent-rt",
	}}
	if _, scheduled := nextRefreshCheckAt(now, a, time.Minute); !scheduled {
		t.Fatal("independently authenticated Claude account must still be refreshable")
	}
}
