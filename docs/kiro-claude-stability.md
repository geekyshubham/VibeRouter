# Claude Code through Kiro: stability repair

## Automatic account failover repair on 2026-10-05

The October 5 session's HTTP 402 (`MONTHLY_REQUEST_COUNT`) came from the
previous Kiro CLI login. The successful delivery ledger changed account identity
at 07:39 UTC after the native CLI login changed. Adding a saved account alone
could not cause that switch: Kiro's Swift direct handler bypassed the Go auth
manager, selected only the preferred CLI token, and returned 402/429 failures
without trying the remaining configured credentials. The quota card could show
another login's remaining credits while execution remained on the CLI login.

The execution route now discovers both native CLI credential sources and every
enabled `kiro-*.json` account on each turn. It deduplicates tokens, respects
disabled accounts and the Kiro provider toggle, refreshes credentials through
their original source, and supports each account's region/profile ARN.
`KiroAccountPool` maintains shared cooldowns across concurrent sessions and keeps
using the account that successfully served the requested model. Newly added
accounts join without restarting the app.

Before response content arrives, monthly quota failures (402), rate limits
(429), failed authentication/permission checks (401/403), transient upstream
failures and `INVALID_MODEL_ID` try the next enabled Kiro account. The requested
model, conversation ID, history, tool schemas and tool results remain intact.
An account-specific model rejection does not disable that account's other models.
401 first refreshes the original credential once. Monthly quota/auth failures
cool down for 30 minutes, model entitlement failures for 12 hours, and rate or
transient failures for one minute. Freshly configured credentials can recover
without inheriting the previous login's cooldown. Cooldowns are process-local.

Metadata-only events do not prevent failover. After text or a tool event has
arrived, a failure cools down the account for future turns but does not replay
the partially delivered response. Malformed and oversized requests keep their
existing validation/compaction behavior. There is no automatic model downgrade
or switch to another provider for a `kiro/` model.

The existing single-login `accessToken` helper remains for callers that need
that login specifically; execution uses the account pool. Its older isolation
tests therefore still apply to refresh behavior rather than execution failover.

Verification: `python3 scripts/verify-kiro-stability.py` exercises production
Swift objects, synthetic enabled/disabled accounts in temporary directories,
concurrent cooldown selection, authentication refresh, no replay after content,
and real local HTTP 402/model-denial/AWS-event-stream failover. The shared Go
router is covered by 90 provider/status/transport combinations in
`TestProviderAccountsFailOverWithoutLosingConversation`, covering Codex, Claude,
Gemini, Antigravity, xAI and OpenAI-compatible providers. Those paths already
perform account failover and did not require production changes for this issue.

The completed checks passed: 89 Kiro regressions (including 32 new failover
checks), 58 account-isolation regressions and the 90 shared-router combinations
with Go race detection. The release app was ad-hoc signed, signature-verified,
installed at `/Applications/VibeRouter.app` and restarted between requests.
The installed binary matches the generated bundle. A live
`claude-viberouter -p --model kiro/claude-opus-5.5` request returned
`VIBEROUTER_FAILOVER_BUILD_OK`. Native Claude settings retained their SHA-256.
Source snapshots and the previous installed app are backed up under
`~/.local/share/viberouter-recovery/20261005-account-failover-152352/`.


The `claude-viberouter` session used for the regression investigation
reported stalls on long or large-context tasks, image failures, and identical
status for two different Codex workspace members. The route uses
`kiro/claude-opus-5.5`, through the Swift provider rather than the Go backend.

## Changes

- Relay Kiro AWS text events incrementally, send SSE heartbeats every ten
  seconds, and apply backpressure when writing to the client. Cancel the
  upstream request when the client disconnects.
- Decode AWS frames across arbitrary network boundaries. Surface upstream
  exceptions and reject truncated streams, malformed tool inputs, and tool
  calls missing their completion event. Support completed zero-argument tools.
- Translate base64 images, including images inside tool results, into the
  `userInputMessage.images` shape used by the installed Kiro CLI. Decode
  thumbnails with ImageIO, bound dimensions and encoded size, and report
  invalid images instead of silently discarding them.
- Report an estimate of the full local history to Claude, while preserving
  Kiro's actual metered usage in the ledger. Keep historical tool text until
  the request budget requires trimming. Preserve the system prompt, latest
  turn, and active tool pair when trimming; cap Unicode output by bytes.
- Configure the isolated Claude proxy profile for a thirty-minute request
  timeout and earlier automatic compaction. Bound the launcher's health check.
  The Kiro HTTP request ceiling is lower than its advertised 1M model window;
  automatic compaction is still needed for extended sessions.
- Repair escaped lone UTF-16 surrogates without changing valid escapes.
- Recognize dotted Kiro model IDs when translating effort settings.
- Require the same login and workspace when adopting Codex CLI credentials;
  derive identity from token claims and reject contradictory stored labels.
  Filter all credential sources, including native CLI credentials, by login.
  Deduplicate token candidates using the full token digest.
- Allow the CLI health check enough time for the initial Kiro model discovery.

## Verification on 2026-10-01

`python3 scripts/verify-kiro-stability.py` passed 35 checks, linking the actual
production objects. These cover context budgets, Unicode, images, effort,
credential identity, fragmented AWS streams, errors, incomplete tools,
cancellation, and SSE over a real TCP connection. The standard `swift test`
suite could not run because this Mac has Command Line Tools without XCTest.

The opt-in live test is:

```sh
python3 src/Verification/verify-kiro-live.py
```

It requires Pillow and uses Kiro credits. The tests passed on
`kiro/claude-opus-5.5`: incremental text; recognition of color and digits in a
4000×3000 image; a 1,758,422-byte local request that received headers in 0.174s,
two heartbeats during generation, and its correct marker after 23.536s; and
a tool-call/result round trip. The final completion-event change was checked
again with the live tool test (`--tools-only`).

A read-only fork of the original session returned `KIRO_RESUME_OK`. Resume
the preserved original with the proxy launcher:

```sh
claude-viberouter --resume <session-id>
```

The local Codex workspace member credentials were restored from their intact
Cockpit record. Live queries then reported distinct weekly usage for the
two Codex workspace members (27% and 39%). Native Claude settings retained their hash.

The current build is installed at `/Applications/VibeRouter.app`. Previous
installed copies and the generated source-tree app bundle are archived under
`~/.local/share/viberouter-recovery/20261001-161256/` and removed from app
locations. The build scripts can regenerate the source-tree bundle.

## Intermittent INVALID_MODEL_ID repair on 2026-10-02

Claude sessions recorded 32 `INVALID_MODEL_ID` failures, including hourly
clusters around 17:08, 18:09 and 19:08 UTC on October 1. The model was
`kiro/claude-opus-5.5`; the ID also appears in Kiro's live model catalog.
Posting that model with the separate Builder ID credential reproduced the
exact upstream HTTP 400 and `INVALID_MODEL_ID` body.

The direct provider considered a social token expired 120 seconds early.
When `kiro-cli chat --list-models --format json` left a still-valid token
unchanged, the second expiry check rejected it too, and `accessToken()`
silently selected the Builder ID login. That login has different model
entitlements. Selecting the model again after the refresh window appeared
to repair the request because the provider then used the social login again.

The provider now attempts an early refresh but retains the social token
until its actual expiry if the CLI has not rotated it. An expired or
unusable social login returns an authentication failure instead of choosing
another account. Builder ID remains available when no social login exists.
An actor serializes social refreshes across concurrent sessions; 401 retries
also require the original credential. No model downgrade is performed.

`python3 scripts/verify-kiro-stability.py` passed 45 checks, including ten
credential regressions with injected tokens, a fixed clock and no live
credential changes. Cases include an unchanged token with 90 seconds left,
CLI refresh failure, exact expiry, fresh tokens, rotation, persisted tokens
after CLI failure, missing expiry and a Builder ID-only login. The standard
XCTest suite still requires Xcode; this harness links production objects.

The release build was installed at `/Applications/VibeRouter.app`, ad-hoc
signed and verified, and the app was restarted. A real
`claude-viberouter -p` request returned `VIBEROUTER_MODEL_OK` using
`kiro/claude-opus-5.5`; the delivery ledger recorded `cli-social`.
Native `~/.claude/settings.json` retained its SHA-256. The previous app
and pre-edit source snapshots are backed up under
`~/.local/share/viberouter-recovery/20261002-invalid-model/`.


## CLI Builder ID selection and management reporting on 2026-10-02

Kiro CLI can store its current login under `kirocli:odic:token`, rather than
`kirocli:social:token`. The provider now recognizes both keys. A CLI Builder ID
login takes precedence over a separately saved Kiro credential file, and its
refresh remains on that login. The usage ledger records `cli-oidc` so the menu
bar can identify the billed account. Existing social-login behavior is retained.

The production regression harness passed 53 Kiro checks, including fresh,
early-refreshing, expired, and rotated CLI OIDC tokens, credential precedence,
and account attribution. Account-isolation verification passed 58 checks and
the managed API-key store specifications.

Management reporting now reads usage schema 3, matching `UsageDailyStore`, and
shows measured tokens separately from estimates and credits. Unknown schemas
surface as a query error instead of reporting zero. Hidden bookkeeping files
are excluded from auth loading and management lists. Backend tests exercise
actual daily-usage handlers, mixed-unit rows, schema drift, malformed dates,
and bookkeeping exclusion. Browser verification covered all management pages,
automatic refresh, historical dates, account toggles, and mobile widths.
