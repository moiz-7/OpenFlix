# Phase 2: Agentic Engine — Report

Run journal + resume, declarative workflows, budget approval gate, generation hooks,
and real MCP cancel routing — all composed on the existing engine (DAGExecutor,
ScatterGather, QualityGate, PreferenceRouter, BudgetManager). No new dependencies.

## Results

| Check | Before | After |
|---|---|---|
| `swift test` | 34/34 | **67/67** (+33) |
| `bash test.sh` | 183/183 | **196/196** (+13) |
| `swift build` (debug + release) | clean | clean, zero warnings |

## What was built

### 1. Run journal + resume
- `Core/RunJournal.swift` — journal at `~/.openflix/runs/<run-id>.json`; one `NodeRecord`
  per node (inputs hash, status, generation id, output path, cost, timestamps).
  Incremental (written after each node) and atomic (write-temp-rename). Inputs hash =
  SHA256 over canonical sorted-key JSON of the node spec. `ResumePolicy.shouldSkip` is the
  pure resume decision: skip only `succeeded` + unchanged hash.
- `DAGExecutor` journals every node at a single choke point right after the node finishes.
  Both `project run` and `workflow run` write journals; output includes `run_id`.
- `workflow run --resume <run-id>`: skipped nodes reuse journaled results; failed/pending/
  changed nodes re-execute; unknown run id → `run_not_found`; output includes
  `"resumed": {"skipped": n, "executed": n}`. Verified end-to-end offline (skip on
  unchanged hash with cost carry-over; re-execute on prompt change and on failure).

### 2. `openflix workflow run <file.json>`
- `Core/WorkflowSpec.swift` — minimal v1 format (name, budget_usd, stages with
  id/needs/prompt/prompt_from/provider+model or route:smart/duration/params/fanout/judge).
  **JSON now, YAML later** (no YAML parser exists in the codebase; `.yaml` rejected with
  `yaml_not_supported`).
- `Commands/WorkflowCommand.swift` — parses, validates (duplicates, unknown deps, cycles
  via the existing `DAGResolver`), resolves smart routing via `PreferenceRouter`, builds a
  Project, and executes on the existing `DAGExecutor`.
- Per-stage `fanout: N` runs N candidates through `ScatterGatherExecutor`; `judge`
  scores them with the existing `QualityGate` evaluators and keeps top K
  (`JudgeSelector.selectTopK`, pure). `min_score` failing all candidates fails the stage.
- `--dry-run` prints the resolved plan (stages, fanout counts, per-stage + total est. cost,
  judge "skipped in dry-run" note) with zero provider calls.

### 3. Budget approval gate
- `WorkflowBudgetGate.check` (pure): estimate > (`--max-spend` or `budget_usd`) without
  `--yes` → structured error `budget_approval_required`. Under threshold → proceed.
- Cost math reuses provider cost tables (`WorkflowCost.estimate` = cps × duration × fanout);
  `BudgetManager.preFlightCheck` still applies daily/monthly limits on top.

### 4. Hooks
- `Core/HookRunner.swift` — `~/.openflix/hooks/pre-generate` (5s) and `post-generate`
  (30s), executable files, JSON on stdin. Pre-hook nonzero exit vetoes with structured
  error `hook_veto` (hook stderr in detail); timeout is NOT a veto (warning + proceed) so a
  hung hook can never brick generation. Post-hook exit code logged, never fails the run.
- Wired at the single choke points: `GenerationEngine.submit` (pre) and
  `waitForCompletion` terminal outcomes (post) → covers generate, batch, project shots,
  scatter-gather, and workflow nodes. New `OpenFlixError.hookVeto` / `ErrorCode.HOOK_VETO`.

### 5. MCP cancel routing
- `CancelService.attemptRemoteCancel` extracted from `CancelCommand`; MCP
  `cancel_generation` now attempts the real provider cancel first and preserves the
  local-state flip as fallback on `cancelNotSupported` / network failure. Response gained
  `remote_cancelled` + `note`.

## Files changed

| File | Why |
|---|---|
| `Sources/openflix/Core/RunJournal.swift` (new) | Journal store, inputs hash, resume policy |
| `Sources/openflix/Core/WorkflowSpec.swift` (new) | Format, parser/validator, JudgeSelector, budget gate, cost estimate |
| `Sources/openflix/Core/HookRunner.swift` (new) | pre/post generation hooks with timeouts |
| `Sources/openflix/Commands/WorkflowCommand.swift` (new) | `workflow run` (dry-run, resume, budget gate) |
| `Sources/openflix/Core/DAGExecutor.swift` | Journal choke point + per-shot fanout/judge execution |
| `Sources/openflix/Core/GenerationEngine.swift` | Hook wiring at submit/completion; `var gen`→`let` warning fix |
| `Sources/openflix/Core/Models.swift` | `hookVeto` error case + `HOOK_VETO` code |
| `Sources/openflix/Core/ProjectModels.swift` | Shot gains optional `fanout`/`judge`/`keptGenerationIds` |
| `Sources/openflix/Core/MCPServer.swift` | cancel_generation routes through provider cancel |
| `Sources/openflix/Commands/CancelCommand.swift` | Extracted shared `CancelService` |
| `Sources/openflix/Commands/ProjectRunCommand.swift` | Project runs write journals; output `run_id` |
| `Sources/openflix/OpenFlixCLI.swift` | Register `WorkflowGroup` |
| `Tests/openflixTests/{RunJournal,WorkflowSpec,HookRunner}Tests.swift` (new) | 33 new unit tests |
| `test.sh` | 13 new smoke tests (177–189) |
| `docs/workflows-engine.md` (new) | Format spec, 2 examples, resume/hooks/budget docs |

## Handoff notes
- `project run --resume` (existing bool flag, resets stale shots in place) is unchanged;
  journal-based `--resume <run-id>` lives on `workflow run`, where the project is rebuilt
  from the file each run.
- Each non-dry workflow run materializes a project in `~/.openflix/projects/` (inspectable
  via `project status`); old workflow projects accumulate — a `runs prune` command is a
  natural follow-up.
- `prompt_from` chains prompt *text*, not video output; visual continuity still needs
  reference images/params (v2 candidate: feed upstream last-frame as reference).
- Smart-routed stages hash the literal `route` field so preference-data drift doesn't
  defeat resume; explicit stages hash provider/model.
- Hook stdin payloads assumed < 64KB (pipe buffer); fine for generation specs.
