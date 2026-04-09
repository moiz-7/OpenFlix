# VortexCLI Round 7: Robustness Fixes Report

## Summary

Applied 5 robustness fixes across 10 files, hardening the CLI for production agent use. All 151 tests pass (138 existing + 13 new).

## Fixes Applied

### Fix 1: Eliminate Force-Unwrapped URLs (7 files)
Replaced all `URL(string: "...")!` patterns:
- **ReplicateClient.swift** — `guard let url` for submit endpoint
- **FalClient.swift** — `guard let url` for dynamic model URL
- **RunwayClient.swift** — `private static let base` with lazy init
- **LumaClient.swift** — `private static let base` with lazy init
- **KlingClient.swift** — `private static let base` with lazy init
- **MiniMaxClient.swift** — `private static let base` with lazy init
- **LLMVisionEvaluator.swift** — `guard let url` for Claude API endpoint

Static base URLs use a `static let` closure (evaluated once, fails fast at startup if invalid). Dynamic URLs use `guard let ... else { throw }`.

### Fix 2: Close Pipe File Handles (2 files)
- **LLMVisionEvaluator.swift** — Added `defer { closeFile() }` in `extractFrames()` (2 pipes) and `getVideoDuration()` (2 pipes)
- **HeuristicEvaluator.swift** — Added `defer { closeFile() }` in `runFfprobe()` (2 pipes)

### Fix 3: Duration Upper Bound Validation
- **GenerateCommand.swift** — Added `d > 600` check before model-specific max, producing `"--duration Xs exceeds maximum allowed (600s)."` error

### Fix 4: Flag Degraded Evaluations
- **HeuristicEvaluator.swift** — Added `ffprobeAvailable` field to `FfprobeResult` struct. Set to `false` in all failure/catch paths. Emitted as `dimensions["ffprobe_available"]` (100 = available, 0 = degraded).

### Fix 5: Replicate URL Encoding Fallback
- **ReplicateClient.swift** — Replaced `?? taskId` fallback with `guard let encoded ... else { throw VortexError.invalidResponse(...) }`

## Files Modified

| File | Changes |
|------|---------|
| `Providers/ReplicateClient.swift` | Fix 1 (guard URL), Fix 5 (encoding guard) |
| `Providers/FalClient.swift` | Fix 1 (guard dynamic URL) |
| `Providers/RunwayClient.swift` | Fix 1 (static base URL) |
| `Providers/LumaClient.swift` | Fix 1 (static base URL) |
| `Providers/KlingClient.swift` | Fix 1 (static base URL) |
| `Providers/MiniMaxClient.swift` | Fix 1 (static base URL) |
| `Core/LLMVisionEvaluator.swift` | Fix 1 (guard URL), Fix 2 (pipe close) |
| `Core/HeuristicEvaluator.swift` | Fix 2 (pipe close), Fix 4 (ffprobe_available) |
| `Commands/GenerateCommand.swift` | Fix 3 (600s upper bound) |
| `test.sh` | 13 new tests (132-144) |

## Test Results

```
=== Results: 151 passed, 0 failed ===
```

- 138 existing tests: all pass
- 13 new tests (132-144): all pass
- Includes runtime test: `--duration 999` correctly rejected

## Verification

- `grep -r 'URL(string:.*)\!' Sources/` returns empty — zero force unwraps
- Debug and release builds compile clean
- All pipe file handles have defer-close blocks
