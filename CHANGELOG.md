# Changelog

All notable changes to **VibeRouter** are documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.4] - 2026-10-21

### Fixed
- Antigravity and Gemini collapsed badges show Google weekly usage as a used percent. A full Claude or GPT pool no longer reads as 100% when Gemini weekly is the limit that matters.
- OpenCode Go uses the signed-in Console session when the stored API key is expired.
- A truncated Codex reply is a client error, so one incomplete response no longer cools that account.
- The thinking proxy can start again after its listener fails.
- Claude quota values survive a restart, polling backs off when the API is cooling down, and native session renewal no longer races the Claude CLI.
- Claude auto mode keeps working on translated gateway routes, including the server-side safeguard protocol.
- Grok quota labels follow the billing period the API reports.

### Changed
- Switching the Antigravity account updates the agy CLI login. The Keychain token is passed on standard input.

## [1.3.3] - 2026-10-02

### Fixed
- Management usage history now reads the app's current schema, refreshes automatically, and keeps measured tokens, estimates, and Kiro credits separate.
- Internal account bookkeeping is excluded from the account list; provider counts reflect the served model catalog.
- Kiro requests use the active CLI Builder ID login as well as social logins, preserving that login through token refresh instead of selecting another account with different model access.
- Streaming, images, large conversations, and account isolation are covered by production-code regression checks.

### Changed
- Renamed the GitHub repository to VibeRouter and updated app, documentation, and release links.

### Added
- **Claude rate-limit resets** — Claude accounts now get the same reset bank as ChatGPT and Grok. Saved resets (the Settings → Usage "Reset for free" grant) and the weekly session reset (`/limit-reset`) are read from Claude's OAuth usage API and can be applied from the usage card or `viberouter reset`. A grant Anthropic only exposes on claude.ai stays hidden here instead of showing a false "none left".

### Fixed
- **Plain `claude` keeps its Anthropic subscription after using Kiro** — `claude-viberouter` now uses a separate Claude config directory, so changing models in that session cannot save a `kiro/…` model into native Claude settings. Reconfiguring Claude also clears a Kiro model left by older launchers and restores the prior native model when the backup has one.
- **Claude reset button missing on the usage card** — The spendable Claude grant is returned on the at-limit usage response (`cedar_ember` inside `at_wall=1`). VibeRouter only read that body for the weekly session reset, and a separate anytime probe that came back "web only" hid the bank, so the "Use rate-limit reset" button never appeared. The card now keeps whichever read actually has a grant, including a saved reset that cannot be spent until a limit is hit. When Anthropic says the saved grant is only on claude.ai, the card shows **Reset on claude.ai** instead of hiding the control.
- **Claude Code no longer gets logged out every other refresh** — Importing the Claude Code account copied its rotating refresh token into `~/.cli-proxy-api`. VibeRouter's keep-alive, usage fetch, and the bundled proxy all POSTed that leftover token; Anthropic invalidated the previous one and `claude` printed `Login expired · Please run /login`. Native Claude Code now owns the refresh token exclusively. The proxy copy keeps only the access token (overlaid from the keychain) and never writes a rotated token back over Claude Code's session.

### Added
- **Model routing in the management console** — The console's new Models tab shows every model the connected accounts can serve, with the provider(s) backing each and live availability, and lets you decide exactly what VibeRouter serves and in what order. Toggle any model off to stop serving it (hidden from `/v1/models`, requests answered with a clear "disabled in the management console" error); arrange the rest into a priority order (first match wins); and optionally enable **failover to next model** so a request whose model is exhausted everywhere (quota hit on every provider/account serving it) automatically flows to the next model in your priority list instead of failing. Settings live under `routing:` (`model-priority`, `disabled-models`, `model-failover`), survive config regeneration and app restarts, and apply instantly via config hot-reload.

### Fixed
- **Management console no longer brands itself "VibeProxy Ultra"** — The embedded management panel served on port 8318 (page title, sidebar, login screen) still carried the old name because the shipped `cli-proxy-api-plus` binary predated the rename: the UI sources were renamed, but the stale `management-ui/dist` build output kept being embedded. The panel is rebuilt from source and re-embedded, so the console now reads "VibeRouter · Management" everywhere.
- **Routing settings written by the console now survive a save** — `SaveConfigPreserveComments` merges the sanitized config into the existing YAML tree while keeping comments, but keys omitted by `omitempty` (an emptied priority list, cleared disabled list, `model-failover: false`) silently kept their previous on-disk values — and the config hot-reload then restored the stale values over the live state seconds later. The routing policy keys are now synced to the sanitized config on every save.
- **Codex "Wake 5h window" actually wakes the account you clicked** — Three stacked failures made Codex wakes dead. (1) The direct ChatGPT wake posted `stream:false` with a string `input`; the backend rejects that with HTTP 400 `Input must be a list` / `Stream must be set to true`, so the per-account fallback could never succeed. It now sends the same shape the bundled proxy's executor does (`stream:true`, list-form `input`, `instructions`, `text/event-stream`). (2) The wake's model list was frozen at registry-era slugs (`gpt-5.4-mini`, `gpt-5.4`, `codex-mini-latest`) that OpenAI now rejects with `model is not supported when using Codex with a ChatGPT account`; the list is the live backend set (`gpt-5.5`, `gpt-5.6-luna`, `codex-auto-review`). (3) Because the local proxy routes fill-first, a proxy wake engaged whichever credential the proxy picked — not the account whose card was clicked, so multi-seat setups woke the wrong 5h window. Native per-account wakes now run first for Codex (OAuth token + `ChatGPT-Account-Id`), Claude (Anthropic messages), and Antigravity/Gemini (Cloud Code `v1internal:generateContent` with the account's own token and project), with the proxy wake kept as a fallback. A Codex 429 (`usage_limit_reached`) is still a successful wake — the window was engaged — and the message now says when it resets.
- **Wake model discovery reads `owned_by`, not ID prefixes** — `/v1/models` was filtered by ID substring, so Codex-owned `gpt-5.5` (no "codex" substring) was invisible and Antigravity-served `gemini-3-flash` never matched "antigravity"; wakes fell through to stale fallback IDs and burned 404/502s before landing somewhere valid. Discovery now prefers the catalog's `owned_by` field (openai / anthropic / antigravity / xai / …) with prefix matching kept as a secondary pass, and the stale fallback lists were replaced with models the backends actually accept.

### Added
- **Kiro models are served to Claude Code** — Neither the bundled proxy nor upstream CLIProxyAPI has a Kiro executor, so a Kiro subscription could never answer a request; the bracketed `[Kiro] …` IDs older builds pinned did not exist. VibeRouter now serves Kiro itself: `kiro/auto`, `kiro/claude-sonnet-4.5`, `kiro/claude-sonnet-4`, and `kiro/claude-haiku-4.5` appear in `/v1/models` and are answered by translating the Anthropic Messages API onto Kiro's CodeWhisperer surface. Multi-turn history, tool calls, tool results, and streaming all round-trip, so the full Claude Code agent loop works against a Kiro plan. Credentials come from the existing Kiro auth file and are refreshed through AWS OIDC when the access token expires. Opus is deliberately not advertised — Kiro rejects every Opus ID on this surface with `INVALID_MODEL_ID`. Token counts in the response are char/4 estimates because Kiro meters in credits and reports no token counts at all.
- **OpenCode Go subscription limits** — The Overview now shows OpenCode Go's three quota windows (5-hour rolling, weekly, monthly) with reset countdowns, read live from `GET https://opencode.ai/zen/go/v1/usage`. OpenCode Go keys are stored as `openai-compat` credentials rather than OAuth seats, so they were previously invisible to the usage cards; they now map to a real `ServiceType` and get a card like any other provider. A key that returns 401 is reported as rejected and a key with no Go entitlement (403) is called out as such, instead of both showing up as an empty card.

### Fixed
- **Claude Code, OpenCode, and Factory no longer autoconfigure to a model that does not exist** — Autoconfigure pinned provider-scoped IDs such as `[Kiro] claude-sonnet-4-5`, `[Codex] gpt-5.5`, and `[Antigravity] claude-sonnet-4-6`. The bundled proxy has no such namespace, so every request against a pinned ID failed with `unknown provider for model`. The writers now resolve a model from the proxy's live `/v1/models` catalog and, when nothing matches, leave `ANTHROPIC_MODEL` unset so the client sends its own default. An already-pinned bracketed value is replaced rather than left in place. Quota-wake fallbacks were cleaned up the same way, and providers the proxy cannot route to (Kiro, Copilot) no longer fall through to universal fallback models, which would have reported a successful wake after pinging a different provider's quota.
- **Kiro Add Account opens AWS Builder ID in the browser** — New Kiro accounts register an OIDC client, start device authorization, copy the user code, and open the verification URL. Existing AWS IdC/Builder ID files are refreshed through `https://oidc.<region>.amazonaws.com/token` (the social `kiro.dev` endpoint cannot revive them). IDE import overlays tokens onto the matching Builder ID file instead of writing a stripped `kiro-kiro-account.json`.
- **Add Account no longer crashes for providers this binary does not OAuth** — The bundled proxy only implements Claude, ChatGPT/Codex, Gemini, Kimi, Antigravity, and Grok login flags. Clicking Add Account for Kiro, Copilot, Cursor, Qwen, CodeBuddy, GitLab, or Kilo spawned a missing `-*-login` flag; Go dumped stdout+stderr and the unsynchronized pipe capture could crash VibeRouter. Login flags are now an allowlist. Cursor / Copilot import a signed-in desktop session; Qwen / CodeBuddy / GitLab / Kilo open paste-JSON. ChatGPT/Codex still uses real `-codex-login`. Auth-process output is captured under a lock.
- **ChatGPT/Codex limits and sessions no longer die on a stale imported copy** — Imported `~/.cli-proxy-api/codex-*.json` files went stale while Codex CLI/desktop kept rotating `~/.codex/auth.json` + the Keychain. Overview then failed to load limits, keep-alive posted the leftover refresh token (`refresh_token_reused`), and OpenAI revoked the whole family — forcing a manual re-login. VibeRouter now adopts the live CLI/desktop token before any usage fetch or refresh, retries once on 401, never treats a still-refreshable session as expired (OpenAI refresh-token JWTs often share the access-token `exp`), fans a rotated token out to every sibling file and back to `~/.codex`, and still fetches limits when the native session is alive.
- **Grok usage limits stay in sync with the live CLI session** — Imported `~/.cli-proxy-api/xai-*.json` copies went stale while `grok` kept refreshing `~/.grok/auth.json`, so Overview could not show SuperGrok's weekly pool even though Grok CLI itself worked. VibeRouter now copies a fresher CLI token onto the imported file, prefers that token for billing, and refreshes through xAI's real OIDC endpoint (`https://auth.x.ai/oauth2/token` with `client_id`). The old `/oauth/token` path is Cloudflare 403 and never rotated tokens; rotated tokens are written back to `~/.grok/auth.json` so the CLI and the menu bar cannot drift apart again.
- **Cursor usage no longer reads as exhausted** — Current `/api/usage-summary` payloads carry a `breakdown` (included/bonus/total) in which `used`/`limit` only count the *included* bucket, so a fully-spent included quota reported `2000/2000` and VibeRouter showed 100% used while 12k bonus units remained and Cursor's own UI said "42%". When a breakdown is present the `*PercentUsed` fields (which match Cursor's displayed percentage) are trusted directly; legacy payloads without one keep the old cents/inversion logic.
- **Codex reset badge no longer lies when offline** — The reset-credits refactor made an unreachable ChatGPT API look identical to "no resets banked"; failures now return nothing to display instead of a false "No rate-limit resets left" chip, both on the card and when redeeming.

### Added
- **Rate-limit reset banks, with one-tap redemption** — The Overview now shows how many banked resets an account holds and lets you apply one in place, the same way the Wake button works for 5-hour windows. **Grok** joins ChatGPT/Codex: SuperGrok's one-time usage resets (the "clear your full weekly pool" tokens from Settings → Usage, expiring Sep 12, 2026) are read live via xAI's `ConsumerUiSvc` gRPC and can be redeemed from VibeRouter — pick the account, confirm, and the weekly pool clears without opening grok.com. Codex reset credits are now redeemable too (`wham/rate-limit-reset-credits/consume`, soonest-expiring credit first), instead of being display-only. The badge, compact row summary, and "Use rate-limit reset" button render automatically for any provider whose snapshot carries a bank, so future providers need only a fetcher.
- **Paste token JSON** on every provider — drop in `~/.codex/auth.json`, Claude credentials, Cursor token JSON, Copilot oauth, Gemini `oauth_creds.json`, or a CLIProxy auth file and the account is added. No browser round-trip required.
- **Cursor subscription** — usage-summary + Stripe profile (Total / Auto + Composer / API / On-Demand) and plan labels (Free / Pro / Pro+ / Business / Enterprise). Switch injects into Cursor’s `state.vscdb`.
- **Multi-instance** — Settings → Instances launches isolated Cursor / Codex / Claude / Antigravity / VS Code Copilot / Kiro / Gemini profiles, each bindable to a VibeRouter account (Cockpit-style `--user-data-dir` / `CODEX_HOME`).
- Import the signed-in Cursor desktop account from local `state.vscdb`.

### Fixed
- **Idle OAuth expiry is not Codex-only** — Claude, Gemini, Kimi, Kiro, and Cursor refresh tokens are now rotated on the same keep-alive loop. Duplicate files that share a refresh token still refresh once and fan the new token out. Native copies (`~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`, Cursor `state.vscdb`) stay in lockstep so a leftover CLI refresh cannot revoke the family.

## [1.3.1] - 2026-08-02

Usage by date, everywhere numbers are shown.

### Added
- **"What did I use on this day?"** — A date picker in the menu bar **Overview** and in the management console top bar, backed by one shared data layer. Pick a day to see that day's tokens, estimated API $, request count, the provider you leaned on most (as a share of spend), and the per-model breakdown.
- **Persisted day history** — Daily totals accumulate in `~/Library/Application Support/VibeRouter/usage-daily.json` (atomic writes, 400-day retention), so history outlives a restart and survives session logs aging out of the scan window. Each scan **replaces** a day's totals per provider rather than adding to them, so refreshing never inflates today.
- **Honest day attribution** — Every provider the Overview counts also appears in the by-date view, so the two can't disagree about a day. Where the per-day figure is weaker, it says so instead of being dropped or dressed up as exact: Copilot reports real day totals but can't name the answering model, and Grok pins a whole session's estimate to its last-active day. OpenCode is read per-turn rather than from its cumulative session row, so a session resumed across several days no longer lands entirely on one.
- **Optional management password** — New Settings toggle, **off by default**: the console is a loopback tool, so a login prompt on a single-user Mac adds friction without adding protection. Turning it on restores the password gate. While auth is off, the server serves the management API only to callers whose TCP peer address is genuinely loopback, and only to same-origin or loopback browser origins — so the port being reachable off-box is not by itself enough to read your keys. It is still an unauthenticated API for anything already running on your Mac; turn the password on if that matters to you.
- Management API: `GET /v0/management/usage-daily` (a day's totals and breakdown) and `GET /v0/management/auth-mode`.

### Security
Both of these were found by an adversarial audit of this release before it shipped, and both were reachable with the default settings.
- **Forwarded headers could forge a loopback caller** — The management API decided "is this caller local" with gin's `ClientIP()`, which honours `X-Forwarded-For` / `X-Real-IP` from any peer because the engine never declared its trusted proxies. With the new password toggle off, that check was the only gate, so `curl -H 'X-Forwarded-For: 127.0.0.1'` from another machine could read plaintext provider keys and linked accounts. Loopback is now judged solely by the TCP peer address, which a header cannot forge. The 5-strike ban is keyed on it too, so an attacker can no longer rotate a header for unlimited key guesses or poison another caller's ban entry.
- **Any website could read the management API from your browser** — Every route answered with `Access-Control-Allow-Origin: *`. That was survivable while a management key was required, but with the password off a management request needs no headers at all, making it a CORS-simple request: any page you happened to visit could `fetch('http://127.0.0.1:8318/v0/management/config')` and read your keys out of the response, or issue a write with no preflight. `/v0/management/*` now refuses browser origins that are neither same-origin nor loopback, before the handler runs, and never echoes the wildcard. The inference endpoints keep the open policy — they require a real API key.

### Fixed
- **Partial days could overwrite complete history** — The per-day scanners filtered log *files* by modification time but not the *days* inside them, so a session file touched today also yielded fragments of days older than the scan window. Since each scan replaces a day's totals per provider, those fragments overwrote complete records that had been saved while the day was current.
- **Large numbers rendered wrong** — `formatTokens` had been copy-pasted into three views with *divergent* tiers: the analytics dashboard handled billions, but the menu bar panel and provider cards stopped at millions, so a 3.1B-token total displayed as `3100.0M`. Every surface now routes through one formatter that scales both up and down — `950`, `12.4K`, `4.2M`, `3.1B`, `2.5T` — and the same rule applies to costs (`<$0.01`, `$18.40`, `$1.2K`) and Kiro credits.
- **"Today" button could vanish after midnight** — A console left open overnight captured today's date once, so the button that returns you to today stayed hidden on a now-stale day. It re-arms at each midnight.
- The same number could round differently in the app and the console (`4.25` → `4.2` vs `4.3`): Swift's `String(format:)` rounds half-to-even, JavaScript's `toFixed` rounds half-away-from-zero. Both now round half away from zero.
- The console's provider-name table was missing Cursor, CodeBuddy, GitLab and Kilo, and mis-cased unknown providers.

### Changed
- The app bundle is now named **VibeRouter.app**, matching the name already shown in the menu bar and About window. Settings and usage history are unaffected — they are keyed on the bundle identifier and a fixed Application Support path, not the bundle filename. Downloadable archives keep their existing space-free names (`VibeRouter-arm64.zip`), so download URLs are unchanged.
- Kiro plan credits are kept out of token totals throughout (they are stored as millicredits, so summing them would inflate a token count ~1000× per credit). Providers are ranked by **cost**, the only basis comparable across unlike units.
- Version **1.3.1**.

### Note
Day history starts accumulating when this version first runs, so dates before that will legitimately read empty.

## [1.2.4] - 2026-07-29

### Fixed
- **Dual “Active” on ChatGPT Team** — Two different users on the same Team org share one `chatgpt_account_id`. Only the login that matches the native Codex session email is marked **Active** now (seat id alone was enough before).
- **Management UI / icons** — Ship the custom management UI in release builds (embedded in `cli-proxy-api-plus`); branded favicon, icon consistency, and reviewed UI wiring bugs.

### Changed
- Release builds compile `cli-proxy-api-plus` from the vendored fork with the custom UI instead of downloading stock upstream.
- Version **1.2.4**.

## [1.2.3] - 2026-07-14

### Fixed
- **Codex multi-subscription switch** — One OAuth login can own Go + Team/Enterprise. Switching the whole account always pinned JWT **Go**. Each subscription row now has its own **Switch to …** control that writes that workspace id into `~/.codex/auth.json` `tokens.account_id`.
- **Cockpit-style app restart** — On switch (when enabled), kill & relaunch Codex/ChatGPT/Claude (and related CLI processes via `pgrep`) so the desktop app actually reloads the chosen account.
- **Grok usage limits** — Prefer live `~/.grok` tokens, skip dead cli-proxy tokens, auto-refresh once on auth failure, and replace cryptic URLSession “unexpected” errors with actionable messages.

### Changed
- Version **1.2.3**.

## [1.2.2] - 2026-07-12

### Fixed
- **Today $ undercount (Grok)** — Running builds before 1.2.1 treated Grok `contextTokensUsed` as total usage (often &lt;$1/day) while Kiro alone filled the Today tile (~$16). Cumulative turn estimate + Composer pricing restore Grok’s share.
- **Grok day bucket** — Prefer `summary.json` `updated_at`/`created_at` over signals mtime so active sessions aren’t dropped from Today.
- **Cost re-scan freshness** — Activity probe walks one level of session dirs so nested Grok/Kiro writes trigger a rescan (root dir mtime often stayed stale).

### Changed
- Analytics provider rows show **today $** under each name so Kiro vs Grok vs Codex is obvious.
- Grok volume marked as estimated tokens.
- Version **1.2.2**.

## [1.2.1] - 2026-07-12

Analytics accuracy and live model pricing.

### Fixed
- **Gemini analytics** — Parse top-level `tokens` (not OpenAI-style `usage`); bill thinking as output; subtract cached from input; **dedupe rewritten message ids** so tool-call rewrites no longer ~2× inflate volume.
- **Codex analytics** — Skip `token_count` re-emits when cumulative usage is unchanged (rate-limit refreshes were over-counting).
- **Grok analytics** — Estimate cumulative tokens from turn count × context growth (was a final-window snapshot undercount); request count from assistant messages.
- **Kiro / Copilot “today”** — Bucket by per-turn / per-message timestamps (and Kiro `created_at` fallback), not file mtime, so resumed sessions don’t dump history into today.
- **OpenCode “today”** — Detect ms vs seconds epoch units; sum today’s rows from the `message` table instead of attributing a whole multi-day session total.
- **Pricing** — GPT-5.6 Sol/Terra/Luna, Grok 4.5 / Composer / Build, DeepSeek V4, Kimi K2.6, Gemini 3.x flash tiers; free/coding-plan $0 remote rows no longer clobber list prices.

### Added
- **Auto-updating list prices** from [models.dev](https://models.dev) (daily TTL + disk cache), with Settings toggle. When off, only the built-in catalog is used.
- Faster cost re-scan when local session roots change (activity mtime probe).

### Changed
- Version **1.2.1**.

## [1.2.0] - 2026-07-10

Full menu bar + Settings UI/UX revamp with Apple **Liquid Glass** styling on macOS 26 (Tahoe), backward compatible with earlier macOS.

### Added
- **Liquid Glass** (macOS 26+) — cards, tiles, buttons, and the segmented tab pill use `.glassEffect`; automatically falls back to the existing translucent material on macOS 13–15 via `if #available`.
- Shared design system: spacing/motion tokens, a sliding segmented tab bar, hover-aware button styles, animated stat tiles, and a pulsing live-status dot.

### Changed
- **Menu bar panel** — pulsing live-status header, icon tabs with a sliding indicator, richer overview strip, redesigned footer, and a clear "Connect a provider" empty state with a call to action.
- **Provider cards, usage bars & analytics** — hover highlights, springier expand/collapse, glossy animated progress bars, and per-provider colored analytics bars.
- **Settings window** — right-sized (was oversized), consistent tabbed navigation with icons, brand-tinted provider icons, and unified color tokens.
- **Panel sizing** — screen-aware height with an explicit popover size so the whole panel always fits on screen (fixes off-screen overflow with many providers).
- Version **1.2.0**.

## [1.1.2] - 2026-07-10

### Fixed
- **Grok usage limits** — Prefer valid `~/.grok/auth.json` tokens over stale cli-proxy OAuth for SuperGrok billing (`GetGrokCreditsConfig`). Empty-body `grpc-status: 7` (bad-credentials) is reported clearly instead of “Could not parse billing usage”.
- **ChatGPT/Codex rate-limit resets** — Fetch `wham/rate-limit-reset-credits` and show remaining manual resets (Cockpit-style) on the usage card.

### Changed
- Version **1.1.2**.

## [1.1.1] - 2026-07-09

### Fixed
- **Menu bar port label** — Proxy port no longer shows a locale thousands separator (e.g. `8,337` → `8337`).

### Changed
- Removed remaining third-party fork/attribution branding; product is VibeRouter only.

## [1.1.0] - 2026-07-09

Analytics accuracy, Kiro quota ground truth, focus-steal fix, and branding cleanup.

### Fixed
- **Settings / focus steal** — Auth/config watchers no longer force Settings to the front. Closed windows clear via `windowWillClose`.
- **Kiro analytics** — Rolling 30-day volume from local session metering only (not billing-period CLI totals).
- **Kiro quota UI** — No invented credit pool; percent-only CLI uses percent display.
- **Volume units** — Credits excluded from global token totals; dashboard formats credits separately.
- **Legacy Opus pricing** — Claude 3 / Opus 4 / 4.1 at $15/$75; 4.5+ at $5/$25.
- **Claude scan roots** — Honors `CLAUDE_CONFIG_DIR/projects`.

### Added
- Local aggregators for Kiro, Grok, OpenCode, and Copilot JB transcripts.
- `kiro-cli /usage` probe (single-flight cache, soft-failure retention, SIGKILL on timeout).
- Expanded token pricing catalog (cache write rates, richer model matching).

### Changed
- Branding is **VibeRouter** only (About, settings footer, docs, copyright).
- Version **1.1.0**.

## [1.0.1] - 2026-07-09

Accurate quotas, status, and menu UX.

## [1.0.0] - 2026-07-09

Initial VibeRouter release — usage limits, account import, session reliability, multi-arch packaging.

### Added
- Live per-account usage cards with streaming updates
- Current-account detection + one-click switching (Codex / Claude / Gemini)
- Auto “wake 5h window” scheduler
- Preferences pane (refresh cadence, analytics window, cost estimates, wake controls)
- Menu-bar usage badge (optional)
- Provider status & incidents
- Local token analytics by provider and model
- Configured account import
- Proactive token refresh
- Multi-arch release packaging (arm64 + x86_64)

### Fixed
- Analytics accuracy (Codex deltas, model name validation, Gemini/Antigravity double-count)
- False session expiry when refresh token remains valid

[1.3.4]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.3.4
[1.3.3]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.3.3
[1.2.4]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.2.4
[1.2.3]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.2.3
[1.2.2]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.2.2
[1.2.1]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.2.1
[1.2.0]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.2.0
[1.1.2]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.1.2
[1.1.1]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.1.1
[1.1.0]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.1.0
[1.0.1]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.0.1
[1.0.0]: https://github.com/Geekyshubham/VibeRouter/releases/tag/v1.0.0
