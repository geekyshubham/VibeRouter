package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestConfig(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func TestSaveConfigPreserveCommentsSyncsRoutingPolicy(t *testing.T) {
	base := `# proxy config
routing:
  strategy: "fill-first"
  model-priority:
    - gemini-3-flash
    - claude-haiku-4-5-20251001
  disabled-models:
    - gemini-3-flash
  model-failover: true
api-keys: []
`
	path := writeTestConfig(t, base)

	// 1) Empty the priority list — must not leave stale entries on disk.
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	cfg.Routing.ModelPriority = []string{}
	if err := SaveConfigPreserveComments(path, cfg); err != nil {
		t.Fatalf("save: %v", err)
	}
	saved, _ := os.ReadFile(path)
	if strings.Contains(string(saved), "gemini-3-flash") && !strings.Contains(string(saved), "disabled-models") {
		t.Fatalf("cleared model-priority must not keep stale entries:\n%s", saved)
	}
	if strings.Contains(string(saved), "claude-haiku-4-5-20251001") {
		t.Fatalf("cleared model-priority still contains old entry:\n%s", saved)
	}

	// Reload: the cleared list must round-trip.
	cfg2, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if len(cfg2.Routing.ModelPriority) != 0 {
		t.Fatalf("expected empty priority after reload, got %v", cfg2.Routing.ModelPriority)
	}
	if len(cfg2.Routing.DisabledModels) != 1 || cfg2.Routing.DisabledModels[0] != "gemini-3-flash" {
		t.Fatalf("disabled-models must survive unrelated saves, got %v", cfg2.Routing.DisabledModels)
	}
	if !cfg2.Routing.ModelFailover {
		t.Fatal("model-failover=true must survive unrelated saves")
	}

	// 2) Flip model-failover back to false — the stale true must not persist.
	cfg2.Routing.ModelFailover = false
	cfg2.Routing.DisabledModels = nil
	if err := SaveConfigPreserveComments(path, cfg2); err != nil {
		t.Fatalf("save 2: %v", err)
	}
	cfg3, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("reload 2: %v", err)
	}
	if cfg3.Routing.ModelFailover {
		t.Fatalf("model-failover=false must persist, file:\n%s", func() string { b, _ := os.ReadFile(path); return string(b) }())
	}
	if len(cfg3.Routing.DisabledModels) != 0 {
		t.Fatalf("cleared disabled-models must persist, got %v", cfg3.Routing.DisabledModels)
	}

	// 3) Comments on unrelated keys survive.
	saved2, _ := os.ReadFile(path)
	if !strings.Contains(string(saved2), "# proxy config") || !strings.Contains(string(saved2), `strategy: "fill-first"`) {
		t.Fatalf("comments/strategy must be preserved:\n%s", saved2)
	}
}

func TestSaveConfigPreserveCommentsKeepsSetPriority(t *testing.T) {
	base := `routing:
  strategy: "fill-first"
`
	path := writeTestConfig(t, base)

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	cfg.Routing.ModelPriority = []string{"gpt-5.5", "claude-sonnet-4-20250514"}
	cfg.Routing.ModelFailover = true
	if err := SaveConfigPreserveComments(path, cfg); err != nil {
		t.Fatalf("save: %v", err)
	}

	reloaded, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if len(reloaded.Routing.ModelPriority) != 2 || reloaded.Routing.ModelPriority[0] != "gpt-5.5" {
		t.Fatalf("priority must persist, got %v", reloaded.Routing.ModelPriority)
	}
	if !reloaded.Routing.ModelFailover {
		t.Fatal("failover must persist")
	}
}
