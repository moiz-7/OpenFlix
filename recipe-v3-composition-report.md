# Recipe formatVersion 3, Composition v1, Registry Mirror, Structural Debt

Four tasks, verified separately, full gauntlet at the end. Baseline going in:
swift build clean, `swift test` 67, `test.sh` 196, registry pytest 33.

## Results

| Suite | Before | After |
|---|---|---|
| `swift build` | 0 warnings | **0 warnings** (verified via clean rebuild) |
| `swift test` | 67 | **106** (+39) |
| `bash test.sh` | 196 | **205** (+9) |
| registry `pytest` | 33 | **38** (+5) |

## Task 1 — Recipe formatVersion 3: args

Recipes stop being frozen prompts: v3 adds an optional `args` array
(`name`, `type` string|number|enum, optional `default`/`choices`/`description`).
`{{name}}` placeholders in `promptText`, `negativePromptText`, and string
parameter values are substituted at run time from repeatable
`--arg name=value` flags on `recipe run`, falling back to defaults. A required
arg with no default → structured `missing_arg`; also `unknown_arg`,
`invalid_number`, `invalid_choice`, `invalid_arg_spec`.

- New `Core/RecipeArgs.swift`: `RecipeArg`, `RecipeArgValue` (string-or-number
  Codable), `RecipeUse`, `RecipeArgError`, pure `RecipeArgResolver`
  (validate/resolve/parseArgFlags/substitute), `CLIRecipe.substituting(_:)`.
- `RecipeBundle.ExportedRecipe` and `CLIRecipe` gain optional `args`/`uses`
  (v2 files and existing stores decode unchanged — fields are optional).
- Export/publish write `formatVersion: 3` **only** when args/uses exist
  (`RecipeBundle.formatVersion(for:)`), else stay 2 — no churn of existing files.

Example v3 recipe:

```json
{
  "formatVersion": 3,
  "exportedAt": "2026-07-04T00:00:00Z",
  "recipes": [{
    "id": "aaaaaaaa-0000-0000-0000-000000000001",
    "name": "Param Sunset",
    "promptText": "a {{subject}} at golden hour, {{style}} style",
    "negativePromptText": "",
    "provider": "fal",
    "model": "fal-ai/minimax/hailuo-02",
    "durationSeconds": 5,
    "args": [
      {"name": "subject", "type": "string", "description": "main subject"},
      {"name": "style", "type": "enum", "default": "cinematic", "choices": ["cinematic", "anime"]}
    ]
  }]
}
```

```bash
openflix recipe run sunset.openflix --arg subject=fox --wait
```

## Task 2 — Composition (minimal honest v1)

Workflow stages gain `recipe: "<recipe-id>"` (XOR with `prompt`/`prompt_from`)
plus optional `args`. The stage pulls prompt/provider/model/duration/aspect
ratio/params from the local RecipeStore copy, applies declared args, and
stage-level fields override recipe fields. Recipes may declare
`uses: [{"recipeId": ..., "args": {...}}]` — carried/exported metadata in v1;
execution always flows through workflow stages (no recursive recipe execution).

```json
{"id": "hero", "recipe": "<recipe-id>", "args": {"subject": "red panda"}}
```

- `WorkflowRecipeResolver.inline(stage:recipe:)` — pure, unit-tested (arg
  substitution, defaults, overrides, `unknown_recipe`, `missing_arg`,
  `missing_provider`, route:"smart" interplay).
- New validation errors: `recipe_conflict`, `args_without_recipe`,
  `unknown_recipe`. Resume hashing covers recipe id + stage args + resolved
  prompt/params.
- `docs/workflows-engine.md` updated (new stage fields + "Recipe-backed
  stages" section).

## Task 3 — Schema + registry

- `docs/openflix-recipe.schema.json` (monorepo): formatVersion 2-or-3
  description, optional `args`/`uses` schemas, `$comment` naming the CLI
  files as source of truth. `additionalProperties` stays true. Verified with
  `jsonschema` against real v2/v3 bundles.
- `registry/server.py` `_validate_bundle` mirror: v2 unchanged;
  args/uses validated whenever present (`_validate_recipe_args`,
  `_validate_recipe_uses`) — malformed → 422.
- Tests: v3 publish + bundle roundtrip, v2 unchanged, v2-with-args accepted,
  11 malformed-args cases, 5 malformed-uses cases.

## Task 4 — Structural debt

- **(a) GenerationStore per-record files:** `~/.openflix/generations/<id>.json`
  (mirrors ProjectStore), transparent one-time migration from legacy
  `store.json` on first access (under the existing flock; original kept as
  `store.json.migrated`; corrupt legacy file left untouched with a stderr
  warning). Public API identical. Existing per-id files win over legacy copies.
- **(b) Single pricing table:** new `Core/ModelPricing.swift` — all 23
  model prices + per-provider fallbacks. Provider catalogs build via
  `CLIProviderModel.priced(...)`; the six duplicated `estimateCost` bodies are
  deleted in favor of one `VideoProvider` extension. A unit test asserts every
  catalog model has an explicit table entry.
- **(c) Budget file lock:** `BudgetManager` wraps `recordSpend`/
  `resetDailySpend` read-modify-write in `flock()` on
  `~/.openflix/daily_spend.lock`, invalidating the in-process cache inside the
  lock so cross-process increments are never lost.

## Deferred (by design)

Full OpenFlixKit extraction — see `docs/openflixkit-plan.md` for what moves
(recipe types first, ReplicateClient as proof), the repo-topology question,
recommendation (kit target inside the CLI repo, adopted via versioned git
dependency once the app commits), and effort (~1 sprint).

## Files changed

CLI (`VortexCLI/`):
- `Sources/openflix/Core/RecipeArgs.swift` — new: arg types + pure resolver/substitution
- `Sources/openflix/Core/RecipeBundle.swift` — args/uses on ExportedRecipe; version helper
- `Sources/openflix/Core/RecipeStore.swift` — CLIRecipe args/uses carry-through
- `Sources/openflix/Core/WorkflowSpec.swift` — stage recipe/args, 3 new errors, WorkflowRecipeResolver
- `Sources/openflix/Core/GenerationStore.swift` — per-record rewrite + legacy migration
- `Sources/openflix/Core/ModelPricing.swift` — new: single pricing table
- `Sources/openflix/Core/BudgetManager.swift` — flock around spend writes
- `Sources/openflix/Commands/RecipeCommand.swift` — --arg flag; v3 export/publish version
- `Sources/openflix/Commands/WorkflowCommand.swift` — recipe-stage inlining; hash/plan fields
- `Sources/openflix/Commands/HealthCommand.swift`, `ListCommand.swift`, `DeleteCommand.swift`, `OpenFlixCLI.swift`, `README.md` — store path references
- `Sources/openflix/Providers/*.swift` (6 clients) — .priced catalogs; estimateCost deduped into ProviderProtocol.swift
- `Tests/openflixTests/RecipeArgsTests.swift` (16), `WorkflowRecipeTests.swift` (11), `GenerationStoreTests.swift` (6), `ModelPricingTests.swift` (6) — new
- `test.sh` — tests 190–198
- `docs/workflows-engine.md` — composition section
- `docs/openflixkit-plan.md` — new design note

Monorepo touchpoints:
- `docs/openflix-recipe.schema.json` — v3 args/uses
- `registry/server.py` — v3 mirror validation
- `registry/tests/test_server.py` — +5 tests
