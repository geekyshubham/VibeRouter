/* ============================================================================
   types — shapes returned by the CLIProxyAPI /v0/management/* endpoints.
   Field names mirror the backend JSON exactly. All collection fields may arrive
   as null; consumers normalize via asArray()/pluckArray().
   ========================================================================== */

/** One 10-minute request window from an auth file's recent_requests. */
export interface RecentRequestBucket {
  /** "HH:MM-HH:MM", server local time. */
  time: string;
  success: number;
  failed: number;
}

/** One OAuth token / auth file under ~/.cli-proxy-api (GET /auth-files → files[]). */
export interface AuthFile {
  auth_index: string;
  created_at: string;
  disabled: boolean;
  failed: number;
  id: string;
  label: string;
  modtime: string;
  name: string;
  path: string;
  provider: string;
  /** Oldest → newest. Older backends sent bare counts. */
  recent_requests?: (RecentRequestBucket | number)[] | null;
  runtime_only: boolean;
  size: number;
  source: string;
  status: string;
  status_message: string;
  success: number;
  type: string;
  unavailable: boolean;
  updated_at: string;
}

/** One entry in an OpenAI-compatible provider's api-key-entries. */
export interface CompatKeyEntry {
  'api-key': string;
  'auth-index'?: string;
}

/** One model alias mapping. */
export interface CompatModel {
  name: string;
  alias: string;
}

/** One OpenAI-compatible provider (GET /openai-compatibility → openai-compatibility[]). */
export interface CompatProvider {
  name: string;
  'display-name'?: string;
  disabled: boolean;
  'base-url': string;
  'api-key-entries': CompatKeyEntry[] | null;
  models: CompatModel[] | null;
}

/** Backend configuration object (GET /config) — partial; only fields we read. */
export interface BackendConfig {
  'proxy-url': string;
  debug: boolean;
  'request-log': boolean;
  'logging-to-file': boolean;
  'usage-statistics-enabled': boolean;
  'request-retry': number;
  'logs-max-total-size-mb'?: number;
  'api-keys': string[] | null;
  'gemini-api-key': string[] | null;
  'claude-api-key': string[] | null;
  'codex-api-key': string[] | null;
  'vertex-api-key': string[] | null;
  'openai-compatibility': CompatProvider[] | null;
  'quota-exceeded'?: { 'switch-project'?: boolean; 'switch-preview-model'?: boolean };
  routing?: { strategy?: string };
  [key: string]: unknown;
}

/* --------------------------------------------------------- USAGE BY DATE */

/* GET /v0/management/usage-daily — see
   third_party/CLIProxyAPI/internal/api/handlers/management/usage_daily.go.
   The server reads the day history the macOS app writes to Application Support;
   totals are computed there so the mixed-unit rules (Kiro reports millicredits,
   everyone else tokens) live in one place per surface. */

/** Volume unit for a usage row. Only token-like units may be summed together. */
export type UsageVolumeUnit = 'tokens' | 'estimatedTokens' | 'credits';

/** One model's usage within a day. */
export interface UsageDailyModelRow {
  providerID: string;
  providerName: string;
  model: string;
  totalVolume: number;
  volumeUnit: UsageVolumeUnit;
  estimatedCostUSD: number;
  requestCount: number;
}

/** One provider's usage within a day, ranked by cost. */
export interface UsageDailyProviderRow {
  providerID: string;
  providerName: string;
  totalVolume: number;
  volumeUnit: UsageVolumeUnit;
  estimatedCostUSD: number;
  requestCount: number;
  /** 'exact' | 'dayTotalsOnly' | 'sessionApproximate'. */
  fidelity: string;
  /** Fraction of the day's spend (0..1). Absent when the day has no cost signal,
   *  so the UI must not render a misleading 0%. */
  costShare?: number;
}

/** A single day's usage report. */
export interface UsageDailyResponse {
  date: string;
  /** Token-like units only; Kiro millicredits are excluded by design. */
  totalTokens: number;
  totalCostUSD: number;
  totalRequests: number;
  providers: UsageDailyProviderRow[] | null;
  models: UsageDailyModelRow[] | null;
  /** Human-readable notes for providers whose day attribution is approximate. */
  caveats: string[] | null;
  empty: boolean;
  availableDays: string[] | null;
  earliestDay?: string;
  latestDay?: string;
  updatedAt?: string;
}

/** One request-log line (GET /logs → logs[] when logging enabled). */
export interface LogLine {
  time?: string;
  timestamp?: string;
  level?: string;
  model?: string;
  status?: number;
  message?: string;
  [key: string]: unknown;
}

/** One model in the routing catalog (GET /routing/models → models[]). */
export interface ModelCatalogEntry {
  id: string;
  display_name?: string;
  owned_by?: string;
  providers: string[] | null;
  available: number;
  disabled: boolean;
  priority: number;
  prioritized: boolean;
}

/** GET /routing/models → catalog + routing policy in one payload. */
export interface ModelRoutingResponse {
  models: ModelCatalogEntry[] | null;
  'model-priority': string[] | null;
  'disabled-models': string[] | null;
  'model-failover': boolean;
}
