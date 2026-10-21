package registry

import (
	"reflect"
	"testing"
)

func TestAvailableModelProvidersTrackSharedAliases(t *testing.T) {
	r := newTestModelRegistry()
	r.RegisterClient("codex-seat", "codex", []*ModelInfo{{ID: "shared-model", OwnedBy: "openai"}})
	r.RegisterClient("go-seat", "opencode-go", []*ModelInfo{{ID: "shared-model", OwnedBy: "openai"}})
	for _, format := range []string{"openai", "claude"} {
		models := r.GetAvailableModels(format)
		if len(models) != 1 {
			t.Fatalf("%s: expected one shared alias, got %d", format, len(models))
		}
		if got := models[0]["providers"]; !reflect.DeepEqual(got, []string{"codex", "opencode-go"}) {
			t.Fatalf("%s: missing serving providers: %v", format, got)
		}
		// Mutating a response cannot corrupt the cached provider list.
		models[0]["providers"].([]string)[0] = "changed"
		if got := r.GetAvailableModels(format)[0]["providers"]; !reflect.DeepEqual(got, []string{"codex", "opencode-go"}) {
			t.Fatalf("%s: cached providers mutated: %v", format, got)
		}
	}
	r.UnregisterClient("go-seat")
	if got := r.GetAvailableModels("openai")[0]["providers"]; !reflect.DeepEqual(got, []string{"codex"}) {
		t.Fatalf("removed provider still advertised: %v", got)
	}
}
