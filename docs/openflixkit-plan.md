# OpenFlixKit extraction — design note (deferred)

Status: **deliberately not done this sprint.** Karpathy rule: no abstraction
before the third consumer. Today the CLI is the only consumer of these types —
the macOS app has its own parallel implementations (GRDB-backed `VortexRecipe`,
its own provider clients) and has not adopted any shared code. A rushed module
split risks the 205-test shell baseline and 106-unit-test baseline for zero
user value this week. This note is the plan for when a second consumer is real.

## What would move, in order

**Wave 1 — recipe types (pure, zero dependencies beyond Foundation):**

| Type | File today |
|---|---|
| `RecipeBundle` (+ `ExportedRecipe`, `ExecutionSnapshot`) | `Sources/openflix/Core/RecipeBundle.swift` |
| `RecipeArg`, `RecipeArgValue`, `RecipeUse`, `RecipeArgError`, `RecipeArgResolver` | `Sources/openflix/Core/RecipeArgs.swift` |
| `CLIRecipe` (rename → `Recipe`; drop the `CLI` prefix at the module boundary) | `Sources/openflix/Core/RecipeStore.swift` (type only — the store stays in the CLI) |

These are pure Codable structs + pure functions with unit tests already
(RecipeArgsTests, RecipeBundleTests). They are the .openflix format's source of
truth, which is exactly what the app should share instead of re-implementing
export/import (`VortexExportBundle` v2 in the app is a second, drifting copy).

**Wave 2 — one provider client as proof:** `ReplicateClient` +
`ProviderProtocol` (`VideoProvider`, `GenerationRequest`, `GenerationSubmission`,
`PollStatus`) + `ModelPricing`. Proves the networking layer can live in the kit
(no keychain, no store, no Output dependencies — API keys are passed in).
`OpenFlixError` must split: provider/network cases move; CLI-only cases
(`hook_veto`, etc.) stay.

**Stays in the CLI:** all Commands, Output (JSON-first stdout contract),
CLIKeychain, the stores (GenerationStore/RecipeStore/ProjectStore — file
layout is a CLI persistence decision), DAGExecutor/daemon/MCP server.

## Import changes

- `Package.swift`: add `.target(name: "OpenFlixKit")`; the `openflix`
  executable target depends on it. Internal types crossing the boundary become
  `public` (the real cost — ~30 types need access-level annotations and
  public memberwise inits, which Swift does not synthesize).
- CLI files: `import OpenFlixKit` where recipe/provider types are used
  (roughly 20 files by today's grep).
- Tests split: `OpenFlixKitTests` (pure) vs `openflixTests` (CLI glue);
  `@testable import` lines change accordingly.

## Repo topology — the real question

The CLI repo (`VortexCLI/`, pushed as `moiz-7/OpenFlix`) is **nested and
gitignored inside the VidViewer monorepo**; the app lives in the monorepo.
Once the repos are separate, the app **cannot** use a
`.package(path: "../VortexCLI/OpenFlixKit")` dependency — path deps don't
cross repo boundaries for anyone who clones only one of them, and CI for the
app would need the CLI checkout present at a fixed relative path.

Options:

1. **Kit inside the CLI repo** (`OpenFlixKit` target in `VortexCLI/Package.swift`),
   app consumes it as a versioned SPM *git* dependency on the public
   `moiz-7/OpenFlix` repo. Cheapest to start; app pins a tag; the CLI repo
   becomes the format's canonical home (matches the schema `$comment`).
2. **Separate `OpenFlixKit` repo.** Cleanest layering, but a third repo to
   version/tag/keep green for a library with (today) one consumer. Premature.
3. **Move the CLI into the monorepo properly.** Undoes the public-repo
   strategy (the monorepo has non-public surfaces). Rejected.

**Recommendation: option 1**, executed only when the app actually adopts the
kit (its first real import — likely `.openflix` encode/decode + arg
substitution, replacing `VortexExportBundle`). Tag the CLI repo `kit-0.1.0`
at extraction time so the app pins a version, not `main`.

## Effort estimate

- Wave 1 (recipe types + access levels + test split + CI still green):
  ~0.5–1 day. Low risk — pure types.
- Wave 2 (ReplicateClient + protocol + error split): ~1–1.5 days. Medium
  risk — `OpenFlixError` split touches every command's catch blocks.
- App adoption (replace `VortexExportBundle` with kit types, keep GRDB
  storage): ~1–2 days on the app side, plus xcodegen/pod wiring for the SPM
  dependency.

Total: roughly one focused sprint, gated on the app team committing to adopt
Wave 1 — otherwise the kit is dead weight.
