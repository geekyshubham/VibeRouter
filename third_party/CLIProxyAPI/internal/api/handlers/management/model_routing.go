package management

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/modelpolicy"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/registry"
)

// normalizeModelIDs trims, lowercases for dedup purposes keeps original case,
// and drops empty entries while preserving the caller's order.
func normalizeModelIDs(ids []string) []string {
	out := make([]string, 0, len(ids))
	seen := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		trimmed := strings.TrimSpace(id)
		if trimmed == "" {
			continue
		}
		key := strings.ToLower(trimmed)
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, trimmed)
	}
	return out
}

// syncRoutingPolicy pushes the mutated routing config into the live policy
// snapshot and drops cached model listings so /v1/models reflects it at once.
func (h *Handler) syncRoutingPolicy() {
	modelpolicy.Sync(h.cfg.Routing.ModelPriority, h.cfg.Routing.DisabledModels, h.cfg.Routing.ModelFailover)
	registry.GetGlobalRegistry().InvalidateAvailableModelsCache()
}

// GetModelRouting returns the model catalog plus the routing policy in one
// payload for the control panel: which models exist, who serves them, their
// availability, and the user's priority / disabled / failover settings.
func (h *Handler) GetModelRouting(c *gin.Context) {
	catalog := registry.GetGlobalRegistry().ModelCatalog()
	c.JSON(http.StatusOK, gin.H{
		"models":          catalog,
		"model-priority":  append([]string(nil), h.cfg.Routing.ModelPriority...),
		"disabled-models": append([]string(nil), h.cfg.Routing.DisabledModels...),
		"model-failover":  h.cfg.Routing.ModelFailover,
	})
}

// readModelIDList accepts either a raw JSON array of model IDs or
// {"value": [...]} / {"items": [...]} bodies.
func readModelIDList(c *gin.Context) ([]string, bool) {
	data, err := c.GetRawData()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "failed to read body"})
		return nil, false
	}
	var arr []string
	if err := json.Unmarshal(data, &arr); err == nil {
		return arr, true
	}
	var obj struct {
		Value []string `json:"value"`
		Items []string `json:"items"`
	}
	if err := json.Unmarshal(data, &obj); err == nil {
		if obj.Value != nil {
			return obj.Value, true
		}
		if obj.Items != nil {
			return obj.Items, true
		}
	}
	c.JSON(http.StatusBadRequest, gin.H{"error": "invalid body"})
	return nil, false
}

// GetModelPriority returns the user-ordered model priority list.
func (h *Handler) GetModelPriority(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"model-priority": append([]string(nil), h.cfg.Routing.ModelPriority...)})
}

// PutModelPriority replaces the model priority order. Models the proxy does
// not know are kept as-is so ordering can be prepared before an account is
// added.
func (h *Handler) PutModelPriority(c *gin.Context) {
	ids, ok := readModelIDList(c)
	if !ok {
		return
	}
	h.mu.Lock()
	h.cfg.Routing.ModelPriority = normalizeModelIDs(ids)
	h.syncRoutingPolicy()
	h.persistLocked(c)
	h.mu.Unlock()
}

// GetDisabledModels returns models excluded from serving.
func (h *Handler) GetDisabledModels(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"disabled-models": append([]string(nil), h.cfg.Routing.DisabledModels...)})
}

// PutDisabledModels replaces the disabled-model list. Disabling a model also
// removes it from the priority list so the failover walk never targets it.
func (h *Handler) PutDisabledModels(c *gin.Context) {
	ids, ok := readModelIDList(c)
	if !ok {
		return
	}
	h.mu.Lock()
	h.cfg.Routing.DisabledModels = normalizeModelIDs(ids)
	disabled := make(map[string]struct{}, len(h.cfg.Routing.DisabledModels))
	for _, id := range h.cfg.Routing.DisabledModels {
		disabled[strings.ToLower(id)] = struct{}{}
	}
	priority := make([]string, 0, len(h.cfg.Routing.ModelPriority))
	for _, id := range h.cfg.Routing.ModelPriority {
		if _, off := disabled[strings.ToLower(id)]; off {
			continue
		}
		priority = append(priority, id)
	}
	h.cfg.Routing.ModelPriority = priority
	h.syncRoutingPolicy()
	h.persistLocked(c)
	h.mu.Unlock()
}

// GetModelFailover returns whether exhausted models fall back down the
// priority list.
func (h *Handler) GetModelFailover(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"model-failover": h.cfg.Routing.ModelFailover})
}

// PutModelFailover enables or disables model failover on exhaustion.
func (h *Handler) PutModelFailover(c *gin.Context) {
	var body struct {
		Value *bool `json:"value"`
	}
	if err := c.ShouldBindJSON(&body); err != nil || body.Value == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid body"})
		return
	}
	h.mu.Lock()
	h.cfg.Routing.ModelFailover = *body.Value
	h.syncRoutingPolicy()
	h.persistLocked(c)
	h.mu.Unlock()
}
