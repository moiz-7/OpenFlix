# Workflow Engine

`openflix workflow run <file.json>` executes a declarative multi-stage pipeline on top of
the existing DAG executor. Every run writes a **run journal**; interrupted or partially
failed runs can be **resumed**; runs are protected by a **budget approval gate**; and every
generation (workflow or not) passes through user **hooks**.

- Format: **JSON now, YAML later.** No YAML dependency exists in this package, and one is
  not worth adding for syntax sugar. `.yaml`/`.yml` files are rejected with
  `yaml_not_supported`.
- All output is JSON on stdout; errors are machine-readable JSON on stderr.
- `--dry-run` never contacts a provider.

## File format (v1)

Top level:

| Field        | Type     | Required | Meaning                                              |
|--------------|----------|----------|------------------------------------------------------|
| `name`       | string   | yes      | Workflow name (becomes the project name)             |
| `budget_usd` | number   | no       | Approval threshold; `--max-spend` overrides it       |
| `stages`     | array    | yes      | Pipeline stages (DAG nodes)                          |

Each stage:

| Field             | Type            | Required | Meaning                                                        |
|-------------------|-----------------|----------|----------------------------------------------------------------|
| `id`              | string          | yes      | Unique stage id (journal node key)                             |
| `needs`           | [string]        | no       | Stage ids that must complete first (DAG edges)                 |
| `prompt`          | string          | one of   | Text prompt                                                    |
| `prompt_from`     | string          | one of   | Copy the resolved prompt of another stage (chains allowed)     |
| `recipe`          | string          | one of   | Recipe id from the local store — pulls prompt/provider/model/params from the recipe (see below) |
| `args`            | {string:string} | no       | Values for the recipe's declared args (`recipe` stages only)   |
| `provider`+`model`| string          | one of   | Explicit provider/model                                        |
| `route`           | `"smart"`       | one of   | Auto-select provider/model via the preference router           |
| `category`        | string          | no       | Smart-routing hint (e.g. `cinematic`)                          |
| `duration`        | number (s)      | no       | Clip duration (cost estimates assume 4s when omitted)          |
| `aspect_ratio`    | string          | no       | e.g. `16:9`                                                    |
| `negative_prompt` | string          | no       | What to avoid                                                  |
| `params`          | {string:string} | no       | Provider extra params (e.g. `{"seed": "42"}`)                  |
| `fanout`          | int >= 1        | no       | Generate N candidates in parallel (scatter-gather)             |
| `judge`           | object          | no       | `{"keep": K, "min_score": X}` — score candidates with the quality evaluators, keep top K, fail the stage if nothing reaches `min_score`. In `--dry-run` judging is skipped with a note. |

Validation errors are structured: `duplicate_stage_id`, `unknown_dependency`,
`cyclic_dependency`, `missing_prompt`, `missing_provider`, `invalid_fanout`,
`invalid_judge`, `unknown_prompt_from`, `yaml_not_supported`, `recipe_conflict`,
`args_without_recipe`, `unknown_recipe`, plus recipe-arg errors (`missing_arg`,
`unknown_arg`, `invalid_number`, `invalid_choice`, `invalid_arg_spec`).

## Recipe-backed stages (composition v1)

A stage may reference a recipe from the local RecipeStore instead of carrying
its own prompt — that's how recipes compose: **recipes referenced from workflow
stages**, not recursive recipe execution.

```json
{
  "name": "recipe-compose",
  "stages": [
    {"id": "hero", "recipe": "<recipe-id>", "args": {"subject": "red panda"}},
    {"id": "closeup", "needs": ["hero"], "prompt_from": "hero",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 4}
  ]
}
```

Rules:

- `recipe` is **XOR** with `prompt`/`prompt_from` (`recipe_conflict` otherwise);
  `args` requires `recipe` (`args_without_recipe`).
- The stage pulls `prompt`, `negative_prompt`, `provider`, `model`, `duration`,
  `aspect_ratio`, and `params` from the recipe. **Stage-level fields override
  recipe fields**; stage `params` merge over recipe params key-by-key.
- The recipe's declared args (formatVersion 3) are resolved from the stage's
  `args` map, falling back to declared defaults; `{{name}}` placeholders in the
  recipe's prompt/negative prompt/param values are substituted. A required arg
  with no default and no stage value fails with `missing_arg`.
- `route: "smart"` still works on a recipe stage: the prompt comes from the
  recipe, provider/model from the preference router.
- The recipe id must exist in the local store (`openflix recipe import` first),
  else `unknown_recipe`.
- Resume hashing covers the recipe id, the stage `args`, and the resolved
  prompt/params — editing the recipe or its args re-executes the stage.
- Recipes may also *declare* composition intent with a `uses` array
  (`[{"recipeId": "...", "args": {...}}]`). In v1 this is carried metadata
  (exported, imported, shown) — execution always flows through workflow stages.

## Example 1 — multi-shot film

Storyboard → 3 shots × fanout 4 → judge keep 1 → extend:

```json
{
  "name": "neon-heist-film",
  "budget_usd": 12.0,
  "stages": [
    {"id": "storyboard",
     "prompt": "storyboard pass: rain-slick neon city, getaway driver waits, 3 beats",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 4},

    {"id": "shot-wide", "needs": ["storyboard"],
     "prompt": "wide establishing shot: rain-slick neon city at night, cinematic",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 5,
     "fanout": 4, "judge": {"keep": 1, "min_score": 60}},

    {"id": "shot-driver", "needs": ["storyboard"],
     "prompt": "medium shot: getaway driver drums fingers on wheel, neon reflections",
     "route": "smart", "category": "cinematic", "duration": 5,
     "fanout": 4, "judge": {"keep": 1, "min_score": 60}},

    {"id": "shot-chase", "needs": ["storyboard"],
     "prompt": "tracking shot: motorcycle chase through wet streets, sparks",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 5,
     "fanout": 4, "judge": {"keep": 1, "min_score": 60}},

    {"id": "extend-finale", "needs": ["shot-chase"],
     "prompt_from": "shot-chase",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 8,
     "params": {"seed": "42"}}
  ]
}
```

```bash
openflix workflow run film.json --dry-run          # plan + cost, no generation
openflix workflow run film.json --stream --yes     # approve and run
openflix workflow run film.json --resume <run-id>  # pick up where it stopped
```

## Example 2 — A/B product spot with cheap draft gate

```json
{
  "name": "product-spot-ab",
  "budget_usd": 3.0,
  "stages": [
    {"id": "draft",
     "prompt": "smartwatch rotating on marble pedestal, studio light, draft quality",
     "route": "smart", "category": "product", "duration": 4},

    {"id": "hero", "needs": ["draft"],
     "prompt": "hero shot: smartwatch rotating on black marble, dramatic rim light, 4k",
     "provider": "fal", "model": "fal-ai/veo3", "duration": 6,
     "fanout": 3, "judge": {"keep": 2, "min_score": 70}}
  ]
}
```

`judge.keep: 2` keeps the two best candidates (`kept_generation_ids`, best first;
`selected_generation_id` is the winner).

## Dry run

`--dry-run` prints the fully resolved plan — stage order, provider/model (smart routing
resolved), fanout counts, per-stage and total cost estimates — and generates nothing.
Judge blocks carry `"note": "judging skipped in dry-run"`.

## Run journal & resume

Every DAG execution (workflow **and** `project run`) writes a journal to
`~/.openflix/runs/<run-id>.json` — one record per node: inputs hash, status, generation
id, output path, cost, timestamps. Writes are incremental (after each node) and atomic
(write-temp-rename). The `run_id` is included in the output JSON.

`openflix workflow run <file> --resume <run-id>`:

- nodes that **succeeded** with an **unchanged inputs hash** are skipped and their
  journaled results reused;
- failed / pending / changed nodes re-execute;
- unknown run ids fail with `run_not_found`;
- output includes `"resumed": {"skipped": n, "executed": n}`.

The inputs hash covers the raw stage spec (resolved prompt, provider/model or the literal
`route`/`category`, duration, aspect ratio, params, fanout, judge, needs) — SHA256 over
canonical sorted-key JSON. Because the *resolved* prompt is hashed, editing an upstream
prompt invalidates every `prompt_from` descendant. Smart-routed stages hash the `route`
field rather than the resolution, so shifting preference data alone does not force
re-execution.

## Budget approval gate

Before executing, the total up-front estimate (provider cost tables:
cost/second × duration × fanout) is checked against `--max-spend` (or `budget_usd` in the
file). Over the limit without `--yes` → structured error `budget_approval_required`, exit 1.
Under the threshold → proceed. BudgetManager's daily/monthly pre-flight limits still apply
on top (`budget_exceeded`), and each node re-checks per-generation limits as usual.

## Hooks

Executable files (any language), applied to **all** generation paths — single `generate`,
`batch`, `project run`, workflow nodes — via the single choke point in
`GenerationEngine.submit` / `waitForCompletion`:

| Hook                            | Stdin                    | Timeout | Nonzero exit                    |
|---------------------------------|--------------------------|---------|---------------------------------|
| `~/.openflix/hooks/pre-generate`  | pending generation spec JSON | 5s  | **Vetoes** (`hook_veto`, hook stderr in detail) |
| `~/.openflix/hooks/post-generate` | result JSON              | 30s     | Logged, never fails the run     |

A pre-hook *timeout* is not a veto: the hook is killed, a `hook_timeout` warning is
emitted, and generation proceeds (a hung hook must never brick every generation path).

```bash
mkdir -p ~/.openflix/hooks
cat > ~/.openflix/hooks/pre-generate << 'EOF'
#!/bin/bash
spec=$(cat)
echo "$spec" | jq -e '(.duration_seconds // 4) <= 10' > /dev/null || {
  echo "durations over 10s need manual approval" >&2
  exit 1
}
EOF
chmod +x ~/.openflix/hooks/pre-generate
```

## Publishing & importing workflows

Share workflow files through the OpenFlix registry:

```bash
# Publish (validates the file locally BEFORE any network call)
openflix workflow publish film.json
openflix workflow publish film.json --name "My Film" --description "Two-stage spot"

# Import by id or full registry URL
openflix workflow import wf_abc123
openflix workflow import https://registry.openflix.app/workflows/wf_abc123
openflix workflow import wf_abc123 --output film.json --force
```

**`workflow publish <file.json>`** — parses and validates the file with the exact
rules `workflow run` uses (any validation error, e.g. `empty_stages` or
`cyclic_dependency`, fails the publish before the registry is contacted), then
`POST {registry}/api/workflows` with `{"name", "description"?, "spec": {<file JSON>}}`.
`--name` defaults to the spec's `name`. Auth: `--token` or the
`OPENFLIX_REGISTRY_TOKEN` env var (same as `recipe publish`; open registries
accept unauthenticated publishes). Output: `{"id", "url", "name", "stage_count"}`.

**`workflow import <id-or-full-url>`** — resolves the reference (a bare id uses
`OPENFLIX_REGISTRY_URL`; a full `…/workflows/<id>` or `…/api/workflows/<id>` URL
pins the host), fetches `GET {registry}/api/workflows/{id}`, credits the
registry's download counter (fire-and-forget — never fails the import),
validates the fetched `spec` locally, and saves it as a runnable workflow file.
Default filename: `<name>.workflow.json` (sanitized); an existing file is never
overwritten without `--force` (`file_exists`). Output:
`{"id", "name", "saved_path", "stage_count"}`.

Structured errors: `file_not_found`, `invalid_workflow_ref`, `fetch_failed`,
`file_exists`, `write_failed`, `publish_failed`, plus all spec-validation codes.

## Notes & limits (v1)

- JSON only; YAML rejected with a clear error (no new dependency for syntax sugar).
- `prompt_from` copies the upstream stage's *prompt text* (chainable); it does not feed
  the upstream *video* forward. Use `params`/reference images for visual continuity.
- Each (non-dry) run materializes a project under `~/.openflix/projects/` and executes on
  the existing DAG executor; `openflix project status <project-id>` works on workflow runs.
- Fanout candidates all use the stage's resolved provider/model; judge scoring uses the
  existing evaluator/quality-gate machinery (heuristic by default).
