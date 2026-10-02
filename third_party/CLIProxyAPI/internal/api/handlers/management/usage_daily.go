package management

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// Per-date usage reporting for the VibeRouter management console.
//
// The data is produced by the macOS app (UsageDailyStore.swift), which scans local CLI
// session logs and writes an accumulating day history to Application Support. This
// server deliberately does NOT rescan those logs: it has no per-request usage history
// of its own (the in-memory ring buffer keeps only ~200 minutes of dateless 10-minute
// buckets), and duplicating the scanner in Go would guarantee the two implementations
// drift apart on cost and dedup rules.
//
// Totals are computed here rather than in the browser so the mixed-unit rules live in
// exactly one place per surface: Kiro reports millicredits, everyone else reports
// tokens, and summing those together would be meaningless.

const usageDailySchemaVersion = 3

// usageDailyFileName is written by the Swift app; keep in sync with UsageDailyStore.fileURL.
const usageDailyFileName = "usage-daily.json"

type usageDailyModel struct {
	Model            string  `json:"model"`
	InputTokens      int     `json:"inputTokens"`
	OutputTokens     int     `json:"outputTokens"`
	CacheReadTokens  int     `json:"cacheReadTokens"`
	TotalVolume      int     `json:"totalVolume"`
	EstimatedCostUSD float64 `json:"estimatedCostUSD"`
	RequestCount     int     `json:"requestCount"`
	VolumeUnit       string  `json:"volumeUnit"`
}

type usageDailyProvider struct {
	ProviderID string            `json:"providerID"`
	Models     []usageDailyModel `json:"models"`
	VolumeUnit string            `json:"volumeUnit"`
	Fidelity   string            `json:"fidelity"`
}

type usageDailyFile struct {
	Version   int                                      `json:"version"`
	UpdatedAt float64                                  `json:"updatedAt"`
	Days      map[string]map[string]usageDailyProvider `json:"days"`
}

// Response shapes.

type usageDailyModelRow struct {
	ProviderID       string  `json:"providerID"`
	ProviderName     string  `json:"providerName"`
	Model            string  `json:"model"`
	TotalVolume      int     `json:"totalVolume"`
	VolumeUnit       string  `json:"volumeUnit"`
	EstimatedCostUSD float64 `json:"estimatedCostUSD"`
	RequestCount     int     `json:"requestCount"`
}

type usageDailyProviderRow struct {
	ProviderID       string  `json:"providerID"`
	ProviderName     string  `json:"providerName"`
	TotalVolume      int     `json:"totalVolume"`
	VolumeUnit       string  `json:"volumeUnit"`
	EstimatedCostUSD float64 `json:"estimatedCostUSD"`
	RequestCount     int     `json:"requestCount"`
	Fidelity         string  `json:"fidelity"`
	// CostShare is the provider's fraction of the day's spend (0..1), omitted when the
	// day has no cost signal so the UI shows volume instead of a misleading 0%.
	CostShare *float64 `json:"costShare,omitempty"`
}

type usageDailyResponse struct {
	Date string `json:"date"`
	// Match DailyUsageSummary: measured tokens, estimates and credits stay separate.
	TotalTokens          int     `json:"totalTokens"`
	TotalEstimatedTokens int     `json:"totalEstimatedTokens"`
	TotalCostUSD         float64 `json:"totalCostUSD"`
	TotalRequests        int     `json:"totalRequests"`
	// Providers ranked by cost — the only basis comparable across unlike units.
	Providers []usageDailyProviderRow `json:"providers"`
	Models    []usageDailyModelRow    `json:"models"`
	// Caveats explains any provider whose day attribution is approximate.
	Caveats []string `json:"caveats"`
	Empty   bool     `json:"empty"`
	// AvailableDays lets the picker restrict itself to days that hold data.
	AvailableDays []string `json:"availableDays"`
	EarliestDay   string   `json:"earliestDay,omitempty"`
	LatestDay     string   `json:"latestDay,omitempty"`
	UpdatedAt     string   `json:"updatedAt,omitempty"`
}

// GetUsageDaily reports usage for one calendar day.
//
// GET /v0/management/usage-daily            → index only (available days, no day totals)
// GET /v0/management/usage-daily?date=YYYY-MM-DD → that day's totals and breakdown
func (h *Handler) GetUsageDaily(c *gin.Context) {
	if h == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "handler unavailable"})
		return
	}
	date := strings.TrimSpace(c.Query("date"))
	if date != "" && !isUsageDayKey(date) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "date must be formatted YYYY-MM-DD"})
		return
	}

	parsed, err := loadUsageDailyFile()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "usage history unreadable"})
		return
	}

	// No file yet: the app has not completed a scan. An empty 200 (not an error) lets the
	// console render "no data yet" instead of a failure toast.
	if parsed == nil {
		c.JSON(http.StatusOK, usageDailyResponse{
			Date:          strings.TrimSpace(c.Query("date")),
			Providers:     []usageDailyProviderRow{},
			Models:        []usageDailyModelRow{},
			Caveats:       []string{},
			AvailableDays: []string{},
			Empty:         true,
		})
		return
	}

	available := usageDailyAvailableDays(parsed.Days)
	resp := usageDailyResponse{
		Providers:     []usageDailyProviderRow{},
		Models:        []usageDailyModelRow{},
		Caveats:       []string{},
		AvailableDays: available,
		Empty:         true,
	}
	if len(available) > 0 {
		resp.EarliestDay = available[0]
		resp.LatestDay = available[len(available)-1]
	}
	if parsed.UpdatedAt > 0 {
		sec := int64(parsed.UpdatedAt)
		resp.UpdatedAt = time.Unix(sec, 0).UTC().Format(time.RFC3339)
	}

	if date == "" {
		// Index request: hand back the day list so the picker can bound itself.
		c.JSON(http.StatusOK, resp)
		return
	}
	resp.Date = date

	providers := parsed.Days[date]
	if len(providers) == 0 {
		c.JSON(http.StatusOK, resp)
		return
	}

	// Pass 1: totals. Cost is summable across every unit; volume is not.
	var totalCost float64
	totalTokens := 0
	totalEstimatedTokens := 0
	totalRequests := 0
	for _, provider := range providers {
		for _, m := range provider.Models {
			totalCost += m.EstimatedCostUSD
			totalRequests += m.RequestCount
			// Match DailyUsageSummary: measured and estimated tokens stay separate.
			if provider.VolumeUnit == "tokens" && m.VolumeUnit == "tokens" {
				totalTokens += m.TotalVolume
			}
			if m.VolumeUnit == "estimatedTokens" {
				totalEstimatedTokens += m.TotalVolume
			}
		}
	}

	// Pass 2: rows.
	for _, provider := range providers {
		if len(provider.Models) == 0 {
			continue
		}
		row := usageDailyProviderRow{
			ProviderID:   provider.ProviderID,
			ProviderName: usageProviderDisplayName(provider.ProviderID),
			VolumeUnit:   provider.VolumeUnit,
			Fidelity:     provider.Fidelity,
		}
		for _, m := range provider.Models {
			// Kiro can contain credits and token estimates in the same provider.
			if m.VolumeUnit == provider.VolumeUnit {
				row.TotalVolume += m.TotalVolume
			}
			row.EstimatedCostUSD += m.EstimatedCostUSD
			row.RequestCount += m.RequestCount
			resp.Models = append(resp.Models, usageDailyModelRow{
				ProviderID:       provider.ProviderID,
				ProviderName:     usageProviderDisplayName(provider.ProviderID),
				Model:            m.Model,
				TotalVolume:      m.TotalVolume,
				VolumeUnit:       m.VolumeUnit,
				EstimatedCostUSD: m.EstimatedCostUSD,
				RequestCount:     m.RequestCount,
			})
		}
		if totalCost > 0 {
			share := row.EstimatedCostUSD / totalCost
			row.CostShare = &share
		}
		resp.Providers = append(resp.Providers, row)

		if caveat := usageFidelityCaveat(provider.Fidelity); caveat != "" {
			resp.Caveats = append(resp.Caveats, usageProviderDisplayName(provider.ProviderID)+": "+caveat)
		}
	}

	// Rank by cost, then by volume within a matching unit, then by ID for stability.
	sort.SliceStable(resp.Providers, func(i, j int) bool {
		a, b := resp.Providers[i], resp.Providers[j]
		if a.EstimatedCostUSD != b.EstimatedCostUSD {
			return a.EstimatedCostUSD > b.EstimatedCostUSD
		}
		if a.VolumeUnit == b.VolumeUnit && a.TotalVolume != b.TotalVolume {
			return a.TotalVolume > b.TotalVolume
		}
		return a.ProviderID < b.ProviderID
	})
	sort.SliceStable(resp.Models, func(i, j int) bool {
		a, b := resp.Models[i], resp.Models[j]
		if a.EstimatedCostUSD != b.EstimatedCostUSD {
			return a.EstimatedCostUSD > b.EstimatedCostUSD
		}
		if a.VolumeUnit == b.VolumeUnit && a.TotalVolume != b.TotalVolume {
			return a.TotalVolume > b.TotalVolume
		}
		return a.Model < b.Model
	})
	sort.Strings(resp.Caveats)

	resp.TotalTokens = totalTokens
	resp.TotalEstimatedTokens = totalEstimatedTokens
	resp.TotalCostUSD = totalCost
	resp.TotalRequests = totalRequests
	resp.Empty = len(resp.Models) == 0

	c.JSON(http.StatusOK, resp)
}

// loadUsageDailyFile reads the app-written history. Returns (nil, nil) when absent.
func loadUsageDailyFile() (*usageDailyFile, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	path := filepath.Join(home, "Library", "Application Support", "VibeRouter", usageDailyFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var parsed usageDailyFile
	if err := json.Unmarshal(data, &parsed); err != nil {
		return nil, err
	}
	// Never report zero usage when history exists but cannot be understood. Older
	// schemas need the Swift app's migration and rescan to correct their accounting.
	if parsed.Version != usageDailySchemaVersion {
		return nil, fmt.Errorf("unsupported usage history version %d", parsed.Version)
	}
	return &parsed, nil
}

// usageDailyAvailableDays returns ascending day keys that hold at least one model row.
func usageDailyAvailableDays(days map[string]map[string]usageDailyProvider) []string {
	out := make([]string, 0, len(days))
	for day, providers := range days {
		for _, provider := range providers {
			if len(provider.Models) > 0 {
				out = append(out, day)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

// volumeAggregatesAsTokens mirrors UsageVolumeUnit.aggregatesAsTokens in Swift.
// Credits must never join a token total: they are stored as millicredits, so adding
// them would inflate the figure by ~1000x per credit.
func volumeAggregatesAsTokens(unit string) bool {
	switch unit {
	case "tokens", "estimatedTokens":
		return true
	default:
		return false
	}
}

// usageFidelityCaveat mirrors DailyUsageFidelity.caveat in Swift.
func usageFidelityCaveat(fidelity string) string {
	switch fidelity {
	case "dayTotalsOnly":
		return "day total only — no per-model split"
	case "sessionApproximate":
		return "approximate — whole sessions land on one day"
	case "partial":
		return "partial — some session logs could not be read"
	case "legacy":
		return "from an older build, unverified"
	default:
		return ""
	}
}

// usageProviderDisplayName mirrors UsageProviderNaming.displayName in Swift.
func usageProviderDisplayName(providerID string) string {
	switch strings.ToLower(providerID) {
	case "codex":
		return "Codex"
	case "claude":
		return "Claude"
	case "gemini":
		return "Gemini"
	case "antigravity":
		return "Antigravity"
	case "copilot":
		return "Copilot"
	case "kiro":
		return "Kiro CLI"
	case "grok":
		return "Grok CLI"
	case "opencode":
		return "OpenCode"
	case "zai", "z.ai":
		return "Z.AI"
	case "kimi":
		return "Kimi"
	case "qwen":
		return "Qwen"
	case "cursor":
		return "Cursor"
	case "codebuddy":
		return "CodeBuddy"
	case "gitlab":
		return "GitLab"
	case "kilo":
		return "Kilo"
	default:
		if providerID == "" {
			return ""
		}
		// Match Swift's `.capitalized`, which uppercases the first letter and lowercases
		// the rest (equivalent here: provider IDs are single words with no spaces).
		// It also works on characters, not bytes — slicing providerID[:1] would split a
		// multi-byte rune and emit replacement characters, so decode runes instead.
		runes := []rune(providerID)
		return strings.ToUpper(string(runes[0])) + strings.ToLower(string(runes[1:]))
	}
}

// isUsageDayKey validates a YYYY-MM-DD key and rejects impossible dates
// (Go's time.Parse would otherwise accept some out-of-range days by normalising).
func isUsageDayKey(value string) bool {
	if len(value) != 10 {
		return false
	}
	parsedTime, err := time.Parse("2006-01-02", value)
	if err != nil {
		return false
	}
	return parsedTime.Format("2006-01-02") == value
}
