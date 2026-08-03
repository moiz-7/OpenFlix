# OpenFlixKit Extraction Report (Waves 1–2)

Executed per `docs/openflixkit-plan.md`, option 1: `OpenFlixKit` library target
inside this repo. Mechanical moves only — no redesigns, no renames beyond the
plan (`CLIRecipe` → `Recipe` at the module boundary).

## Gate results (full gauntlet after each wave)

| Gate | swift build | swift test | test.sh |
|---|---|---|---|
| Baseline | 0 warnings | 106 / 0 failures | 205 / 0 failed |
| After Wave 1 | 0 warnings | 106 / 0 failures | 205 / 0 failed |
| After Wave 2 | 0 warnings | 106 / 0 failures | 205 / 0 failed |

Unit tests now split across two targets (106 total): `OpenFlixKitTests`
(RecipeArgsTests 17 + RecipeBundleTests 2 = 19) and `openflixTests` (87,
including the new `RegistryClientTests` that absorbed the one CLI-coupled test
formerly inside RecipeBundleTests).

## Wave 1 — recipe types

Moved into `Sources/OpenFlixKit/` (public + explicit public memberwise inits):

- `RecipeBundle.swift` — `RecipeBundle`, `RecipeBundle.ExportedRecipe`, `RecipeBundle.ExecutionSnapshot`
- `RecipeArgs.swift` — `RecipeArgValue`, `RecipeArg`, `RecipeUse`, `RecipeArgError`, `RecipeArgResolver`, `Recipe.substituting(_:)`, `Recipe.parameterStrings()`
- `Recipe.swift` — the former `CLIRecipe` struct, renamed `Recipe`; includes the pure `toExported()` and `jsonRepresentation`

Stayed in the CLI (`Sources/openflix/Core/RecipeStore.swift`):
- `RecipeStore` (persistence is a CLI decision)
- `typealias CLIRecipe = Recipe` shim — chosen because it is the mechanically
  smallest option: zero CLI call sites churned
- `Recipe.toExported(bestGen: CLIGeneration?)` — thin CLI extension over the
  kit's `toExported()` (it references the CLI-only `CLIGeneration`)

## Wave 2 — provider proof

Moved into `Sources/OpenFlixKit/`:

- `ReplicateClient.swift` — public class, `public init()`, public `parsePollStatus`
- `ProviderProtocol.swift` — public `VideoProvider` protocol + default `cancel`/`estimateCost`; kit-internal `URLSession.jsonData` + `makeSession`
- `ProviderModels.swift` — `CLIProviderModel`, `GenerationRequest`, `GenerationSubmission`, `PollStatus` (out of CLI `Models.swift`)
- `ModelPricing.swift` — moved verbatim, publicized
- `ProviderError.swift` — NEW public error enum (the provider/network split)

Stayed in the CLI:
- `Sources/openflix/Providers/ProviderProtocol.swift` now holds `ProviderRegistry`
  + the CLI-side `jsonData`/`makeSession` (throwing `OpenFlixError`) — path kept
  because test.sh asserts on it, and which providers ship is a CLI decision
- The other 5 provider clients (Fal/Runway/Luma/Kling/MiniMax) — they conform
  to the kit protocol and use kit types via `import OpenFlixKit`

### Error split: option chosen

**`ProviderError` in kit + boundary mapping** (not renaming `OpenFlixError`).
The CLI's `OpenFlixError` keeps its full 14-case surface; **0 catch sites
changed** anywhere in the CLI (vs ~19 catch sites + 18 throw sites for the
"move the name into the kit" option). The kit throws `ProviderError`
(`http_error`, `invalid_response`, `rate_limited`, `cancel_not_supported` —
identical `code` strings), and `OpenFlixError.init(_: ProviderError)`
(Models.swift) maps it at exactly 4 provider-call boundary sites:

1. `GenerationEngine.submit` (provider.submit)
2. `GenerationEngine.waitForCompletion` (provider.poll)
3. `StatusCommand` single poll
4. `CancelCommand.attemptRemoteCancel`

Machine-readable JSON error codes on stderr are byte-identical.

### test.sh path updates (4 assertions, same content checks)

Tests 31/32/134/135 now grep `Sources/OpenFlixKit/ReplicateClient.swift`;
test 196 checks `Sources/OpenFlixKit/ModelPricing.swift` and includes the kit
client in the "no per-model cost constants" grep.

## OpenFlixKit public API surface

Recipe domain: `Recipe`, `RecipeBundle` (+ `ExportedRecipe`, `ExecutionSnapshot`),
`RecipeArg`, `RecipeArgValue`, `RecipeUse`, `RecipeArgError`, `RecipeArgResolver`.
Provider domain: `VideoProvider`, `CLIProviderModel`, `GenerationRequest`,
`GenerationSubmission`, `PollStatus`, `ProviderError`, `ModelPricing`,
`ReplicateClient`.

The kit imports only Foundation. No keychain, store, or Output references
(verified by grep). API keys are parameters.

## App adoption handoff

- Add SPM dependency on this repo (`moiz-7/OpenFlix`), product `OpenFlixKit`;
  pin the `kit-0.1.0` tag (create the tag at push time — not yet created).
- `import OpenFlixKit`
- `.openflix` decode: `try RecipeBundle.decode(fromFile: url)` / `.decode(from: data)`;
  encode: `RecipeBundle(formatVersion: RecipeBundle.formatVersion(for: recipes), exportedAt: Date(), author: author, recipes: recipes).encode()`
- App recipe ⇄ format: `Recipe(from: exportedRecipe, fork: false)` and `recipe.toExported()`
- Arg substitution: `RecipeArgResolver.resolve(args:provided:)` →
  `recipe.substituting(values)` (or `RecipeArgResolver.substitute(text, values:)`)
- Keep GRDB storage — map `VortexRecipe` rows to `Recipe`/`ExportedRecipe`
  only at import/export boundaries.
