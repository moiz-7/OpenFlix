# Video Generation Services — Stress-Test & Hardening Report

**Date:** 2026-07-17
**Scope:** The OpenFlix CLI "video generation services" — the seven provider
clients (`fal`, `replicate`, `runway`, `luma`, `kling`, `minimax`, local
ComfyUI), the `GenerationEngine` submit/poll/download orchestrator, the
`VideoDownloader`, the `GenerationStore`, budget accounting, and every path that
reaches a provider: `generate`, `status`, `download`, `retry`, `batch`,
`recipe`, `project`/DAG, scatter-gather, and the MCP server.
**Result:** 10 defects found (3 crash/HIGH, 5 correctness-or-money/MED, 2 LOW).
**All 10 fixed.** Full unit suite **171 passing** (was 155; +16 regression tests).

---

## 1. Executive summary

The provider layer was already hardened in the July‑15 service stress test
(non-finite guards on Replicate, non-destructive downloads, flock'd budget
writes). This round targeted the **generation-specific** surface and the
**non-`generate` entry points** (workflow / MCP / batch / recipe / project /
scatter), which do **not** inherit the flag-level validation that the `generate`
command performs. That gap was the source of the most severe findings: a value
that `generate` rejects at the boundary reaches a provider unchecked from a
workflow, and a `Int(Double)` conversion there **aborts the entire process**.

Theme of the fixes, Karpathy-style: **push the guarantee to the single choke
point, express it as a small pure function, and unit-test that function.** Three
new pure helpers (`GenerationRequest.durationInt`,
`GenerationEngine.preflightEstimate`, `GenerationEngine.validateReferenceImage`)
now carry the invariants that were previously scattered or missing.

---

## 2. Findings & fixes

Severity: **HIGH** = crash / data-or-money loss reachable in normal use ·
**MED** = wrong result, budget error, or silent loss of user input · **LOW** =
resource/DoS footgun requiring a hostile input.

| # | Sev | Defect | Root cause | Fix |
|---|-----|--------|------------|-----|
| 1 | HIGH | Non-finite / huge `--duration` **crashes the CLI** from workflow/MCP/batch/recipe/scatter | 5 provider clients did `Int(request.durationSeconds)`; `Int(.nan/.inf/1e300)` traps. Only `generate` pre-validated duration. | `GenerationRequest.durationInt()` — nil for non-finite/≤0, clamps huge; all 5 providers use it |
| 2 | HIGH | Empty scatter targets **crash the run** (index out of range) | `scatter()` computed `window = max(1, min(8, 0)) = 1` then read `targets[0]` on `[]`. Pinned scatter path can hand in `[]`. | `guard !targets.isEmpty else { return [] }` in `scatter`; honest "no scatter targets" failure in the executor |
| 3 | HIGH→resolved | `Int(1e300)` trap also reachable via batch/recipe/project (agent-confirmed) | Same as #1 — those paths never validated duration | Fixed by #1 (providers no longer trap); documented residual below |
| 4 | MED | **Local reference images silently unusable** — sent as `file://`/scheme-less URLs a remote provider can't fetch; the request is billed then degrades to text-to-video | `generate` built `URL(fileURLWithPath:)`; batch/scatter/DAG built `URL(string: localPath)`. No upload step exists. | `GenerationEngine.validateReferenceImage` rejects non-`http(s)` refs at the single submit choke point (local ComfyUI exempt); `generate` fails fast with an actionable message |
| 5 | MED | **Budget pre-flight bypassed** by omitting `--duration` | Engine estimated `$0` when duration was nil, though the provider bills its default duration; a non-finite duration also made `cps*dur` NaN and `NaN > limit` false | `preflightEstimate()` falls back to a nominal duration and sanitises non-finite, so the gate always runs |
| 6 | MED | **Single-poll `status` success never recorded spend** → budget ledger under-counts | Only `waitForCompletion` called `recordSpend`; the plain `status` path set `actualCostUSD` but not the ledger | Record spend in the single-poll success branch (exactly-once: the record becomes terminal) |
| 7 | MED | **Project cost-budget race** — a concurrent wave can spend up to `maxConcurrency × budget` | Gate summed only `actualCostUSD` (nil for in-flight shots), so all N shots read `$0` and dispatched | Count in-flight shots' `estimatedCostUSD` as reserved, and reserve synchronously at dispatch so the next shot's check sees it |
| 8 | MED | **`retry` silently dropped the reference image and extra params** — resubmitted a *different*, still-billed generation, contradicting its own "same parameters" docstring | `CLIGeneration` never persisted `referenceImageURL`/`extraParams`; retry (CLI + MCP) didn't forward them | Persist both on `CLIGeneration` (optional + defaulted → old records decode fine); forward on both retry paths |
| 9 | LOW | **Unbounded `fanout`** → `Array(repeating:count:)` memory blow-up + flood of paid generations | Validation only rejected `fanout < 1` | `WorkflowSpec.maxFanout = 32` enforced at validation + clamped defensively in the executor |
| 10 | LOW | Scatter-gather linked results with empty `generationId` and produced an empty error string on total failure | Missing `!isEmpty` guard / empty `errorMessage` join | Honest "no scatter targets available…" failure message (see #2 fix) |

### Notable detail per fix

- **#1 `durationInt()`** lives in `OpenFlixKit/ProviderModels.swift` as a pure
  method on `GenerationRequest`: `guard d.isFinite, d > 0 else { nil }; Int(min(d, 3600).rounded())`.
  This is the exact pattern `ReplicateClient` already used — now shared, not
  copy-pasted. `generate` still validates at the flag boundary too
  (defense-in-depth: clamp at the boundary **and** the point of use).
- **#4 honest failure over silent breakage.** No provider uploads local files;
  guessing per-provider base64/multipart support blind (no live keys) is risky,
  so the correct ship-today fix is to **reject with guidance** ("Upload the image
  and pass its URL") rather than bill a doomed request. Matches the codebase's
  established "honest failure" ethos (cf. the AirPlay `.airPlayFormatUnsupported`
  toast).
- **#7 reservation.** `DAGExecutor` is an actor; the budget check + synchronous
  `store.updateShot` reservation contains no `await`, so it is atomic per shot
  and a concurrent shot's check observes the reservation.

---

## 3. What was verified

**Unit (pure logic):** 16 new tests in `GenerationSafetyTests.swift` and
`WorkflowSpecTests.swift`:

- `durationInt`: rounds normal values; returns nil for missing/zero/negative;
  **does not trap** on `.nan`/`±.inf`; clamps `1e30 → 3600`.
- `validateReferenceImage`: allows `http(s)`; rejects `file://` and scheme-less
  paths; exempts the local provider.
- `preflightEstimate`: uses the default duration when nil (gate runs); zero when
  no cost; sanitises non-finite.
- `scatter([])` returns `[]` without trapping.
- `CLIGeneration` round-trips `referenceImageURL` + `extraParams`; legacy records
  without those keys still decode.
- Fanout above `maxFanout` is rejected; the exact max is allowed.

**Runtime (real binary):**

- `--image /tmp/x.png` and `--image ~/pics/cat.png` → rejected with the
  actionable message (exit 1).
- `--image https://…` → passes validation, dry-run succeeds.
- `--duration nan` → "must be positive"; `--duration inf` → "exceeds maximum";
  `--duration 8` → accepted (boundary guard intact).

Full suite: `swift test` → **171 passed, 0 failures**.

---

## 4. Residual / follow-ups (triaged, not blocking)

- **P2 — batch/recipe/project don't validate duration at ingestion.** The crash
  (#1) and budget bypass (#5) are closed, but an absurd/negative duration on
  those paths is now *silently normalised* (→ provider default) rather than
  rejected with a clear error like `generate` gives. Add a shared
  `validateDuration` at those ingestion boundaries.
- **P2 — reference image with spaces/`%` on batch/project paths.**
  `URL(string:)` returns nil for such local paths, dropping the image *before*
  the engine guard can reject it. Once #4's message trains users to pass URLs
  this is rare; a nil-drop warning at ingestion would close it fully.
- **P3 — concurrent spend double-count edge.** Running `generate --wait` and
  `status <id>` on the *same* id simultaneously could record spend twice
  (`recordSpend` is atomic but not idempotent). A per-generation `spendRecorded`
  flag under the store lock would make it exactly-once. Extremely unlikely in
  practice.

---

## 5. Files changed

Providers: `FalClient`, `RunwayClient`, `KlingClient`, `LumaClient`,
`MiniMaxClient` (durationInt). Kit: `ProviderModels` (durationInt).
Core: `GenerationEngine` (ref-image guard, preflight estimate, persist inputs),
`Models` (CLIGeneration fields), `StatusCommand` (record spend),
`ScatterGather` (empty guard), `DAGExecutor` (budget reservation, fanout clamp,
scatter honest-fail), `WorkflowSpec` (maxFanout), `MCPServer` + `RetryCommand`
(forward retry inputs), `GenerateCommand` (reject local image).
Tests: `GenerationSafetyTests` (new), `WorkflowSpecTests` (+1).
