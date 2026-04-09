# Round 4: Agentic Orchestration System — Implementation Report

**Date:** 2026-03-15
**Status:** Complete — 78/78 tests pass (28 new)

---

## Summary

Implemented the full Phase 1 + Phase 2 agentic orchestration system for VortexCLI: batch submission, project/scene/shot data model, DAG execution engine, daemon mode for persistent agent connections, smart provider routing (all 5 strategies), scatter-gather multi-provider dispatch, and cost budget enforcement.

---

## Files Created (18)

| File | Purpose |
|------|---------|
| `Core/ProjectModels.swift` | Project, Scene, Shot, ReferenceAsset, BatchItem, ProjectSpec structs |
| `Core/ProjectStore.swift` | File-locked per-project persistence at `~/.vortex/projects/<id>/` |
| `Core/DAGExecutor.swift` | Kahn's algorithm topological sort + actor-based parallel dispatch |
| `Core/ProviderRouter.swift` | 5 routing strategies + capability matching |
| `Core/ScatterGather.swift` | Multi-provider parallel dispatch with best-result selection |
| `Core/DaemonProtocol.swift` | JSON-RPC message types with AnyCodableValue |
| `Core/DaemonServer.swift` | NWListener Unix domain socket server |
| `Core/DaemonSession.swift` | Per-connection state with event streaming |
| `Commands/BatchCommand.swift` | Parallel batch submission with concurrency control |
| `Commands/ProjectCommand.swift` | Command group container |
| `Commands/ProjectCreateCommand.swift` | Parse spec JSON, resolve deps, validate DAG |
| `Commands/ProjectRunCommand.swift` | Execute DAG with --resume support |
| `Commands/ProjectStatusCommand.swift` | Progress summary with --detail |
| `Commands/ProjectListCommand.swift` | List projects with --status filter |
| `Commands/ProjectDeleteCommand.swift` | Delete project + optional generation cleanup |
| `Commands/ProjectShotCommand.swift` | add/retry/skip/update/remove subcommands |
| `Commands/ProjectExportCommand.swift` | JSON manifest + ffmpeg concat file |
| `Commands/DaemonCommand.swift` | start/stop/status subcommands |

## Files Modified (2)

| File | Changes |
|------|---------|
| `Core/Models.swift` | Added `projectId`, `shotId` optional fields to CLIGeneration |
| `VortexCLI.swift` | Registered Batch, ProjectGroup, Daemon commands; updated help text |

---

## New Tests (28)

| # | Test | Type |
|---|------|------|
| 44 | batch command exists | help |
| 45 | batch requires input | runtime |
| 46 | project command group exists | help |
| 47 | project create exists | help |
| 48 | project run exists | help |
| 49 | project status exists | help |
| 50 | project list exists | help |
| 51 | project delete exists | help |
| 52 | project shot exists | help |
| 53 | project export exists | help |
| 54 | daemon command exists | help |
| 55 | daemon start exists | help |
| 56 | daemon stop exists | help |
| 57 | DAGResolver in source | grep |
| 58 | ProviderRouter in source | grep |
| 59 | ScatterGatherExecutor in source | grep |
| 60 | Routing strategies defined | grep |
| 61 | DaemonServer uses NWListener | grep |
| 62 | Unix socket path configured | grep |
| 63 | ProjectStore file locking | grep |
| 64 | Project status enum complete | grep |
| 65 | Shot status enum complete | grep |
| 66 | BatchItem model defined | grep |
| 67 | project create from spec file | **runtime lifecycle** |
| 68 | project list shows created | **runtime lifecycle** |
| 69 | project delete cleans up | **runtime lifecycle** |
| 70 | debug build with all new files | build |
| 71 | release build with orchestration | build |

---

## Test Results

```
=== Results: 78 passed, 0 failed ===
```

All 50 existing tests continue to pass. All 28 new tests pass including 3 runtime lifecycle tests that create a project from a JSON spec, verify it appears in list, and confirm deletion cleans it up.

---

## Architecture Highlights

- **DAG Executor** uses Swift's `actor` isolation for thread safety and `TaskGroup` for parallel shot dispatch with configurable concurrency limits
- **Provider Router** filters models by capability (I2V support, duration limits) before applying strategy
- **Scatter-Gather** dispatches the same shot to N distinct providers in parallel, picks the first success
- **ProjectStore** follows the exact `withFileLock` + `NSLock` pattern from GenerationStore
- **Batch Command** uses a custom `AsyncSemaphore` actor for concurrency limiting
- **Daemon** uses macOS Network framework (`NWListener`) — no external dependencies added
- **ProjectSpec** uses snake_case CodingKeys to match the agent-friendly JSON format
- **CLIGeneration** extended non-destructively with optional `projectId`/`shotId` fields

---

## Notes & Decisions

1. **No new dependencies** — Daemon uses built-in Network framework, no third-party packages added
2. **Spec format uses shot names for dependencies** — Resolved to UUIDs at create time, validated for cycles
3. **Daemon background mode** suggests `nohup` — proper fork/exec in Swift is complex and out of scope
4. **Cost budget** checked per-shot before dispatch, not mid-generation
5. **AnyCodableValue** enum used instead of `Any` for type-safe Codable JSON-RPC messages
