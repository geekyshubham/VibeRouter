package cliproxy

import (
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/registry"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/util"
	coreauth "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/auth"
	"github.com/router-for-me/CLIProxyAPI/v7/sdk/config"
)

func TestRegisterModelsForAuthCodexSol(t *testing.T) {
	const modelID = "gpt-6.1-sol"
	for _, plan := range []string{"free", "team", "business", "go", "plus", "pro", ""} {
		t.Run(plan, func(t *testing.T) {
			service := &Service{cfg: &config.Config{}}
			auth := &coreauth.Auth{
				ID: "test-codex-sol-" + plan, Provider: "codex", Status: coreauth.StatusActive,
				Attributes: map[string]string{"auth_kind": "oauth", "plan_type": plan},
			}
			r := registry.GetGlobalRegistry()
			t.Cleanup(func() { r.UnregisterClient(auth.ID) })
			service.registerModelsForAuth(auth)
			providers := util.GetProviderName(modelID)
			if len(providers) != 1 || providers[0] != "codex" {
				t.Fatalf("model providers = %v, want [codex]", providers)
			}
			info := r.GetModelInfo(modelID, "codex")
			if info == nil || info.ContextLength != 272000 || info.Thinking == nil {
				t.Fatalf("missing Codex Sol metadata: %+v", info)
			}
			// Re-registration after a catalog refresh must retain the built-in.
			service.registerModelsForAuth(auth)
			count := 0
			for _, model := range r.GetModelsForClient(auth.ID) {
				if model.ID == modelID {
					count++
				}
			}
			if count != 1 {
				t.Fatalf("registered Sol models = %d, want 1", count)
			}
			auth.Attributes["excluded_models"] = modelID
			service.registerModelsForAuth(auth)
			if providers := util.GetProviderName(modelID); len(providers) != 0 {
				t.Fatalf("excluded model still routes to %v", providers)
			}
		})
	}
}
