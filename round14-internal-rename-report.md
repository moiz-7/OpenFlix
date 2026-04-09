# Round 14: Internal Rename — vortex → openflix

**Date:** 2026-04-09
**Result:** 151/151 tests pass, build clean

---

## Summary

Renamed all internal "vortex" references to "openflix" across the CLI codebase. The binary was already named `openflix` and the repo is `OpenFlix`, but 216+ internal references still said "vortex." This round eliminates the naming mismatch while preserving backward compatibility for existing users.

---

## Phase 1: Bulk Renames

| Change | Hits | Files |
|--------|------|-------|
| `VortexError` → `OpenFlixError` | ~68 | 25 |
| `struct Vortex:` → `struct OpenFlix:` | 1 | OpenFlixCLI.swift |
| `commandName: "vortex"` → `"openflix"` | 1 | OpenFlixCLI.swift |
| Help text `"vortex ` → `"openflix ` | ~75 | All .swift |
| `the vortex daemon` → `the openflix daemon` | 3 | DaemonCommand.swift |
| `Vortex submits` / `Starts Vortex` / `use Vortex` | 3 | OpenFlixCLI.swift, MCPCommand.swift |
| `vortex://` → `openflix://` | ~8 | MCPServer.swift, MCPToolRegistry.swift |
| MCP server name `"vortex"` → `"openflix"` | 1 | MCPServer.swift |
| `vortex_eval_` → `openflix_eval_` | 1 | LLMVisionEvaluator.swift |
| Package name `VortexCLI` → `OpenFlixCLI` | 1 | Package.swift |
| File rename: `VortexCLI.swift` → `OpenFlixCLI.swift` | 1 | Entry point |

## Phase 2: Keychain Prefix

- **Old:** `com.openflix.vortex` → **New:** `com.openflix.cli`
- Full migration chain: `com.meridian.vortex` → `com.openflix.vortex` → `com.openflix.cli`
- New migration flag: `com.openflix.cli.keychain.v2.migrated`
- Updated 4 hardcoded prefixes in `KeysCommand.swift`

## Phase 3: Data Directory

### 3A: Path replacement
- `.vortex` → `.openflix` across all .swift files
- False positives restored: `com.meridian.vortex` preserved in migration code

### 3B: New file — `DataMigration.swift`
- One-time `~/.vortex/` → `~/.openflix/` directory move
- Guarded by UserDefaults flag `com.openflix.cli.data.migrated`
- Called from `GenerationStore.init()` (earliest common access)
- On failure: logs structured warning to stderr, does not crash

## Phase 4: Environment Variables (Backward Compatible)

New resolution order in `resolveKey()`:
1. `--api-key` flag
2. `OPENFLIX_<PROVIDER>_KEY` (new)
3. `VORTEX_<PROVIDER>_KEY` (old, fallback)
4. `OPENFLIX_API_KEY` (new generic)
5. `VORTEX_API_KEY` (old generic, fallback)
6. macOS Keychain

- `HealthCommand.swift`: checks both `OPENFLIX_*` and `VORTEX_*` prefixes
- Help text updated to show `OPENFLIX_*_KEY` with legacy support note

## Phase 5: test.sh Updates

| Pattern | Change |
|---------|--------|
| `VortexCLI Hardening Tests` | `OpenFlix CLI Tests` |
| `VortexError` grep patterns | `OpenFlixError` |
| `VORTEX_*_KEY` unset lines | Unset **both** `OPENFLIX_*` and `VORTEX_*` |
| `Manage/Start/Stop the vortex daemon` | `...the openflix daemon` |
| `vortex_spec_` / `vortex_fb_` temp prefixes | `openflix_spec_` / `openflix_fb_` |

## Phase 6: Verification

- `swift build` — **Build succeeded** (0 errors)
- `bash test.sh` — **151/151 passed, 0 failed**
- Final grep: only backward-compat refs remain (`VORTEX_*_KEY` fallback, `com.meridian.vortex` migration, `~/.vortex` migration)

---

## What Did NOT Change (By Design)

| Item | Reason |
|------|--------|
| `VortexCLI/` local directory name | Not on GitHub, invisible to users |
| `VORTEX_*_KEY` env vars | Still work as fallback |
| `com.meridian.vortex` in migration code | Old migration source, must stay |
| `com.openflix.vortex` in migration code | Intermediate migration source |
| GUI app internal names | Separate codebase, not in scope |

---

## New Files

| File | Purpose |
|------|---------|
| `Sources/openflix/Core/DataMigration.swift` | One-time `~/.vortex/` → `~/.openflix/` migration |

## Renamed Files

| Old | New |
|-----|-----|
| `Sources/openflix/VortexCLI.swift` | `Sources/openflix/OpenFlixCLI.swift` |
