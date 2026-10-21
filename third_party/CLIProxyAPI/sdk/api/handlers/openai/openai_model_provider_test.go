package openai

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/registry"
)

func TestOpenAIModelsPreservesServingProviderMetadata(t *testing.T) {
	r := registry.GetGlobalRegistry()
	const client = "test-model-provider-metadata"
	const modelID = "test-go-model-provider-metadata"
	r.RegisterClient(client, "opencode-go", []*registry.ModelInfo{{
		ID: modelID, OwnedBy: "openai", DisplayName: "Upstream Model", Description: "Upstream details",
	}})
	t.Cleanup(func() { r.UnregisterClient(client) })
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	h := &OpenAIAPIHandler{}
	h.OpenAIModels(c)
	var payload struct {
		Data []struct {
			ID          string   `json:"id"`
			Providers   []string `json:"providers"`
			DisplayName string   `json:"display_name"`
			Description string   `json:"description"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	for _, model := range payload.Data {
		if model.ID == modelID {
			if !reflect.DeepEqual(model.Providers, []string{"opencode-go"}) || model.DisplayName != "Upstream Model" || model.Description != "Upstream details" {
				t.Fatalf("model metadata lost at HTTP boundary: %+v", model)
			}
			return
		}
	}
	t.Fatal("test model missing from catalog")
}
