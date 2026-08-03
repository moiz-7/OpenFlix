# Agent C Report: Benchmark, Compare, Recipes, README

**Date:** 2026-04-12
**Test results:** 175/175 pass (0 failures)

## Changes Made

### 1. RecipeBenchmark Command (NEW)
**File:** `Sources/openflix/Commands/RecipeBenchmarkCommand.swift`

Subcommand registered under `RecipeGroup` as `openflix recipe benchmark`.

- Accepts recipe ID or `.openflix` file path
- `--providers` flag for comma-separated provider targets (default: all with API keys)
- `--dry-run` validates and shows targets without generating
- `--stream` emits NDJSON progress events
- `--timeout`, `--poll-interval`, `--output-dir`, `--api-key`, `--pretty` flags
- For each provider: picks first/default model, runs `GenerationEngine.submitAndWait`
- Runs heuristic quality evaluation on each result video
- Determines winner by quality score > lowest cost > fastest latency
- Individual provider failures are caught and recorded (don't abort entire benchmark)
- Output JSON includes `recipe_id`, `recipe_name`, `prompt`, `results[]`, `winner`, `benchmarked_at`

### 2. Compare Command (NEW)
**File:** `Sources/openflix/Commands/CompareCommand.swift`

Top-level command: `openflix compare <id1> <id2>`

- Fetches both generations from GenerationStore
- Runs heuristic quality evaluation if video exists locally
- Computes latency from submittedAt to completedAt
- Determines winner by: succeeded status > quality score > cost
- Output JSON includes `comparison[]` entries and `winner` with reason

### 3. Example Recipes (NEW)
**Directory:** `recipes/`

5 `.openflix` bundle files with real model IDs from provider registry:
- `cinematic-sunset.openflix` -- fal / fal-ai/veo3
- `anime-fight.openflix` -- fal / fal-ai/kling-video/v2/master/text-to-video
- `product-reveal.openflix` -- runway / gen4_turbo
- `nature-timelapse.openflix` -- fal / fal-ai/wan/v2.1/1080p
- `abstract-morph.openflix` -- luma / ray-2

### 4. Recipes README (NEW)
**File:** `recipes/README.md`

Short practical guide: run, benchmark, import, fork, export, create, format reference.

### 5. README Rewrite
**File:** `README.md` (project root)

Completely rewritten to position OpenFlix around the recipe primitive:
- Quick Start flow: install > key > recipe run > create > benchmark > fork > export
- "Why Recipes?" comparison table
- Surfaces table (CLI vs App)
- Full CLI command reference organized by category
- Provider table with real model names and pricing
- Example recipes section
- Data storage reference

### 6. Registration
- `Compare.self` added to `OpenFlixCLI.swift` top-level subcommands
- `RecipeBenchmark.self` added to `RecipeGroup` subcommands in `RecipeCommand.swift`

### 7. Tests Added (158-168)
- 158: `recipe benchmark --help` works
- 159: `compare --help` works
- 160: `recipe benchmark --dry-run` produces dry_run output
- 161: `--providers` flag exists on benchmark
- 162: `--stream` flag exists on benchmark
- 163: `compare` requires two generation ID arguments
- 164: All 5 example `.openflix` files exist
- 165: All 5 example `.openflix` files are valid JSON
- 166: `recipe show` can parse `.openflix` file (cinematic-sunset)
- 167: `compare` registered as top-level command
- 168: `benchmark` registered under recipe group

## Architecture Decisions

1. **Separate file for RecipeBenchmark** -- avoids merge conflicts with Agent B's RecipeCommand.swift
2. **Compare at top level** -- not nested under recipe since it compares generations, not recipes
3. **Heuristic evaluator only** for benchmark/compare -- LLM vision requires Claude API key, heuristic is always available
4. **Per-provider error isolation** in benchmark -- one provider failure doesn't abort the whole run
5. **Winner selection** -- quality score first, then cost, then latency (quality is the primary differentiator)
