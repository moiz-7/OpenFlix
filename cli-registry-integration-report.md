# CLI Registry Integration Report

**Date:** 2026-04-12
**Scope:** Agent B -- CLI Registry Integration (OpenFlix Phase 3)

## Summary

Added registry client and CLI commands that enable publishing, searching, and importing recipes from the OpenFlix public registry server. Also extended the benchmark command with a `--publish` flag to push benchmark results to the registry.

## Changes Made

### 1. New File: `Sources/openflix/Core/RegistryClient.swift`

HTTP client for the OpenFlix recipe registry (`https://registry.openflix.app` by default, configurable via `OPENFLIX_REGISTRY_URL` env var). Provides five static methods:

| Method | Description |
|--------|-------------|
| `publish(bundle:author:)` | POST `.openflix` bundle JSON to `/api/recipes`, returns `(id, url)` |
| `fetch(recipeId:)` | GET `/api/recipes/{id}/bundle`, returns decoded `RecipeBundle` |
| `fetchFromURL(_:)` | GET from arbitrary URL, returns decoded `RecipeBundle` |
| `search(query:category:limit:)` | GET `/api/recipes?q=...&category=...&limit=...`, returns array of dicts |
| `publishBenchmark(results:author:)` | POST benchmark JSON to `/api/benchmarks`, returns `(id, url)` |

All URL constructions use `guard let` (no force-unwraps), consistent with Round 7 robustness standards. Reuses `makeSession()` and `URLSession.jsonData(for:)` from `ProviderProtocol.swift`.

### 2. Modified: `Sources/openflix/Commands/RecipeCommand.swift`

**RecipePublish subcommand** (`openflix recipe publish <recipe-id> [--author "Name"]`):
- Looks up recipe from local store, builds a `RecipeBundle` with the best succeeded generation, and publishes to the registry via `RegistryClient.publish()`.
- Emits JSON with `id`, `url`, `recipe_name`, and `message`.

**RecipeSearch subcommand** (`openflix recipe search [query] [--category X] [--limit N]`):
- Searches the registry via `RegistryClient.search()` and emits JSON with `results` array and `count`.

**RecipeImport extended** (`openflix recipe import [file] [--url <url-or-id>]`):
- `filePath` argument made optional (`String?`).
- New `--url` option: if provided, fetches from registry (bare ID) or full URL.
- If neither `filePath` nor `--url` is given, emits an error.
- Existing file-based import logic preserved.

**Subcommand registration:**
- `RecipePublish.self` and `RecipeSearch.self` added to `RecipeGroup.subcommands`.

### 3. Modified: `Sources/openflix/Commands/RecipeBenchmarkCommand.swift`

- Added `--publish` flag and `--author` option.
- After building the output dict (and before `Output.emitDict(output)`), if `--publish` is set, calls `RegistryClient.publishBenchmark()` and adds `benchmark_id`/`benchmark_url` to the output (or `publish_error` on failure).

### 4. Modified: `test.sh`

Added 5 new tests (169--173):

| # | Test | Type |
|---|------|------|
| 169 | `recipe publish --help` mentions "registry" or "Publish" | CLI help |
| 170 | `recipe search --help` mentions "registry" or "Search" | CLI help |
| 171 | `recipe import --help` mentions "url" | CLI help |
| 172 | `recipe benchmark --help` mentions "publish" | CLI help |
| 173 | `RegistryClient.swift` exists in `Sources/openflix/Core/` | Source check |

## Test Results

```
=== Results: 180 passed, 0 failed ===
```

All 180 tests pass (168 existing + 5 new + 7 pre-existing that were renumbered from the new insertions -- actually the total grew from 168 to 173 test definitions with all passing as 180 individual assertions).

## Files Changed

| File | Action |
|------|--------|
| `Sources/openflix/Core/RegistryClient.swift` | Created |
| `Sources/openflix/Commands/RecipeCommand.swift` | Modified (3 changes) |
| `Sources/openflix/Commands/RecipeBenchmarkCommand.swift` | Modified (2 changes) |
| `test.sh` | Modified (5 new tests) |

## Design Decisions

1. **No force-unwrapped URLs** -- All `URL(string:)` calls use `guard let` to comply with Round 7 robustness checks (test 132).
2. **Optional filePath on import** -- Made `@Argument` optional (`String?`) so `--url` can be used without a positional arg. Both paths still work.
3. **Error handling pattern** -- Follows existing CLI convention: catch `OpenFlixError` specifically for `Output.fail()`, generic errors for `Output.failMessage()`.
4. **Benchmark publish is non-fatal** -- If publishing fails, the error is recorded in `publish_error` but the benchmark output still emits successfully.
