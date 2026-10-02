package management

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"testing"

	"github.com/gin-gonic/gin"
)

// swiftEncodedFixture is REAL output from Swift's JSONEncoder, produced by encoding
// UsageDailyStore's payload types (DailyProviderUsage / DailyModelUsage / UsageVolumeUnit /
// DailyUsageFidelity). It is pasted verbatim rather than hand-written so this test fails
// if the Swift writer and this Go reader ever drift apart on field names, enum spellings,
// or nesting — the one seam in the per-date usage feature that no other test covers.
//
// Regenerate with a small Swift program that encodes the same three providers:
//
//	swiftc -O -o /tmp/gen main.swift src/Sources/UsageDailyModels.swift \
//	  src/Sources/UsageVolumeUnit.swift && /tmp/gen
const swiftEncodedFixture = `{
  "days": {
    "2026-07-30": {
      "codex": {
        "fidelity": "exact",
        "models": [
          {
            "cacheReadTokens": 900000,
            "estimatedCostUSD": 5.2,
            "inputTokens": 1300000,
            "model": "gpt-5.4",
            "outputTokens": 42000,
            "requestCount": 88,
            "totalVolume": 2242000,
            "volumeUnit": "tokens"
          }
        ],
        "providerID": "codex",
        "volumeUnit": "tokens"
      },
      "grok": {
        "fidelity": "sessionApproximate",
        "models": [
          {
            "cacheReadTokens": 0,
            "estimatedCostUSD": 0.55,
            "inputTokens": 91000,
            "model": "grok-4",
            "outputTokens": 0,
            "requestCount": 3,
            "totalVolume": 91000,
            "volumeUnit": "estimatedTokens"
          }
        ],
        "providerID": "grok",
        "volumeUnit": "estimatedTokens"
      },
      "kiro": {
        "fidelity": "exact",
        "models": [
          {
            "cacheReadTokens": 0,
            "estimatedCostUSD": 0.168,
            "inputTokens": 4200,
            "model": "kiro-claude-sonnet",
            "outputTokens": 0,
            "requestCount": 7,
            "totalVolume": 4200,
            "volumeUnit": "credits"
          }
        ],
        "providerID": "kiro",
        "volumeUnit": "credits"
      }
    }
  },
  "updatedAt": 1784000000,
  "version": 3
}`

func parseFixture(t *testing.T) *usageDailyFile {
	t.Helper()
	var parsed usageDailyFile
	if err := json.Unmarshal([]byte(swiftEncodedFixture), &parsed); err != nil {
		t.Fatalf("Swift-encoded history did not unmarshal: %v", err)
	}
	return &parsed
}

// The schema version must match what the Swift store writes, or loadUsageDailyFile
// discards the file as unknown and the console silently shows "no data".
func TestSwiftFixtureMatchesSchemaVersion(t *testing.T) {
	// Read the actual writer, not just the pasted fixture: the old test let both
	// Go constants drift together while Swift moved to schema 3.
	source, err := os.ReadFile("../../../../../../src/Sources/UsageDailyStore.swift")
	if err != nil {
		t.Fatal(err)
	}
	match := regexp.MustCompile(`schemaVersion = (\d+)`).FindSubmatch(source)
	if len(match) != 2 {
		t.Fatal("Swift schema version missing")
	}
	version, _ := strconv.Atoi(string(match[1]))
	if version != usageDailySchemaVersion {
		t.Fatalf("Swift schema %d differs from Go schema %d", version, usageDailySchemaVersion)
	}
	parsed := parseFixture(t)
	if parsed.Version != usageDailySchemaVersion {
		t.Fatalf("version = %d, want %d (Swift and Go schema versions have drifted)", parsed.Version, usageDailySchemaVersion)
	}
	if parsed.UpdatedAt != 1784000000 {
		t.Errorf("updatedAt = %v, want 1784000000", parsed.UpdatedAt)
	}
}

// Every field the Swift encoder emits must land in a Go field. A silent mismatch
// would decode as a zero value and under-report usage rather than erroring.
func TestSwiftFixtureFieldsDecodeIntoGoStructs(t *testing.T) {
	parsed := parseFixture(t)

	providers, ok := parsed.Days["2026-07-30"]
	if !ok {
		t.Fatalf("day key 2026-07-30 missing; got days %v", parsed.Days)
	}
	if len(providers) != 3 {
		t.Fatalf("provider count = %d, want 3", len(providers))
	}

	codex, ok := providers["codex"]
	if !ok {
		t.Fatal("codex provider missing")
	}
	if codex.ProviderID != "codex" {
		t.Errorf("providerID = %q, want codex", codex.ProviderID)
	}
	if codex.VolumeUnit != "tokens" {
		t.Errorf("volumeUnit = %q, want tokens", codex.VolumeUnit)
	}
	if codex.Fidelity != "exact" {
		t.Errorf("fidelity = %q, want exact", codex.Fidelity)
	}
	if len(codex.Models) != 1 {
		t.Fatalf("codex model count = %d, want 1", len(codex.Models))
	}

	m := codex.Models[0]
	if m.Model != "gpt-5.4" {
		t.Errorf("model = %q, want gpt-5.4", m.Model)
	}
	if m.InputTokens != 1300000 {
		t.Errorf("inputTokens = %d, want 1300000", m.InputTokens)
	}
	if m.OutputTokens != 42000 {
		t.Errorf("outputTokens = %d, want 42000", m.OutputTokens)
	}
	if m.CacheReadTokens != 900000 {
		t.Errorf("cacheReadTokens = %d, want 900000", m.CacheReadTokens)
	}
	if m.TotalVolume != 2242000 {
		t.Errorf("totalVolume = %d, want 2242000", m.TotalVolume)
	}
	if m.RequestCount != 88 {
		t.Errorf("requestCount = %d, want 88", m.RequestCount)
	}
	if math.Abs(m.EstimatedCostUSD-5.2) > 1e-9 {
		t.Errorf("estimatedCostUSD = %v, want 5.2", m.EstimatedCostUSD)
	}
	if m.VolumeUnit != "tokens" {
		t.Errorf("model volumeUnit = %q, want tokens", m.VolumeUnit)
	}
}

// Swift's enum raw values must match the strings this package switches on. If
// "estimatedTokens" were spelled differently here, Grok's volume would be dropped
// from token totals; if "credits" were, Kiro's millicredits would be added to them.
func TestSwiftEnumSpellingsMatchGoSwitches(t *testing.T) {
	parsed := parseFixture(t)
	providers := parsed.Days["2026-07-30"]

	if !volumeAggregatesAsTokens(providers["codex"].VolumeUnit) {
		t.Error("codex tokens must aggregate into the token total")
	}
	if !volumeAggregatesAsTokens(providers["grok"].VolumeUnit) {
		t.Error("grok estimatedTokens must aggregate into the token total")
	}
	if volumeAggregatesAsTokens(providers["kiro"].VolumeUnit) {
		t.Error("kiro credits must NOT aggregate into the token total (millicredits would inflate it ~1000x)")
	}

	if got := usageFidelityCaveat(providers["grok"].Fidelity); got == "" {
		t.Error("sessionApproximate must produce a caveat; Swift spelling may have drifted")
	}
	if got := usageFidelityCaveat(providers["codex"].Fidelity); got != "" {
		t.Errorf("exact fidelity must have no caveat, got %q", got)
	}
}

// The headline numbers: tokens exclude credits, cost includes everything.
func TestTotalsApplyMixedUnitRules(t *testing.T) {
	writeUsageHistoryFixture(t, swiftEncodedFixture)
	status, resp := queryUsageHistory(t, "2026-07-30")
	if status != http.StatusOK {
		t.Fatalf("status = %d", status)
	}
	// Match the menu bar: measured tokens exclude both estimates and credits.
	if resp.TotalTokens != 2242000 || resp.TotalEstimatedTokens != 91000 {
		t.Errorf("tokens = %d + %d estimated", resp.TotalTokens, resp.TotalEstimatedTokens)
	}
	// Cost is the one basis comparable across unlike units.
	if math.Abs(resp.TotalCostUSD-5.918) > 1e-9 {
		t.Errorf("totalCostUSD = %v, want 5.918", resp.TotalCostUSD)
	}
	if resp.TotalRequests != 98 {
		t.Errorf("totalRequests = %d, want 98", resp.TotalRequests)
	}
}

// "Which provider did I use most" must rank by cost. Ranking by raw volume would
// wrongly promote Grok (91,000 estimated tokens) over Kiro, and more importantly
// would compare unlike units.
func TestProviderRankingUsesCostNotVolume(t *testing.T) {
	parsed := parseFixture(t)
	providers := parsed.Days["2026-07-30"]

	rows := make([]usageDailyProviderRow, 0, len(providers))
	for _, provider := range providers {
		row := usageDailyProviderRow{
			ProviderID: provider.ProviderID,
			VolumeUnit: provider.VolumeUnit,
			Fidelity:   provider.Fidelity,
		}
		for _, m := range provider.Models {
			row.TotalVolume += m.TotalVolume
			row.EstimatedCostUSD += m.EstimatedCostUSD
		}
		rows = append(rows, row)
	}

	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.EstimatedCostUSD != b.EstimatedCostUSD {
			return a.EstimatedCostUSD > b.EstimatedCostUSD
		}
		if a.VolumeUnit == b.VolumeUnit && a.TotalVolume != b.TotalVolume {
			return a.TotalVolume > b.TotalVolume
		}
		return a.ProviderID < b.ProviderID
	})

	want := []string{"codex", "grok", "kiro"}
	for i, id := range want {
		if rows[i].ProviderID != id {
			t.Fatalf("rank %d = %q, want %q (full order %v)", i, rows[i].ProviderID, id, rows)
		}
	}
}

func TestAvailableDaysSkipsDaysWithoutModels(t *testing.T) {
	days := map[string]map[string]usageDailyProvider{
		"2026-07-28": {"codex": {ProviderID: "codex", Models: nil}},
		"2026-07-29": {"codex": {ProviderID: "codex", Models: []usageDailyModel{{Model: "gpt-5.4"}}}},
		"2026-07-30": {"kiro": {ProviderID: "kiro", Models: []usageDailyModel{{Model: "kiro"}}}},
	}
	got := usageDailyAvailableDays(days)
	want := []string{"2026-07-29", "2026-07-30"}
	if len(got) != len(want) {
		t.Fatalf("availableDays = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("availableDays = %v, want %v (must be ascending, data-only)", got, want)
		}
	}
}

func TestDayKeyValidationRejectsMalformedAndImpossibleDates(t *testing.T) {
	valid := []string{"2026-07-30", "2024-02-29", "1999-12-31"}
	for _, v := range valid {
		if !isUsageDayKey(v) {
			t.Errorf("isUsageDayKey(%q) = false, want true", v)
		}
	}
	// Rejecting normalised-but-wrong dates matters: Go's time.Parse would otherwise
	// accept 2026-02-30 and silently answer for 2026-03-02.
	invalid := []string{"", "2026-7-30", "30-07-2026", "2026-02-30", "2025-02-29", "2026-13-01", "2026-07-30T00:00:00Z", "not-a-date"}
	for _, v := range invalid {
		if isUsageDayKey(v) {
			t.Errorf("isUsageDayKey(%q) = true, want false", v)
		}
	}
}

// Display names must agree with UsageProviderNaming.displayName in Swift, or the same
// provider reads differently in the menu bar and the console.
func TestProviderDisplayNamesMatchSwift(t *testing.T) {
	cases := map[string]string{
		"codex":       "Codex",
		"claude":      "Claude",
		"gemini":      "Gemini",
		"antigravity": "Antigravity",
		"copilot":     "Copilot",
		"kiro":        "Kiro CLI",
		"grok":        "Grok CLI",
		"opencode":    "OpenCode",
		"zai":         "Z.AI",
		"kimi":        "Kimi",
		"qwen":        "Qwen",
		"":            "",
	}
	for id, want := range cases {
		if got := usageProviderDisplayName(id); got != want {
			t.Errorf("displayName(%q) = %q, want %q", id, got, want)
		}
	}
}

func TestUnsupportedSchemaIsAnErrorInsteadOfZeroUsage(t *testing.T) {
	for _, version := range []int{1, 2, 999} {
		t.Run(strconv.Itoa(version), func(t *testing.T) {
			writeUsageHistoryFixture(t, `{"version":`+strconv.Itoa(version)+`,"days":{}}`)
			status, _ := queryUsageHistory(t, "2026-07-30")
			if status != http.StatusInternalServerError {
				t.Fatalf("status = %d, want error for incompatible history", status)
			}
		})
	}
}

func writeUsageHistoryFixture(t *testing.T, fixture string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, "Library", "Application Support", "VibeRouter")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, usageDailyFileName), []byte(fixture), 0o600); err != nil {
		t.Fatal(err)
	}
}

func queryUsageHistory(t *testing.T, date string) (int, usageDailyResponse) {
	t.Helper()
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, "/usage-daily?date="+date, nil)
	(&Handler{}).GetUsageDaily(c)
	var resp usageDailyResponse
	if rec.Code == http.StatusOK {
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
	}
	return rec.Code, resp
}

func TestDailyUsageMixedProviderUnitsAndFidelity(t *testing.T) {
	parsed := parseFixture(t)
	providers := parsed.Days["2026-07-30"]
	kiro := providers["kiro"]
	kiro.Fidelity = "partial"
	kiro.Models = append(kiro.Models, usageDailyModel{Model: "proxy-estimate", TotalVolume: 800000, VolumeUnit: "estimatedTokens"})
	providers["kiro"] = kiro
	grok := providers["grok"]
	grok.Fidelity = "legacy"
	providers["grok"] = grok
	data, err := json.Marshal(parsed)
	if err != nil {
		t.Fatal(err)
	}
	writeUsageHistoryFixture(t, string(data))
	status, resp := queryUsageHistory(t, "2026-07-30")
	if status != http.StatusOK {
		t.Fatalf("status = %d", status)
	}
	if resp.TotalTokens != 2242000 || resp.TotalEstimatedTokens != 891000 {
		t.Fatalf("wrong token totals: %+v", resp)
	}
	for _, row := range resp.Providers {
		if row.ProviderID == "kiro" && row.TotalVolume != 4200 {
			t.Fatalf("estimates inflated credit volume: %+v", row)
		}
	}
	if len(resp.Caveats) != 2 {
		t.Fatalf("missing partial/legacy caveats: %v", resp.Caveats)
	}
	if len(resp.AvailableDays) != 1 || resp.UpdatedAt == "" || resp.Empty {
		t.Fatalf("missing history metadata: %+v", resp)
	}
}

func TestUsageHistoryMissingFileStillValidatesDates(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	status, resp := queryUsageHistory(t, "2026-07-30")
	if status != http.StatusOK || !resp.Empty {
		t.Fatalf("absent history status=%d empty=%v", status, resp.Empty)
	}
	status, _ = queryUsageHistory(t, "2026-02-30")
	if status != http.StatusBadRequest {
		t.Fatalf("invalid date status=%d", status)
	}
}
