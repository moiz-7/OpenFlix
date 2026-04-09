# Phase 4: Environment Variable Rename (Backward Compatible)

**Date:** 2026-04-09
**Scope:** Support new `OPENFLIX_*_KEY` env vars while keeping `VORTEX_*_KEY` as fallback

---

## Summary

Updated the OpenFlix CLI to recognize `OPENFLIX_*_KEY` environment variables as the primary
env var names, while preserving full backward compatibility with legacy `VORTEX_*_KEY` names.

## Files Modified

### 1. `Sources/openflix/Core/CLIKeychain.swift`

**Change:** Rewrote `resolveKey()` to implement the 6-step resolution order:

1. `--api-key` flag (unchanged)
2. `OPENFLIX_{PROVIDER}_KEY` env var (NEW)
3. `VORTEX_{PROVIDER}_KEY` env var (legacy fallback)
4. `OPENFLIX_API_KEY` env var (NEW generic)
5. `VORTEX_API_KEY` env var (legacy generic fallback)
6. macOS Keychain (unchanged)

Previously only checked `VORTEX_*` env vars. Now checks `OPENFLIX_*` first, then falls back
to `VORTEX_*`.

### 2. `Sources/openflix/Commands/HealthCommand.swift`

**Changes:**
- Updated provider key detection to check both `OPENFLIX_{PROVIDER}_KEY` and `VORTEX_{PROVIDER}_KEY`
- Updated generic key detection to check both `OPENFLIX_API_KEY` and `VORTEX_API_KEY`
- Updated help text examples to use `openflix` command name
- Added note about checking both env var prefixes in discussion text

### 3. `Sources/openflix/VortexCLI.swift`

**Change:** Updated the ENVIRONMENT VARIABLES section in the help text:
- Listed `OPENFLIX_*` as the primary env var names
- Added note: "Legacy VORTEX_*_KEY variables are still supported as fallback."

### 4. `Sources/openflix/Commands/GenerateCommand.swift`

**Change:** Updated the env var example in help text from:
```
VORTEX_FAL_KEY=your-key vortex generate ...
```
to:
```
OPENFLIX_FAL_KEY=your-key openflix generate ...
```

## Backward Compatibility

All `VORTEX_*_KEY` environment variables continue to work. Users who have set `VORTEX_FAL_KEY`,
`VORTEX_API_KEY`, etc. in their shell profiles will see no breakage. The new `OPENFLIX_*`
names take priority when both are set.

## Notes

- The other agent is concurrently renaming `VortexError` to `OpenFlixError` and the CLI
  entry point struct. A linter/other agent updated the `throw` in `resolveKey()` from
  `VortexError.noApiKey` to `OpenFlixError.noApiKey` -- this is expected.
- No keychain prefix or migration logic was touched (that is the other agent's domain).
