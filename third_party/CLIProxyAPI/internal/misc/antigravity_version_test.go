package misc

import (
	"testing"
	"time"
)

func TestAntigravityUserAgentUsesHubFamily(t *testing.T) {
	antigravityVersionMu.Lock()
	prevVersion, prevExpiry := cachedAntigravityVersion, antigravityVersionExpiry
	cachedAntigravityVersion = antigravityFallbackVersion
	antigravityVersionExpiry = time.Now().Add(time.Hour)
	antigravityVersionMu.Unlock()
	t.Cleanup(func() {
		antigravityVersionMu.Lock()
		cachedAntigravityVersion, antigravityVersionExpiry = prevVersion, prevExpiry
		antigravityVersionMu.Unlock()
	})

	got := AntigravityUserAgent()
	want := "antigravity/hub/" + antigravityFallbackVersion + " " + antigravityHubPlatform
	if got != want {
		t.Fatalf("AntigravityUserAgent() = %q, want %q", got, want)
	}
	if version := AntigravityVersionFromUserAgent(got); version != antigravityFallbackVersion {
		t.Fatalf("version = %q, want %q", version, antigravityFallbackVersion)
	}
}

func TestAntigravitySemVersion(t *testing.T) {
	if !isValidAntigravitySemVersion("2.17.0") {
		t.Fatal("expected 2.17.0 to be valid")
	}
	if isValidAntigravitySemVersion("2.0") || isValidAntigravitySemVersion("hub/2.17.0") {
		t.Fatal("expected incomplete versions to be rejected")
	}
}
