# Smart Routing + Quickstart Report (Roadmap Phase 1: CLI Parity)

## What was built

### 1. `--route smart` on `openflix generate`
Preference-aware routing fed by the registry's aggregate data
(`GET {registry}/api/preferences/summary`).

- `--provider` / `--model` are now optional; `--route smart` auto-selects among
  providers the user has keys for that fit the request (I2V capability, duration).
- New `--category` option hints the request category (e.g. `cinematic`, `anime`).
- Selection: highest Laplace-smoothed win rate for the category; falls back to
  the overall (server-smoothed) `win_rate` when the category has < 5 events.
- Cache: `~/.openflix/preference_summary.json`, 24h TTL by file mtime.
- Resilience ladder (a generation never fails because the registry is down):
  fresh cache → network fetch (result cached) → stale cache (stderr warning)
  → default cheapest-capable routing (stderr warning, `"fallback": true`).
- The routing decision is explained in the JSON output under `"routing"`.

Example (network path):
```json
"routing" : {
  "category" : "cinematic",
  "category_events" : 35,
  "chosen" : "runway/gen4_turbo",
  "fallback" : false,
  "mode" : "smart",
  "source" : "network",
  "used_category_stats" : true,
  "win_rate" : 0.8378
}
```

Example (registry down, no cache):
```json
"routing" : {
  "category" : "cinematic",
  "chosen" : "kling/kling-v2.5-turbo",
  "fallback" : true,
  "fallback_reason" : "preference data unavailable (registry unreachable, no cache)",
  "mode" : "smart",
  "source" : "none"
}
```
Warnings go to stderr as machine-readable JSON
(`{"code":"smart_routing_fallback","warning":"..."}`), keeping stdout pure.

### 2. `openflix quickstart`
Guided onboarding around THE LOOP (generate → compare → vote → publish):
- Checks configured provider keys locally (flag/env/keychain — no network).
- Prints 5 copy-pasteable commands, using a real recipe from `recipes/` when
  running from a repo checkout.
- Mentions `--dry-run`, `openflix budget set`, `recipe list` / `recipe search`
  / `recipe publish`.
- Plain text stdout (matches the `--help` convention; every other command is
  JSON); `--json` wraps the same content in `{"text": ...}` for agents.

## Files changed
- `Sources/openflix/Core/PreferenceRouter.swift` — NEW: summary contract structs,
  `PreferenceSummaryCache` (injectable directory, TTL), pure `select()` math,
  `loadSummary()` fallback ladder, `decide()` for the generate command.
- `Sources/openflix/Core/RegistryClient.swift` — added `fetchPreferenceSummaryData()`.
- `Sources/openflix/Commands/GenerateCommand.swift` — `--route` / `--category`,
  optional provider/model, `routing` key in dry-run/submit/wait outputs.
- `Sources/openflix/Commands/QuickstartCommand.swift` — NEW: onboarding command.
- `Sources/openflix/OpenFlixCLI.swift` — registered `Quickstart` subcommand.
- `Tests/openflixTests/PreferenceRouterTests.swift` — NEW: 12 tests.
- `test.sh` — 3 new smoke tests (174–176), all offline.

## Test results
- `swift build`: clean (no code warnings).
- `swift test`: **34/34 pass** (22 existing + 12 new PreferenceRouterTests).
- `bash test.sh`: **183/183 pass** (180 existing + 3 new).
- Runtime: quickstart output verified; smart dry-run verified offline (fallback)
  and against a local mock registry on 127.0.0.1 (network path, cache write).
  No live provider API calls were made (dry-run only).

## Handoff notes
- Registry team: CLI decodes only `models[]` (`model`, `provider`, `wins`,
  `losses`, `win_rate`, `categories{cat:{wins,losses}}`), `total_events`,
  `generated_at`; `pairs` is accepted and ignored. `win_rate` is used as-is
  (assumed Laplace-smoothed server-side); category rates are smoothed
  client-side as `(wins+1)/(wins+losses+2)`.
- Cache is the raw payload byte-for-byte, so future contract additions are
  preserved on disk.
- `PreferenceRouter.decide()` is reusable if `batch` / `project run` want a
  `smart` strategy later (it mirrors `ProviderRouter`'s capability filters).
- Matching is exact on `(provider, model)` pairs vs the CLI's
  `ProviderRegistry` model IDs — if the registry uses different model ID
  spellings, candidates silently fall through to the cheapest fallback.
- Threshold `minCategoryEvents = 5` is a constant in `PreferenceRouter`.
