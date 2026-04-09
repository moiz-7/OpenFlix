# Round 5: Intelligence Layer — Implementation Report

## Summary

Phase 3 adds the **intelligence layer** to VortexCLI: pluggable video quality evaluation, provider metrics tracking with learning from feedback, quality gates in the DAG executor, and new CLI commands for evaluation, feedback, and metrics.

## New Files (8)

| File | Purpose |
|------|---------|
| `Core/EvaluatorProtocol.swift` | `VideoEvaluator` protocol, `EvaluationResult`, `QualityConfig` |
| `Core/HeuristicEvaluator.swift` | File size + ffprobe metadata scoring (100pt scale) |
| `Core/LLMVisionEvaluator.swift` | ffmpeg frame extraction → Claude Vision API multimodal scoring |
| `Core/ProviderMetricsStore.swift` | File-locked JSON at `~/.vortex/metrics.json` — tracks quality, latency, cost, success rate per provider+model |
| `Core/QualityGate.swift` | Orchestrator: evaluate → check threshold → pass/retry/accept |
| `Commands/EvaluateCommand.swift` | `vortex evaluate <gen-id> [--evaluator llm-vision]` |
| `Commands/FeedbackCommand.swift` | `vortex feedback <gen-id> --score 85` |
| `Commands/MetricsCommand.swift` | `vortex metrics [--provider fal] [--sort quality]` |

## Modified Files (8)

| File | Changes |
|------|---------|
| `Core/ProjectModels.swift` | Added `qualityScore`, `evaluationReasoning`, `evaluationDimensions`, `qualityRetryCount` to Shot; `qualityConfig` to ProjectSettings; quality spec fields to ProjectSpecSettings |
| `Core/ScatterGather.swift` | Added `qualityScore`/`evaluationResult` to ScatterResult; async `selectBest(_:qualityConfig:)` that evaluates all results and picks highest score |
| `Core/DAGExecutor.swift` | Added `qualityConfig` property; quality gate in `executeSingleShot` (evaluating→pass/retry/accept); provider metrics recording on success/failure |
| `Core/ProviderRouter.swift` | `.quality` strategy now queries `ProviderMetricsStore.rankedByQuality()` with cost-proxy fallback |
| `Core/DaemonProtocol.swift` | Added `evaluate`, `feedback`, `providerMetrics` to DaemonMethods |
| `Core/DaemonServer.swift` | Added handlers for 3 new daemon methods |
| `Commands/ProjectRunCommand.swift` | Added `--evaluate`, `--quality-threshold`, `--evaluator` flags; builds QualityConfig and passes to DAGExecutor |
| `Commands/ProjectExportCommand.swift` | Added quality fields to export entries |
| `Core/ProjectStore.swift` | Applied quality spec fields in `createFromSpec`; updated Shot initializer |
| `VortexCLI.swift` | Registered `Evaluate`, `Feedback`, `Metrics` subcommands |

## Architecture

```
Pluggable Evaluator Protocol
    ├── HeuristicEvaluator (file size, ffprobe metadata, completion status)
    └── LLMVisionEvaluator (ffmpeg frame extraction → Claude Vision API)

QualityGate (orchestrator)
    → Calls evaluator, records metrics, returns pass/retry/accept decision

ProviderMetricsStore (~/.vortex/metrics.json)
    → Tracks avg quality, latency, cost, success rate per provider+model
    → Fed by: evaluations, user feedback, generation outcomes
    → Consumed by: ProviderRouter.quality strategy, MetricsCommand

Integration points:
    → DAGExecutor: quality gate after generation, before marking succeeded
    → ScatterGather: evaluate all results, pick highest score
    → ProviderRouter: .quality uses real metrics instead of cost proxy
```

## Test Results

**105/105 tests pass** (78 existing + 27 new)

### New Tests (27)
- 3 command existence tests (evaluate, feedback, metrics)
- 2 runtime tests (evaluate requires ID, feedback validates score range)
- 7 protocol/struct definition tests (VideoEvaluator, HeuristicEvaluator, LLMVisionEvaluator, ProviderMetricsStore, QualityGate, EvaluationResult, QualityConfig)
- 6 integration grep tests (metrics.json path, ffprobe, Claude API, quality gate check, Shot fields, ProjectSettings)
- 4 wiring tests (ProviderRouter→metrics, ScatterGather async, DAGExecutor config, DaemonMethods)
- 2 flag tests (ProjectRun --evaluate, feedback runtime lifecycle)
- 2 build tests (debug, release)
- 1 runtime lifecycle test (feedback not_found for missing gen)

## Key Design Decisions

1. **Quality gate is advisory**: evaluation failure = pass through (never blocks generation)
2. **Metrics store uses same flock pattern** as GenerationStore for process safety
3. **Quality retries are separate from error retries**: `qualityRetryCount` on Shot, `maxRetries` in QualityConfig
4. **LLM evaluator resolves API key from**: config → `ANTHROPIC_API_KEY` env var
5. **ProviderRouter `.quality` strategy**: real metrics when available, falls back to cost proxy
6. **ScatterGather quality selection**: evaluates all succeeded results, picks highest score
