package registry

import (
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/modelpolicy"
)

func withPolicy(t *testing.T, priority, disabled []string, failover bool) {
	t.Helper()
	modelpolicy.Sync(priority, disabled, failover)
	t.Cleanup(func() { modelpolicy.Sync(nil, nil, false) })
}

func TestAvailableModelsExcludeDisabled(t *testing.T) {
	withPolicy(t, nil, []string{"m-off"}, false)
	r := newTestModelRegistry()
	r.RegisterClient("client-1", "openai", []*ModelInfo{
		{ID: "m-on", OwnedBy: "openai"},
		{ID: "m-off", OwnedBy: "openai"},
	})
	r.InvalidateAvailableModelsCache()

	models := r.GetAvailableModels("openai")
	ids := make([]string, 0, len(models))
	for _, m := range models {
		if id, ok := m["id"].(string); ok {
			ids = append(ids, id)
		}
	}
	if len(ids) != 1 || ids[0] != "m-on" {
		t.Fatalf("expected only m-on, got %v", ids)
	}

	byProvider := r.GetAvailableModelsByProvider("openai")
	if len(byProvider) != 1 || byProvider[0].ID != "m-on" {
		t.Fatalf("by-provider listing must skip disabled models, got %+v", byProvider)
	}
}

func TestAvailableModelsOrderByPriority(t *testing.T) {
	withPolicy(t, []string{"zeta", "alpha"}, nil, false)
	r := newTestModelRegistry()
	r.RegisterClient("client-1", "openai", []*ModelInfo{
		{ID: "alpha", OwnedBy: "openai"},
		{ID: "zeta", OwnedBy: "openai"},
		{ID: "unlisted", OwnedBy: "openai"},
	})
	r.InvalidateAvailableModelsCache()

	models := r.GetAvailableModels("openai")
	ids := make([]string, 0, len(models))
	for _, m := range models {
		if id, ok := m["id"].(string); ok {
			ids = append(ids, id)
		}
	}
	// Priority-ordered models first (zeta, alpha), unlisted keeps registry order.
	if len(ids) != 3 || ids[0] != "zeta" || ids[1] != "alpha" {
		t.Fatalf("expected [zeta alpha unlisted…], got %v", ids)
	}
}

func TestModelCatalogReflectsPolicy(t *testing.T) {
	withPolicy(t, []string{"m2"}, []string{"m3"}, false)
	r := newTestModelRegistry()
	r.RegisterClient("client-1", "openai", []*ModelInfo{
		{ID: "m1", DisplayName: "One", OwnedBy: "openai"},
		{ID: "m2", DisplayName: "Two", OwnedBy: "openai"},
		{ID: "m3", DisplayName: "Three", OwnedBy: "openai"},
	})

	catalog := r.ModelCatalog()
	if len(catalog) != 3 {
		t.Fatalf("expected 3 catalog entries, got %d", len(catalog))
	}
	byID := make(map[string]ModelCatalogEntry, len(catalog))
	for _, e := range catalog {
		byID[e.ID] = e
	}
	if !byID["m2"].Prioritized || byID["m2"].Priority != 0 {
		t.Fatalf("m2 should be prioritized at 0, got %+v", byID["m2"])
	}
	if !byID["m3"].Disabled {
		t.Fatalf("m3 should be disabled, got %+v", byID["m3"])
	}
	if byID["m1"].Prioritized || byID["m1"].Disabled {
		t.Fatalf("m1 should be plain, got %+v", byID["m1"])
	}
	// Prioritized models first in catalog order.
	if catalog[0].ID != "m2" {
		t.Fatalf("expected prioritized model first, got %s", catalog[0].ID)
	}
}

func TestInvalidateCacheRefreshesListings(t *testing.T) {
	withPolicy(t, nil, nil, false)
	r := newTestModelRegistry()
	r.RegisterClient("client-1", "openai", []*ModelInfo{{ID: "m1", OwnedBy: "openai"}})

	if models := r.GetAvailableModels("openai"); len(models) != 1 {
		t.Fatalf("expected m1 listed, got %d", len(models))
	}

	withPolicy(t, nil, []string{"m1"}, false)
	r.InvalidateAvailableModelsCache()

	if models := r.GetAvailableModels("openai"); len(models) != 0 {
		t.Fatalf("expected m1 hidden after disable, got %d", len(models))
	}
}
