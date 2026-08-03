# Phase 1: Recipe Entity + Intelligence Flywheel

**Date:** 2026-04-12
**Result:** 198/198 app tests pass (182 existing + 16 new), 151/151 CLI tests pass
**Build:** Clean, 0 errors

---

## Summary

Phase 1 transforms OpenFlix from a disconnected multi-provider video generation tool into a self-improving system centered on the **Recipe** primitive and a **unified preference flywheel**.

**Before:** Comparison Theater votes were ephemeral. SmartRouter ignored Arena data. No reproducible creative object existed. The intelligence gears were disconnected.

**After:** Every vote (Arena, Comparison, Scatter-Gather) flows through PreferenceEventService into persistent preference events that feed Elo ratings AND a new preference-aware SmartRouter strategy. Recipes capture the full reproducible specification. The system gets smarter with every vote.

---

## New Files Created (7)

| File | Purpose |
|------|---------|
| `OpenFlix/Persistence/Database+Recipe.swift` | Recipe + PreferenceEvent CRUD (extension on OpenFlixDatabase) |
| `OpenFlix/Vortex/Services/RecipeService.swift` | Recipe CRUD, fork, stats tracking, auto-create from prompt |
| `OpenFlix/Vortex/Services/PreferenceEventService.swift` | Centralized preference hub: records events, delegates to Elo, updates recipe stats |
| `OpenFlixTests/RecipeTests.swift` | 8 tests: insert/fetch/update/delete, FK linkage, fork, preference events, win rate |
| `OpenFlixTests/RecipeServiceTests.swift` | 5 tests: create, fork, generation completed, win/loss, auto-create |
| `OpenFlixTests/PreferenceWiringTests.swift` | 3 tests: preference recording, scatter-gather, draw |

## Files Modified (11)

| File | Change |
|------|--------|
| `VortexModels.swift` | Added `VortexRecipe` struct (24 fields), `VortexPreferenceEvent` struct, `recipeId` on VortexGeneration/VortexStoryboardShot/VortexArenaSession |
| `VortexEnums.swift` | Added `ForkType`, `PreferenceEventType` enums. Updated `VortexSection`: renamed promptStudio→"Recipe Editor", community→"Recipe Library", added `sectionGroup`/`orderedGroups`/`sections(in:)` |
| `Database.swift` | Added migrations v9 (recipe table + recipeId FKs + indexes) and v10 (preferenceEvent table + indexes). Changed `dbQueue` to `internal` for extension access. |
| `SmartRouterService.swift` | Added `.preferenceAware` strategy with Laplace-smoothed win rate routing by category. Falls back to balanced when <10 events. |
| `GenerationQueueService.swift` | Hooks recipe stats update on generation completion (increments generationCount, updates avg quality, accumulates cost) |
| `ModelArenaViewModel.swift` | Routes all votes (manual + auto-eval) through PreferenceEventService instead of direct EloService calls |
| `ComparisonTheaterViewModel.swift` | Persists votes to DB via PreferenceEventService when clear winner emerges. Fixed removeSlot observer re-registration bug. |
| `ScatterGatherViewModel.swift` | Routes winner selection through PreferenceEventService |
| `ABTestingService.swift` | Fixed enqueue bug: generations now dispatched to queue instead of just inserted into DB |
| `VortexTabView.swift` | Sidebar reorganized into 4 groups: Create, Evaluate, Analyze, Browse |
| `PromptStudioView.swift` | Left pane replaced with recipe list (name, generation count, quality badge, context menu with fork/favorite/delete) above prompt history |
| `PromptStudioViewModel.swift` | Added activeRecipeId, recipes list, recipe CRUD methods. Auto-creates recipe on first generate. |
| `VortexViewModel.swift` | Sets recipeId on generations in generateFromCurrentPrompt and batchGenerateAcrossProviders. Refreshes recipe list on generation completion. |

## Schema Changes

### Migration v9: Recipe Table
- `vortexRecipe` — 24 columns (name, prompt, provider/model, parameters, fork lineage, generation stats, cost, favorites)
- `vortexGeneration.recipeId` FK added
- `vortexStoryboardShot.recipeId` FK added
- `vortexArenaSession.recipeId` FK added
- 4 new indexes

### Migration v10: Preference Event Table
- `vortexPreferenceEvent` — winner/loser generation FKs, event type, category, recipe FK
- 3 new indexes

## Intelligence Flywheel

```
User votes in Arena/Comparison/ScatterGather
  → PreferenceEventService.recordPreference()
    → Inserts VortexPreferenceEvent row (persistent)
    → Delegates to EloRatingService (updates Elo by category)
    → Updates Recipe win/loss stats
  → SmartRouter.preferenceAware reads preference data
    → Recommends winning models for similar prompts
    → System improves with every vote
```

## Bug Fixes

1. **ABTestingService.runTest** — generations now enqueued via `GenerationQueueService.enqueue()` instead of just inserted into DB (were never dispatched)
2. **ComparisonTheaterViewModel.removeSlot** — time observers now re-registered with correct slot indices after removal (were using stale captured indices)

## Test Results

- **App:** 198/198 (182 existing + 16 new), 0 failures
- **CLI:** 151/151, 0 failures
