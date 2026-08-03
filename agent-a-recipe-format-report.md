# Agent A: Recipe File Format + RecipeStore + App Integration

## Summary

Implemented the portable `.openflix` recipe bundle format, CLI-side recipe persistence, and app-side recipe export/import functionality. This enables recipes to be shared between the OpenFlix CLI and macOS app via `.openflix` JSON files.

## Changes Made

### 1. RecipeBundle.swift (CLI - NEW)

**File:** `Sources/openflix/Core/RecipeBundle.swift`

Portable `.openflix` recipe bundle format (JSON) for export/import/sharing between app, CLI, and GitHub.

- `RecipeBundle` struct (Codable) with `formatVersion`, `exportedAt`, `author`, `recipes`
- `ExportedRecipe` nested struct with 21 fields covering prompt, provider, model, generation stats
- `ExecutionSnapshot` nested struct for best generation metadata
- `encode()` / `decode(from:)` / `decode(fromFile:)` convenience methods using ISO 8601 dates

### 2. RecipeStore.swift (CLI - NEW)

**File:** `Sources/openflix/Core/RecipeStore.swift`

Local recipe persistence following GenerationStore's exact pattern.

- `CLIRecipe` struct (Codable) with 21 fields, UUID-based ID, JSON output representation
  - `toExported(bestGen:)` converts to `RecipeBundle.ExportedRecipe` for export
  - `init(from:fork:)` creates from imported `RecipeBundle.ExportedRecipe`
  - `jsonRepresentation` for agent-friendly snake_case JSON output
- `RecipeStore` singleton with dual locking (file lock via `flock` + `NSLock`)
  - Stored at `~/.openflix/recipes.json` with lock file at `~/.openflix/recipes.lock`
  - CRUD: `save`, `get`, `all`, `delete`, `update(id:mutate:)`
  - `search(query:)` for name/prompt text search
  - `loadAll()` / `persist()` private helpers matching GenerationStore pattern

### 3. VortexExportBundle.swift (App - MODIFIED)

**File:** `Vortex/Models/VortexExportBundle.swift`

Added v2 recipe-based export format alongside existing v1 project-based format.

- Added `ExportedRecipeV2` nested struct with field names matching CLI's `RecipeBundle.ExportedRecipe`
- Added `exportedRecipes: [ExportedRecipeV2]?` field (nil for v1, populated for v2)
- Added `init(recipes: [VortexRecipe])` convenience initializer for recipe export
- Changed stored property declarations from `let` to `var` to support both init paths
- Updated doc comment to reference `.openflix` extension and describe v1/v2 formats

### 4. PromptStudioView.swift (App - MODIFIED)

**File:** `Vortex/Views/PromptStudio/PromptStudioView.swift`

Added recipe export/import UI integration.

- Added `import AppKit` for NSSavePanel/NSOpenPanel
- Added `@State` properties: `importError`, `showImportError`
- Added "Import Recipe" button (square.and.arrow.down icon) in recipe list header
- Added "Export Recipe" context menu item on each recipe row
- Added `.alert` modifier for import error display
- Added `exportRecipe(_:)` method: creates VortexExportBundle v2, saves via NSSavePanel with `.openflix` extension
- Added `importRecipe(studio:)` method: opens NSOpenPanel for `.openflix` files, decodes bundle, creates VortexRecipe via RecipeService

## JSON Compatibility

The CLI's `RecipeBundle.ExportedRecipe` and app's `VortexExportBundle.ExportedRecipeV2` share identical field names for all 20 common fields. The CLI has 2 extra optional fields (`referenceImagePaths`, `bestExecution`) that safely decode as nil when absent. This ensures bidirectional file compatibility.

## Test Results

- CLI: 151/151 tests pass (no regressions)
- CLI build: clean (debug)
- App build: cannot verify (xcodegen/workspace not generated in current environment)

## Files Created/Modified

| File | Action | Location |
|------|--------|----------|
| `RecipeBundle.swift` | Created | CLI `Sources/openflix/Core/` |
| `RecipeStore.swift` | Created | CLI `Sources/openflix/Core/` |
| `VortexExportBundle.swift` | Modified | App `Vortex/Models/` |
| `PromptStudioView.swift` | Modified | App `Vortex/Views/PromptStudio/` |
