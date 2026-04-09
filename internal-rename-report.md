# Internal Rename Report: vortex -> openflix

**Date:** 2026-04-09
**Scope:** Complete internal rename of all "vortex" references to "openflix" across the CLI codebase
**Result:** Build succeeds, 151/151 tests pass

---

## Phase 1: Bulk Replacements (12 Steps)

| Step | Change | Files Affected |
|------|--------|----------------|
| 1 | `VortexError` -> `OpenFlixError` | 25 files (Models.swift, all providers, commands, core) |
| 2 | `struct Vortex:` -> `struct OpenFlix:` | OpenFlixCLI.swift |
| 3 | `commandName: "vortex"` -> `"openflix"` | OpenFlixCLI.swift |
| 4 | Help text `vortex ` -> `openflix ` | All command files |
| 5 | `"the vortex daemon"` -> `"the openflix daemon"` | DaemonCommand.swift |
| 6 | `"Vortex submits"` / `"Starts Vortex"` / `"use Vortex"` -> OpenFlix | MCPCommand.swift, OpenFlixCLI.swift |
| 7 | `vortex://` -> `openflix://` | MCPServer.swift, MCPToolRegistry.swift |
| 8 | MCP server name `"vortex"` -> `"openflix"` | MCPServer.swift |
| 9 | MCP config example key/command | MCPCommand.swift |
| 10 | `vortex_eval_` -> `openflix_eval_` | LLMVisionEvaluator.swift |
| 11 | Package name `VortexCLI` -> `OpenFlixCLI` | Package.swift |
| 12 | Renamed `VortexCLI.swift` -> `OpenFlixCLI.swift` | File rename |

## Phase 2: Keychain Prefix Migration

**Changed:** `com.openflix.vortex` -> `com.openflix.cli`

### CLIKeychain.swift (complete rewrite)
- `servicePrefix` = `"com.openflix.cli"` (new canonical prefix)
- `oldServicePrefix` = `"com.meridian.vortex"` (v1 legacy)
- `midServicePrefix` = `"com.openflix.vortex"` (v2 intermediate)
- Two-step migration chain:
  1. `com.meridian.vortex.*` -> `com.openflix.cli.*` (guarded by `migrationFlagV1`)
  2. `com.openflix.vortex.*` -> `com.openflix.cli.*` (guarded by `migrationFlagV2`)
- `resolveKey` priority: `OPENFLIX_*_KEY` env -> Keychain -> `VORTEX_*_KEY` env (legacy fallback) -> `OPENFLIX_API_KEY` env -> `VORTEX_API_KEY` env (legacy)

### KeysCommand.swift
- 4 hardcoded `"com.openflix.vortex.\(provider)"` -> `"com.openflix.cli.\(provider)"`

## Phase 3: Data Directory Migration

### 3A: Path Replacements
`.vortex` -> `.openflix` in 8 files:
- HealthCommand.swift
- VideoDownloader.swift
- GenerationStore.swift
- DaemonServer.swift
- ProviderMetricsStore.swift
- ProjectStore.swift
- BudgetManager.swift
- ProjectExportCommand.swift

**Preserved** (migration code, intentionally kept):
- `com.meridian.vortex` in CLIKeychain.swift
- `com.openflix.vortex` in CLIKeychain.swift
- `VORTEX_*_KEY` env var fallbacks in CLIKeychain.swift, HealthCommand.swift, OpenFlixCLI.swift

### 3B: DataMigration.swift (new file)
- Created `Sources/openflix/Core/DataMigration.swift`
- One-time migration of `~/.vortex/` -> `~/.openflix/` directory
- Guarded by `UserDefaults` flag `com.openflix.cli.data.migrated`
- Safe: skips if `~/.openflix/` already exists or `~/.vortex/` doesn't exist
- Called from `GenerationStore.init()` before directory creation

## Remaining Legacy References (Intentional)

All remaining "vortex" strings in the codebase are intentional backward-compatibility code:
1. **CLIKeychain.swift** -- Migration chain from old keychain prefixes
2. **DataMigration.swift** -- References to old `~/.vortex/` directory being migrated
3. **HealthCommand.swift** -- Legacy `VORTEX_*_KEY` env var detection
4. **OpenFlixCLI.swift** -- Help text documenting legacy env var support
5. **GenerationStore.swift** -- Comment on migration call

## Verification

- `swift build` -- Build succeeded (0 errors, 1 pre-existing warning)
- `test.sh` -- 151/151 tests passed
- Grep audit -- All remaining "vortex" references confirmed as intentional migration/legacy code
