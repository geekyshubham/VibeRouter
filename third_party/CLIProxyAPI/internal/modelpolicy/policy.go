// Package modelpolicy holds the user-configured model routing policy:
// which models may be served at all, the order they are preferred in, and
// whether an exhausted model falls back to the next preferred one.
//
// The policy is a small immutable snapshot swapped atomically on startup,
// config hot-reload, and management-console mutations, so request paths can
// read it without locks.
package modelpolicy

import (
	"strings"
	"sync/atomic"
)

// Policy is the immutable snapshot of the routing settings.
type Policy struct {
	// ModelPriority is the user-ordered list of model IDs (management UI order).
	// It governs /v1/models listing order, "auto" model resolution, and — when
	// ModelFailover is enabled — the exhaustion fallback walk.
	ModelPriority []string

	// DisabledModels are hidden from /v1/models and rejected when requested.
	DisabledModels []string

	// ModelFailover enables falling back to the next preferred model when the
	// requested model has no available credential (e.g. quota exhausted on
	// every provider that serves it).
	ModelFailover bool
}

var current atomic.Pointer[Policy]

func init() {
	current.Store(&Policy{})
}

// Set swaps the active policy snapshot.
func Set(p *Policy) {
	if p == nil {
		p = &Policy{}
	}
	current.Store(p)
}

// Sync refreshes the active policy from the routing config values. Call after
// the config loads or hot-reloads, and after management-console mutations of
// the routing settings (followed by an invalidation of the registry's
// model-listing cache).
func Sync(modelPriority, disabledModels []string, modelFailover bool) {
	Set(&Policy{
		ModelPriority:  append([]string(nil), modelPriority...),
		DisabledModels: append([]string(nil), disabledModels...),
		ModelFailover:  modelFailover,
	})
}

// Get returns the active policy snapshot (never nil).
func Get() *Policy {
	return current.Load()
}

func normalize(id string) string {
	return strings.ToLower(strings.TrimSpace(id))
}

// IsDisabled reports whether the model is excluded from serving and listing.
func IsDisabled(modelID string) bool {
	id := normalize(modelID)
	if id == "" {
		return false
	}
	for _, disabled := range Get().DisabledModels {
		if normalize(disabled) == id {
			return true
		}
	}
	return false
}

// PriorityPosition returns the position of the model in the user's priority
// list. Unlisted models sort after every listed one (position = len + offset).
func PriorityPosition(modelID string) (int, bool) {
	id := normalize(modelID)
	for i, candidate := range Get().ModelPriority {
		if normalize(candidate) == id {
			return i, true
		}
	}
	return 0, false
}

// FallbackCandidates returns the model IDs to try — in the user's preferred
// order — when the requested model cannot be served. The requested model
// itself, disabled models, and duplicates are excluded, and the list is
// capped to keep worst-case failover latency bounded.
func FallbackCandidates(requestedModelID string, limit int) []string {
	requested := normalize(requestedModelID)
	candidates := make([]string, 0, len(Get().ModelPriority))
	seen := make(map[string]struct{})
	for _, candidate := range Get().ModelPriority {
		id := normalize(candidate)
		if id == "" || id == requested {
			continue
		}
		if IsDisabled(id) {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		candidates = append(candidates, candidate)
		if limit > 0 && len(candidates) >= limit {
			break
		}
	}
	return candidates
}
