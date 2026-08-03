# Phase 3 Wave 4 — Consistency in the Recipe Format

**Date:** 2026-07-05 · **Contract:** docs/phase3-wave-plan.md §Wave 4
**Gauntlet:** swift build 0 warnings · swift test **145/145** (was 128) · test.sh **213/213** (was 211) · registry pytest **103/103** (was 92)

Consistency intent — "these shots should look like the same film" — is now **recorded in
the formats and reproducible at execution time**, not a prompt-engineering vibe.

## 1. Recipe format v3 fields (kit)

New file `Sources/OpenFlixKit/StyleLock.swift`:

```swift
public enum SeedPolicy: String, Codable { case fixed; case perShot = "per_shot" }
public struct StyleLock: Codable {
    public var seedPolicy: SeedPolicy
    public var notes: String?
}
```

`Recipe` and `RecipeBundle.ExportedRecipe` gain **additive optional** fields:

- `referenceImages: [String]?` — reference image paths or URLs
- `styleLock: StyleLock?` — seed policy + free-form notes

`formatVersion` stays an Int and stays **3** — 3 means "has optional extensions";
referenceImages/styleLock are valid in any v3 bundle (there is no 3.1).
`RecipeBundle.formatVersion(for:)` now emits 3 when either field is present; plain
recipes still emit 2 (zero churn for existing files). Both fields ride
`toExported()` / `Recipe(from:)`, `substituting()` (struct copy), and
`jsonRepresentation` (`reference_images`, `style_lock.seed_policy`).

## 2. Workflow stages: `reference_from: <stage-id>`

- **Validation:** unknown or self reference → structured error `unknown_reference`.
  A valid reference **implies a DAG edge**: `WorkflowParser.normalized` adds it to
  `needs` if missing; a reference that closes a loop fails `cyclic_dependency`.
- **Plan + journal record the intent:** dry-run stages and journal nodes carry
  `"reference": {"from": "shot1", "resolved_path": null}`; `resolved_path` fills in at
  execution time (upstream's remote video URL, local path fallback).
- **Execution:** DAGExecutor gained `referenceEdges`; at dispatch (upstream guaranteed
  complete) the upstream output is written into the shot's `referenceImageURL`, which
  the existing plumbing already forwards: `GenerationRequest.referenceImageURL` →
  fal `image_url`, Kling `image` (+ endpoint flip to `image_to_video`), MiniMax
  `first_frame_image`, Luma, Runway. **No provider API params were invented; no kit
  request field had to be added — the plumbing already existed end-to-end.**
- **Honesty:** models with `supportsImageToVideo == false` get the dry-run note
  `"provider does not support reference input"`; intent is still recorded.

## 3. styleLock seed policy + recipe carry

- `WorkflowRecipeResolver.inline` carries `referenceImages`/`styleLock` from
  recipe-backed stages (stage-level override wins); `seedPolicy: fixed` pins the
  recipe's `seed` into stage params.
- `StyleLockSeed` (pure, unit-tested): **fixed** → one seed for every fanout candidate;
  explicit `params.seed` wins, else the seed is derived **deterministically**
  (SHA256 of workflow name + stage id) — same file, same seed, on every run, `--resume`,
  and machine. A random seed would have broken resume (inputs-hash churn) and
  reproducibility, the whole point of the wave. **per_shot** → params untouched
  (current provider-randomizes behavior).
- A stage's (or recipe's) first `reference_images` entry passes through as the shot's
  reference input; `reference_from` output overrides it at dispatch time.
- Inputs hash now covers `reference_from`/`reference_images`/`style_lock` seed policy
  (all optional — hashes of existing workflows unchanged).

## 4. Schema + registry mirror

- `docs/openflix-recipe.schema.json`: `referenceImages` (array of strings),
  `styleLock` (`seedPolicy ∈ fixed|per_shot` required, `notes` optional, lenient about
  unknown sub-fields).
- `registry/server.py`: `_RECIPE_FIELD_TYPES` + `_validate_style_lock` +
  `_validate_reference_images`, wired into `_validate_bundle` → 422 on malformed
  shapes. Workflow-spec validator unchanged by design (unknown stage fields pass
  through); a test pins that `reference_from`/`style_lock` publish fine.

## 5. Exit-gate demo (verbatim, offline)

`openflix workflow run ref-demo.json --dry-run --pretty` for a two-stage file where
shot2 has `reference_from: shot1`:

```json
{
  "dry_run" : true,
  "name" : "two-shot-consistency",
  "stages" : [
    { "id" : "shot1", "provider" : "fal", "model" : "fal-ai/veo3", "fanout" : 2,
      "style_lock" : { "notes" : "keep the robot's glaze identical",
                       "seed" : "820935650", "seed_policy" : "fixed" }, "...": "..." },
    { "id" : "shot2", "provider" : "kling", "model" : "kling-v2.6-pro",
      "needs" : [ "shot1" ],
      "reference" : { "from" : "shot1", "resolved_path" : null }, "...": "..." }
  ],
  "total_candidates" : 3
}
```

test.sh 205/206 pin this (reference intent + fixed seed + implied edge;
`unknown_reference` structured error).

## Files changed

| File | Change |
|---|---|
| `Sources/OpenFlixKit/StyleLock.swift` | **new** — SeedPolicy + StyleLock |
| `Sources/OpenFlixKit/Recipe.swift` | +referenceImages/styleLock, carry + JSON |
| `Sources/OpenFlixKit/RecipeBundle.swift` | +fields on ExportedRecipe, formatVersion(for:) |
| `Sources/openflix/Core/WorkflowSpec.swift` | stage fields, normalized(), unknown_reference, inline carry, StyleLockSeed |
| `Sources/openflix/Core/RunJournal.swift` | NodeReferenceRecord + NodeRecord.reference |
| `Sources/openflix/Core/DAGExecutor.swift` | referenceEdges, dispatch-time resolution, journaling |
| `Sources/openflix/Commands/WorkflowCommand.swift` | seed apply, plan/hash/journal/reference wiring, referenceImageUrl pass-through |
| `Tests/OpenFlixKitTests/StyleLockTests.swift` | **new** — 6 tests |
| `Tests/openflixTests/WorkflowReferenceTests.swift` | **new** — 11 tests |
| `test.sh` | +2 smoke tests (205, 206) |
| `docs/workflows-engine.md` | Consistency section, stage table, journal/hash notes, Example 2 |
| `../docs/openflix-recipe.schema.json` | referenceImages + styleLock |
| `../registry/server.py` | validator mirror |
| `../registry/tests/test_style_lock.py` | **new** — 11 tests |

## Provider wiring: real vs intent-only

- **Real pass-through (pre-existing request plumbing, now fed by reference_from):**
  fal (`image_url`), Kling (`image` + I2V endpoint), MiniMax (`first_frame_image`),
  Luma, Runway.
- **Intent-only:** models flagged `supportsImageToVideo: false` (e.g. `fal-ai/veo3`,
  Hailuo 2.3) — plan/journal record the reference with the honest dry-run note.
  ComfyUI/local: seed flows via `extraParams["seed"]` (fixed policy works); reference
  input depends on the user's graph template (no placeholder invented).

## App-team handoff (kit round-trip)

`Recipe`/`ExportedRecipe` now expose `referenceImages: [String]?` and
`styleLock: StyleLock?` — additive, no renames; nil-safe with all existing bundles.
The app should later: surface a "Style Lock" toggle (fixed/per-shot + notes) and a
reference-image list in the Recipe Editor; persist both in the GRDB recipe table
(new nullable columns + migration); include them in export/import (they already ride
`VortexExportBundle` v2 via ExportedRecipe). Note the pre-existing, unrelated
`referenceImagePaths` field on ExportedRecipe — `referenceImages` is the canonical
Wave-4 field (schema + registry validate it).
