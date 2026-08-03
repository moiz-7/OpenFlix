# Phase 2: Portable Recipe Format + CLI Recipe Commands + Benchmark Harness

**Date:** 2026-04-12
**Result:** 175/175 CLI tests pass (151 original + 24 new), 198/198 app tests pass, both builds clean
**New commands:** 9 (recipe init/show/list/export/import/fork/run/benchmark + compare)

---

## Summary

Phase 2 makes recipes portable. They can now be exported as `.openflix` files, shared, imported, forked, run from the CLI, and benchmarked across providers. The CLI becomes the automation and distribution surface. The README is rewritten around the recipe primitive.

**Before:** Recipes existed only inside the app's SQLite database. The CLI had no concept of recipes. The README described a utility tool.

**After:** Recipes flow between app and CLI via `.openflix` files. The CLI has a full `recipe` subcommand group (8 commands). A `compare` command enables side-by-side evaluation. 5 example recipes ship in the repo. The README positions OpenFlix as "the reproducible AI video workflow system."

---

## New Files Created (12)

### CLI
| File | Purpose |
|------|---------|
| `Sources/openflix/Core/RecipeBundle.swift` | Portable `.openflix` JSON format (ExportedRecipe + ExecutionSnapshot) |
| `Sources/openflix/Core/RecipeStore.swift` | CLI recipe persistence at `~/.openflix/recipes.json` (CLIRecipe struct + RecipeStore singleton) |
| `Sources/openflix/Commands/RecipeCommand.swift` | RecipeGroup + 7 subcommands (init/show/list/export/import/fork/run) |
| `Sources/openflix/Commands/RecipeBenchmarkCommand.swift` | `recipe benchmark` — runs recipe across multiple providers, evaluates, determines winner |
| `Sources/openflix/Commands/CompareCommand.swift` | `compare` — side-by-side generation comparison with quality evaluation |
| `recipes/cinematic-sunset.openflix` | Example: drone sunset (fal/veo3) |
| `recipes/anime-fight.openflix` | Example: anime sword fight (fal/kling-v2-master) |
| `recipes/product-reveal.openflix` | Example: product showcase (runway/gen4-turbo) |
| `recipes/nature-timelapse.openflix` | Example: mountain timelapse (fal/wan-2.1) |
| `recipes/abstract-morph.openflix` | Example: fluid art (luma/ray-2) |
| `recipes/README.md` | Recipe usage guide |

### App
| File | Purpose |
|------|---------|
| (No new files — modifications to existing) | |

## Files Modified (5)

| File | Change |
|------|--------|
| `OpenFlixCLI.swift` | Registered `RecipeGroup.self` and `Compare.self` |
| `test.sh` | +24 new tests (145-168): recipe subcommand help, CRUD roundtrip, export/import, fork, benchmark, compare |
| `README.md` | Complete rewrite around recipe primitive, quick-start flow, "Why Recipes?" table, CLI command reference |
| `VortexExportBundle.swift` (app) | Added `ExportedRecipeV2` struct, `exportedRecipes` field, v2 recipe export initializer |
| `PromptStudioView.swift` (app) | Added "Export Recipe" context menu item and "Import Recipe" button with NSOpenPanel/NSSavePanel |

## New CLI Commands

| Command | What It Does |
|---------|-------------|
| `openflix recipe init <prompt>` | Create a recipe from parameters |
| `openflix recipe show <id-or-file>` | Display recipe details |
| `openflix recipe list` | List all recipes with optional search |
| `openflix recipe export <id>` | Export to `.openflix` file |
| `openflix recipe import <file>` | Import from `.openflix` file |
| `openflix recipe fork <id>` | Fork with modifications |
| `openflix recipe run <id-or-file>` | Execute recipe (generate video) |
| `openflix recipe benchmark <id-or-file>` | Run across providers, compare results |
| `openflix compare <id1> <id2>` | Compare two generations side-by-side |

## Recipe File Format (`.openflix`)

```json
{
  "formatVersion": 2,
  "exportedAt": "2026-04-12T...",
  "author": "OpenFlix",
  "recipes": [{
    "id": "uuid",
    "name": "Cinematic Sunset",
    "promptText": "...",
    "negativePromptText": "...",
    "provider": "fal",
    "model": "fal-ai/veo3",
    "aspectRatio": "16:9",
    "durationSeconds": 8,
    "category": "cinematic",
    "bestExecution": { ... }
  }]
}
```

## Test Results

- **CLI:** 175/175 (151 original + 24 new), 0 failures
- **App:** 198/198, 0 failures
