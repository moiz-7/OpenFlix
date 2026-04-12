# OpenFlix: Product Architecture Strategy

**Date:** 2026-04-12
**Scope:** Full-stack product strategy and implementation plan for transforming OpenFlix from a multi-provider video generation tool into a compounding, defensible platform built on the "video recipe" primitive.

---

## A. Executive Takeaway

OpenFlix has the right loop already built. The problem is that the loop's components are disconnected, the core object is wrong, and the intelligence layer is a sketch.

**What exists:** Prompt Studio -> Generate -> Dashboard -> Comparison Theater -> Arena/Elo -> Projects/Storyboards -> Export. This is real working code, 26 database tables, 7 providers, evaluation pipeline, lineage tracking.

**What's broken:**
1. The core object is `VortexGeneration` — a log entry, not a creative asset. It records what happened, not how to reproduce it.
2. Comparison Theater votes are ephemeral (in-memory, not persisted, not connected to Elo). The Arena feeds Elo, but SmartRouter doesn't read Elo data. RecommendationService reads Elo but uses naive keyword detection for categories. The intelligence flywheel has no flywheel — it's three disconnected gears.
3. Everything is single-user, local-only. No sharing, no collaboration, no publishing. Export is a `.vortex` JSON file that captures project names and bare configs — not a reproducible recipe.
4. The navigation treats the gold loop as 10 equal sidebar sections. There's no opinionated flow. Users don't feel pulled through prompt -> generate -> evaluate -> iterate -> publish.

**The move:** Introduce `Recipe` as the first-class object. Wire every vote (Arena AND Comparison) into the preference system. Make SmartRouter read from accumulated preference data. Build the publishing layer on top of recipes. Collaboration comes after recipes and publishing, not before.

**Sequencing:**
- **Now (Phase 1, 4-6 weeks):** Recipe entity + wiring the intelligence flywheel
- **Next (Phase 2, 4-6 weeks):** Publishing layer + recipe sharing
- **Later (Phase 3, 8-12 weeks):** Collaboration primitives + team workspaces

---

## B. Product Reframing Around the Gold Loop

### The Gold Loop Today

```
Prompt Studio → Generate → Dashboard → [dead end]
                                    ↘ Comparison Theater → [ephemeral votes, nowhere]
                                    ↘ Arena → Elo → [stored but unused by router]
```

Every piece exists. None are connected.

### The Gold Loop Target

```
Recipe Editor → Generate across models → Compare → Vote/Evaluate
     ↑                                                    ↓
     ←←←←← Remix/Fork/Branch ←←←← Keep Best → Publish/Export
                                        ↓
                              Intelligence Flywheel
                    (preferences → routing → recommendations)
```

### What Already Supports This Loop Strongly

| Component | File(s) | Status |
|-----------|---------|--------|
| Prompt editing + enhancement | `PromptStudioViewModel.swift`, `PromptEnhancerService.swift` | Strong |
| Multi-provider generation | `GenerationQueueService.swift`, 7 provider adapters | Strong |
| Generation lineage | `parentGenerationId` + `lineageType` on `vortexGeneration`, recursive CTE in `Database.swift` | Good foundation |
| Comparison Theater | `ComparisonTheaterViewModel.swift` | Playback works, votes ephemeral |
| Arena + Elo | `ModelArenaViewModel.swift`, `EloRatingService.swift` | Works but isolated |
| Quality evaluation | `VideoEvaluatorService.swift`, `QualityGateService.swift` | Works (heuristic + LLM) |
| Post-gen tools | `ExtendService`, `UpscaleService`, `ReframeService` | Impressive real implementations |
| Seed exploration | `SeedExplorerViewModel.swift` | Complete |
| Scatter-gather | `ScatterGatherViewModel.swift` | Complete |
| Cost tracking + budget | `CostTrackerService.swift`, `BudgetService.swift` | Complete |
| Projects + storyboards | `ProjectManagerViewModel.swift`, `StoryboardViewModel.swift` | Complete |

### What Is Peripheral — Deprioritize

| Feature | Why Deprioritize |
|---------|-----------------|
| Media Library (`LibraryBrowserView`, `LibraryIndexerService`, `TMDBService`) | This is video player functionality, not generation. Keep but don't invest. |
| Community Gallery (`CommunityGalleryView`, `vortexCommunityPrompt` table) | Dead feature — `isLocal = true` always, no server, no network. Replace with Recipe publishing. |
| Soundtrack service | Scaffolding. Not connected to the generation loop. Freeze. |
| Scheduler service | Scaffolding. Not connected. Freeze. |
| Sleep prevention / Deep Focus / Panic Hide | Player features. Irrelevant to the generation loop. Leave as-is. |

### Navigation and Mental Model Changes Required

**Current:** 10 flat sidebar sections. No hierarchy, no flow suggestion.

**Proposed:** 4 section groups with opinionated ordering:

```
CREATE
  Prompt Studio          (renamed: "Recipe Editor" in Phase 1)
  Projects & Storyboards (merged into one section)

EVALUATE
  Dashboard              (generations + queue)
  Comparison Theater
  Model Arena

ANALYZE
  Cost & Budget          (merged)
  Provider Metrics
  Provider Hub

BROWSE
  Recipe Library         (replaces "Community", shows user's published + forked recipes)
```

This is a navigation change in `VortexTabView.swift` — the `VortexSection` enum gets reordered and grouped. Implementation: add a `sectionGroup` computed property on `VortexSection` and render grouped `Section` elements in the sidebar `List`.

**Rename "Studio" tab to "Create"** in `OrbitaWelcomeView.swift` and `SettingsView.swift`. The word "Studio" is generic. "Create" is an action.

---

## C. Video Recipe: The Core Product Primitive

### What a Recipe Is

A recipe is the **complete, reproducible specification** for a video generation outcome. It is NOT a generation (that's an execution). It is NOT a prompt (that's one input). It is NOT a project (that's a container).

**Analogy:** A generation is a baked cake. A recipe is the instructions + ingredients list. You can fork the recipe, change the frosting, and bake a new cake. The recipe carries provenance — who wrote it, what it was forked from, which executions scored highest.

### Entity Definition

```swift
struct Recipe: Codable, FetchableRecord, PersistableRecord, Identifiable {
    // Identity
    var id: Int64?                    // auto-increment
    let uuid: String                  // UUID string, stable across exports

    // Content (the reproducible specification)
    var title: String                 // user-facing name
    var promptText: String
    var negativePromptText: String
    var stylePresetId: Int64?         // FK to vortexStylePreset
    var referenceImagePaths: String?  // JSON array of paths
    var seed: Int?                    // explicit seed, nil = random
    var parameters: String?           // JSON dict of provider-specific params

    // Target
    var providerId: String?           // nil = "use SmartRouter"
    var modelId: String?              // nil = "use recommendation"
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var aspectRatio: String?

    // Provenance
    var authorName: String?           // creator attribution
    var parentRecipeId: Int64?        // FK to recipe (fork source)
    var forkType: String?             // "fork", "remix", "branch", "variation"
    var projectId: String?            // FK to vortexProject
    var version: Int                  // increments on edit

    // Evaluation (aggregated from executions)
    var bestGenerationId: Int64?      // FK to vortexGeneration (highest-scored execution)
    var avgQualityScore: Double?      // running average across executions
    var executionCount: Int           // how many times this recipe has been run
    var winCount: Int                 // how many times executions of this recipe won arena matches
    var category: String?             // detected or user-assigned content category

    // Status
    var isPublished: Bool             // visible in recipe library
    var isFeatured: Bool              // editorially promoted
    var forkCount: Int                // how many times this recipe has been forked
    var likeCount: Int                // preference signals

    // Timestamps
    var createdAt: Date
    var updatedAt: Date
}
```

### How Recipe Differs from Existing Entities

| Entity | What It Is | Relationship to Recipe |
|--------|-----------|----------------------|
| `VortexPrompt` | A text string + version | Recipe.promptText absorbs this. Prompts still exist for edit history within a recipe. |
| `VortexGeneration` | An execution log entry | A generation is an execution OF a recipe. `VortexGeneration` gets a `recipeId` FK. |
| `VortexPromptTemplate` | A reusable text pattern | Templates generate recipes. A template is a recipe factory. |
| `VortexStoryboardShot` | A slot in a sequence | A shot gets a `recipeId` instead of bare `description` + `assignedGenerationId`. |
| `VortexExportBundle` | A serialization format | The export bundle becomes a recipe bundle (array of recipes + their best outputs). |
| `VortexProject` | A container | Still a container, but now contains recipes instead of bare prompts. |

### Versioning and Immutability

- **Immutable:** `uuid`, `parentRecipeId`, `forkType`, `createdAt`, `authorName` (attribution can't be rewritten)
- **Editable:** Everything else. Editing `promptText` or `parameters` increments `version`.
- **Fork creates a new recipe** with `parentRecipeId` set and `forkType` specified. The original is untouched.
- **Version history** is tracked via `version` field. Each edit is an in-place update (not a new row). If full history is needed later, add a `recipeVersion` table — but don't build that now.

### Fork / Remix / Branch Semantics

| Operation | What Changes | `forkType` |
|-----------|-------------|-----------|
| Fork | Copy everything, new author | `"fork"` |
| Remix | Copy and modify prompt/style | `"remix"` |
| Branch | Copy and modify provider/model/params | `"branch"` |
| Variation | Copy and change seed only | `"variation"` |

All four create a new recipe row with `parentRecipeId` pointing to the source.

### Recipe in the UI

**Recipe Editor** (replaces current Prompt Studio layout):
- Left pane: Recipe list (replaces prompt history) — shows title, thumbnail of best generation, quality score, execution count
- Center pane: Recipe form (prompt, negative prompt, style, references, parameters)
- Right pane: Execution history + enhancement panel

**Recipe Card** (appears in Dashboard, Library, Search):
- Thumbnail of best generation
- Title, prompt preview, provider/model badge
- Quality score, execution count, fork count
- Context menu: Fork, Remix, Branch, Generate, Compare, Export

**Recipe Detail Sheet:**
- Full specification with all fields
- Execution history (list of generations from this recipe)
- Lineage graph (ancestors + descendants via parentRecipeId)
- Arena performance (win rate for this recipe's executions)

### Search / Ranking / Discovery

- **FTS5 index** already exists (`vortexSearchIndex`). Add `recipe` as a new `entityType`. Index `title`, `promptText`, `category`.
- **Ranking:** Default sort by `avgQualityScore * log(executionCount + 1)` — quality weighted by confidence.
- **Category filtering:** Use the `category` field (detected or user-assigned).
- **Fork trees:** Query `parentRecipeId` chains to show "forked from X, which was forked from Y."

### Data / Storage Layer

Recipe is a **first-class top-level entity** in the database. New table in migration v9.

---

## D. Codebase-Aware Architecture and Schema Changes

### Migration v9: Recipe Table

```sql
CREATE TABLE recipe (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL DEFAULT '',
    promptText TEXT NOT NULL,
    negativePromptText TEXT NOT NULL DEFAULT '',
    stylePresetId INTEGER REFERENCES vortexStylePreset(id) ON DELETE SET NULL,
    referenceImagePaths TEXT,
    seed INTEGER,
    parameters TEXT,
    providerId TEXT,
    modelId TEXT,
    width INTEGER,
    height INTEGER,
    durationSeconds DOUBLE,
    aspectRatio TEXT,
    authorName TEXT,
    parentRecipeId INTEGER REFERENCES recipe(id) ON DELETE SET NULL,
    forkType TEXT,
    projectId TEXT REFERENCES vortexProject(id) ON DELETE SET NULL,
    version INTEGER NOT NULL DEFAULT 1,
    bestGenerationId INTEGER REFERENCES vortexGeneration(id) ON DELETE SET NULL,
    avgQualityScore DOUBLE,
    executionCount INTEGER NOT NULL DEFAULT 0,
    winCount INTEGER NOT NULL DEFAULT 0,
    category TEXT,
    isPublished BOOLEAN NOT NULL DEFAULT 0,
    isFeatured BOOLEAN NOT NULL DEFAULT 0,
    forkCount INTEGER NOT NULL DEFAULT 0,
    likeCount INTEGER NOT NULL DEFAULT 0,
    createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_recipe_projectId ON recipe(projectId);
CREATE INDEX idx_recipe_parentRecipeId ON recipe(parentRecipeId);
CREATE INDEX idx_recipe_category ON recipe(category);
CREATE INDEX idx_recipe_isPublished ON recipe(isPublished);
CREATE INDEX idx_recipe_avgQualityScore ON recipe(avgQualityScore);
CREATE INDEX idx_recipe_updatedAt ON recipe(updatedAt);

-- Add recipeId to vortexGeneration
ALTER TABLE vortexGeneration ADD COLUMN recipeId INTEGER REFERENCES recipe(id) ON DELETE SET NULL;
CREATE INDEX idx_vortexGen_recipeId ON vortexGeneration(recipeId);

-- Add recipeId to vortexStoryboardShot
ALTER TABLE vortexStoryboardShot ADD COLUMN recipeId INTEGER REFERENCES recipe(id) ON DELETE SET NULL;

-- Add recipeId to vortexArenaSession
ALTER TABLE vortexArenaSession ADD COLUMN recipeId INTEGER REFERENCES recipe(id) ON DELETE SET NULL;
```

### Migration v10: Preference Events Table

```sql
CREATE TABLE preferenceEvent (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    winnerId INTEGER NOT NULL REFERENCES vortexGeneration(id) ON DELETE CASCADE,
    loserId INTEGER NOT NULL REFERENCES vortexGeneration(id) ON DELETE CASCADE,
    winnerRecipeId INTEGER REFERENCES recipe(id) ON DELETE SET NULL,
    loserRecipeId INTEGER REFERENCES recipe(id) ON DELETE SET NULL,
    winnerProvider TEXT NOT NULL,
    winnerModel TEXT NOT NULL,
    loserProvider TEXT NOT NULL,
    loserModel TEXT NOT NULL,
    promptCategory TEXT,
    source TEXT NOT NULL,  -- 'arena', 'comparison', 'scatter_gather', 'manual'
    isDraw BOOLEAN NOT NULL DEFAULT 0,
    metadata TEXT,  -- JSON for additional context
    createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_pref_winnerProvider ON preferenceEvent(winnerProvider, winnerModel);
CREATE INDEX idx_pref_loserProvider ON preferenceEvent(loserProvider, loserModel);
CREATE INDEX idx_pref_category ON preferenceEvent(promptCategory);
CREATE INDEX idx_pref_source ON preferenceEvent(source);
CREATE INDEX idx_pref_createdAt ON preferenceEvent(createdAt);
```

### Files to Create

| File | Purpose |
|------|---------|
| `Vortex/Models/Recipe.swift` | Recipe struct (GRDB model) |
| `Vortex/Services/RecipeService.swift` | CRUD, fork, versioning, stat aggregation |
| `Vortex/Services/PreferenceEventService.swift` | Centralized preference capture + Elo updates |
| `Vortex/ViewModels/RecipeEditorViewModel.swift` | Replaces/extends PromptStudioViewModel |
| `Vortex/Views/RecipeEditor/RecipeEditorView.swift` | Replaces PromptStudioView |
| `Vortex/Views/RecipeEditor/RecipeListView.swift` | Sidebar recipe browser |
| `Vortex/Views/RecipeEditor/RecipeDetailSheet.swift` | Full recipe inspection |

### Files to Modify

| File | Change |
|------|--------|
| `Database.swift` | Add migrations v9, v10. Add Recipe + PreferenceEvent CRUD methods. |
| `VortexModels.swift` | Add Recipe struct. Add `recipeId` to VortexGeneration. |
| `VortexEnums.swift` | Add `ForkType` enum. Update `VortexSection` with groups. |
| `GenerationQueueService.swift` | After generation completes, update `recipe.executionCount`, `recipe.avgQualityScore`, `recipe.bestGenerationId`. |
| `ModelArenaViewModel.swift` | After vote, create `PreferenceEvent` via `PreferenceEventService`. |
| `ComparisonTheaterViewModel.swift` | Persist votes to DB. Create `PreferenceEvent` on vote. |
| `SmartRouterService.swift` | Add preference-aware ranking strategy (see Section F). |
| `EloRatingService.swift` | Accept calls from `PreferenceEventService` instead of direct calls from Arena. |
| `VortexTabView.swift` | Reorganize sidebar with section groups. |
| `PromptStudioView.swift` | Evolve into `RecipeEditorView` (or redirect). |
| `PromptStudioViewModel.swift` | Evolve into `RecipeEditorViewModel` (adds recipe CRUD). |
| `StoryboardViewModel.swift` | Use `recipeId` on shots instead of bare descriptions. |
| `ScatterGatherViewModel.swift` | Create recipe from prompt before scattering. Capture winner selection as `PreferenceEvent`. |
| `VortexExportBundle.swift` | Include full recipe objects in export format. |
| `PostGenToolkitView.swift` | Show recipe provenance in lineage section. |

### Backward Compatibility

- `VortexGeneration.recipeId` is nullable — existing generations don't need recipes.
- `VortexPrompt` remains intact — recipes reference prompts via text content, not FK (prompts are edit history within a recipe).
- The migration is purely additive (new table + new columns). No data loss.
- Existing projects, generations, comparisons, arena sessions all work unchanged.

### Lineage Graph Extension

The current lineage graph (`LineageGraphView.swift`) walks `vortexGeneration.parentGenerationId` via recursive CTE. This is generation lineage (extend/upscale/reframe).

Recipe lineage is separate: `recipe.parentRecipeId` tracks fork/remix/branch. Both graphs exist:

1. **Generation lineage** (existing): "This upscaled video came from that generated video"
2. **Recipe lineage** (new): "This recipe was forked from that recipe"

`LineageGraphView` should accept a mode toggle: "Show generation lineage" vs "Show recipe lineage."

---

## E. Arena as Intelligence Flywheel

### Current State (Honest Assessment)

The Arena works but teaches the system nothing actionable:

1. **EloRatingService** records matches with K=32 fixed Elo. Ratings are stored in `vortexEloRating` per provider+model+category. Standard chess Elo.
2. **ModelArenaViewModel** creates one generation per selected provider, runs auto-eval after 30 seconds if user doesn't vote, records wins/losses.
3. **SmartRouterService** has four strategies (cheapest/fastest/quality/balanced). **None of them read Elo data.** The prompt parameter is accepted but ignored.
4. **RecommendationService** reads Elo data but uses keyword-count category detection (11 keywords for "cinematic", 13 for "nature", etc.).
5. **ComparisonTheaterViewModel** has in-memory `votes` on entries. These votes are **never persisted** and **never connected to Elo**.

The gears are disconnected. Turning one doesn't turn the others.

### Redesign: Unified Preference Capture

**New service: `PreferenceEventService`**

Every vote, everywhere in the app, flows through one service:

```swift
@Observable final class PreferenceEventService {
    static let shared = PreferenceEventService()

    /// Record a pairwise preference (winner > loser)
    func recordPreference(
        winner: VortexGeneration,
        loser: VortexGeneration,
        source: PreferenceSource,    // .arena, .comparison, .scatterGather, .manual
        promptCategory: String?,
        metadata: [String: Any]? = nil
    ) {
        // 1. Insert PreferenceEvent row
        // 2. Update Elo ratings (calls EloRatingService)
        // 3. Update recipe stats if generations have recipeIds
        // 4. Update provider metrics preference signal
    }

    /// Record a draw
    func recordDraw(
        generationA: VortexGeneration,
        generationB: VortexGeneration,
        source: PreferenceSource,
        promptCategory: String?
    )

    /// Batch record from scatter-gather winner selection
    func recordScatterGatherWinner(
        winner: VortexGeneration,
        losers: [VortexGeneration],
        promptCategory: String?
    )
}
```

**Integration points:**

| Surface | Current | Change |
|---------|---------|--------|
| Arena vote | Calls `EloRatingService.recordMatch()` directly | Call `PreferenceEventService.recordPreference()` |
| Arena auto-eval | Calls `EloRatingService` directly | Call `PreferenceEventService` |
| Comparison Theater | In-memory `votes` array, never persisted | Persist to DB, call `PreferenceEventService` when user picks a winner |
| Scatter-Gather | Winner selection is ephemeral (`selectedWinnerId` in VM) | Call `PreferenceEventService.recordScatterGatherWinner()` |
| Dashboard | No preference capture | Add "prefer this" action on generation context menu |

### Category Taxonomy

Replace the naive keyword lists in `RecommendationService.detectCategory()` with a structured taxonomy:

```swift
enum PromptCategory: String, Codable, CaseIterable {
    case cinematic           // film/movie/trailer/scene/character
    case nature              // landscape/ocean/forest/wildlife
    case abstract            // shapes/patterns/fractals/psychedelic
    case commercial          // product/brand/advertisement/marketing
    case sciFi               // space/cyberpunk/robot/futuristic
    case documentary         // historical/educational/timelapse
    case musicVideo          // concert/performance/dance/rhythm
    case socialMedia         // trendy/viral/short/vertical
    case anime               // anime/manga/cel-shaded/japanese
    case architectural       // building/interior/urban/cityscape
    case portrait            // face/person/closeup/emotion
    case motion              // action/sports/fast/dynamic
}
```

**Detection:** Keep keyword matching for now (it's fast and good enough for v1). Improve later with embedding similarity. The key insight is that category needs to be **stored on every preference event and every recipe** so routing can slice by it.

### What Gets Measured

Every `PreferenceEvent` row captures:
- Which generation won (provider + model)
- Which generation lost (provider + model)
- What category the prompt belongs to
- Which recipes were involved (if any)
- The source of the preference (arena/comparison/scatter/manual)
- Timestamp for temporal analysis

From this, the system can derive:
- **Per-model win rate by category:** "Kling v2.6 Pro wins 73% of arena matches for cinematic prompts"
- **Per-model win rate by source:** "Fal Seedance wins more in blind arena, Runway wins more in side-by-side comparison" (interesting signal)
- **Preference velocity:** "Veo 3 is gaining preference share over the last 30 days"
- **Recipe quality signal:** "Recipes forked from recipe #42 have 2x higher avg quality than average"

### Elo Improvements (Keep Simple)

The current Elo system (K=32, starting 1500) is fine for now. Don't overcomplicate. Three changes:

1. **K-factor decay:** K=40 for first 10 matches (provisional), K=32 after (established). One constant change in `EloRatingService.swift`.
2. **Category always populated:** Every arena match and comparison vote should include detected category. Currently most default to "overall."
3. **Confidence display:** Show match count alongside rating. "1650 Elo (47 matches)" is more useful than "1650 Elo."

### System Outputs

The intelligence flywheel should produce these concrete outputs:

| Output | Consumer | Data Source |
|--------|----------|-------------|
| "Best model for cinematic prompts" | SmartRouter | PreferenceEvent aggregated by category + provider |
| "Recommended model for this prompt" | RecipeEditor | RecommendationService reading Elo by detected category |
| "This recipe's best execution used Kling v2.6 Pro" | Recipe detail | recipe.bestGenerationId → vortexGeneration |
| "Models trending up this week" | Arena leaderboard | PreferenceEvent time-series |
| "Your preference profile leans toward motion realism" | Settings/Profile (future) | Aggregated preference patterns |

---

## F. Routing, Recommendation, and Data Moat

### Wire SmartRouter to Preference Data

`SmartRouterService.swift` currently has four strategies. Add a fifth:

```swift
case preferenceAware  // "Use accumulated preference data for this prompt category"
```

**Implementation in `rankByPreference()`:**

1. Detect category from prompt text (reuse `RecommendationService.detectCategory()`)
2. Query `PreferenceEvent` table: count wins and losses per provider+model for that category
3. Compute preference-adjusted score: `wins / (wins + losses)` with Laplace smoothing `(wins + 1) / (wins + losses + 2)`
4. Fallback to Elo rating if fewer than 5 preference events for the category
5. Weight by recency: events from last 30 days count 2x vs older events

This is the minimum viable intelligence layer. No ML needed. Pure SQL aggregation + arithmetic.

**Query:**
```sql
SELECT winnerProvider, winnerModel,
       COUNT(*) as wins,
       (SELECT COUNT(*) FROM preferenceEvent
        WHERE loserProvider = pe.winnerProvider
        AND loserModel = pe.winnerModel
        AND promptCategory = ?) as losses
FROM preferenceEvent pe
WHERE promptCategory = ?
GROUP BY winnerProvider, winnerModel
ORDER BY wins DESC
```

### Make Preference-Aware the Default

Change `SmartRouterService.Strategy` default from `.balanced` to `.preferenceAware`. When the user has fewer than 10 total preference events, fall back to `.balanced` automatically.

This means the system gets smarter with every single vote the user casts.

### The Proprietary Datasets

| Dataset | How It Accumulates | Why It's Defensible |
|---------|-------------------|-------------------|
| Pairwise preferences by category | Every arena match, comparison vote, scatter-gather winner pick | No other tool captures structured preference data across multiple video gen providers |
| Prompt-to-quality mapping | Every quality evaluation (heuristic + LLM) stored per recipe | Maps prompt characteristics to output quality by model — this doesn't exist anywhere publicly |
| Recipe lineage trees | Every fork/remix creates a link | Shows which creative patterns produce high-quality descendants |
| Cost-quality frontier per category | Cost + quality score per generation by provider+model+category | Enables "cheapest model that achieves 75+ quality for nature scenes" — no public benchmark does this |

### Ship Now vs Future ML Layer

**Ship now (SQL aggregation):**
- Preference-aware routing (win rate by category)
- Recommendation badges ("Best for cinematic: Kling v2.6 Pro based on 47 arena matches")
- Recipe quality ranking (avgQualityScore * log(executionCount + 1))
- Cost-quality scatter plot per category (data already in `vortexCostEntry` + `vortexProviderMetrics`)

**Future ML layer (requires significant data volume):**
- Prompt embedding similarity for category detection (replace keyword lists)
- Collaborative filtering on recipe forks ("users who forked recipe X also liked recipe Y")
- Generative prompt optimization ("given this recipe's performance, try adjusting the camera language")
- Personal taste model (user preference vector learned from their votes)

Don't build the ML layer until you have 1,000+ preference events and 500+ recipes. The SQL layer is correct and ships immediately.

---

## G. Collaboration System Design

### Honest Constraint Assessment

OpenFlix is a local macOS app. There is no server, no auth, no user accounts, no cloud storage. Building real-time collaboration would require:
- A backend service (user accounts, auth, data sync)
- Conflict resolution for concurrent edits
- Permission management
- Network state handling

This is a 6-12 month effort to do properly. Don't start it in Phase 1 or Phase 2.

### v1 Collaboration: Recipe Files + Review Links (Phase 2)

**Recipe files (`.openflix` format):**

Evolve `VortexExportBundle` into a richer format:

```json
{
    "version": 2,
    "type": "recipe_bundle",
    "exportedAt": "2026-04-12T...",
    "author": "moiz",
    "recipes": [
        {
            "uuid": "...",
            "title": "Neon City Timelapse",
            "promptText": "...",
            "negativePromptText": "...",
            "providerId": "fal",
            "modelId": "fal-ai/veo3",
            "parameters": { "seed": 42, "aspect_ratio": "16:9" },
            "category": "cinematic",
            "parentRecipeUuid": null,
            "forkType": null,
            "avgQualityScore": 82.3,
            "executionCount": 7,
            "bestExecution": {
                "providerId": "fal",
                "modelId": "fal-ai/veo3",
                "qualityScore": 91.0,
                "evaluationDimensions": { ... },
                "durationSeconds": 8,
                "widthPx": 1280,
                "heightPx": 720
            }
        }
    ],
    "videos": ["neon_city_best.mp4"],
    "thumbnails": ["neon_city_thumb.jpg"]
}
```

This file can be:
- Shared via AirDrop, email, Slack, Discord
- Imported into another OpenFlix instance
- Forked by the recipient (creates a new recipe with `parentRecipeUuid` attribution)

**Review links (local-first):**

A "review link" in v1 is actually a recipe file hosted on a simple static file server (or even iCloud Drive / Dropbox). The app generates the file, the user shares the URL manually.

Future: a simple cloud service that hosts recipe files and generates shareable URLs. This is the minimum viable "publishing layer" (see Section H).

### v2 Collaboration: Team Workspaces (Phase 3, Cloud Required)

| Primitive | What It Does | Requires |
|-----------|-------------|----------|
| Team workspace | Shared project space with multiple members | Auth, user accounts, server |
| Shared projects | Multiple users contribute recipes to one project | Real-time sync or merge |
| Review approvals | "Approve this shot" workflow | Notification system |
| Remix permissions | Control who can fork your recipes | Permission model |
| Creator credits | Attribution in fork chains | Already in recipe.authorName |

**Permission model sketch:**

```
Workspace
  ├── Owner (full control)
  ├── Editor (create/edit/fork recipes, vote in arena)
  ├── Reviewer (view, vote, comment — no create/edit)
  └── Viewer (view only)

Recipe permissions:
  - Public: anyone can fork
  - Workspace: workspace members can fork
  - Private: only the author can fork
```

**Don't build this until:**
1. Recipe primitive is solid and tested (Phase 1)
2. Publishing layer exists (Phase 2)
3. There are real users asking for collaboration

---

## H. Export -> Publishing Evolution

### The Five Levels of Sharing

| Level | What | When to Build |
|-------|------|---------------|
| 1. Local export | `.openflix` file saved to disk | **Now** (enhance existing) |
| 2. Private share | Recipe file sent to specific people | **Phase 2** (file format + import) |
| 3. Review link | URL to a hosted recipe with video preview | **Phase 2** (simple cloud) |
| 4. Published recipe | Listed in public recipe library | **Phase 3** (requires cloud) |
| 5. Creator page | Profile page with all published recipes | **Phase 3+** |

### Phase 1: Enhanced Local Export

- Replace `VortexExportBundle` with `RecipeBundle` format
- Include full recipe specification, not just bare configs
- Include best video file and thumbnail
- Include evaluation data and lineage
- File extension: `.openflix` (replace `.vortex`)
- Import creates recipes with proper `parentRecipeUuid` attribution

### Phase 2: Publishing Layer

**Minimum viable publishing:**

A simple web service (could be a single Go/Python server or even a static site generator) that:
1. Accepts recipe bundle uploads from the app
2. Generates a public URL with: recipe details, video preview, fork button
3. Allows browsing published recipes by category and quality
4. Provides a fork URL that opens in OpenFlix app (via `openflix://` URL scheme)

**This is NOT a full social network.** It's a recipe registry — like a Homebrew tap or a Docker registry. Minimal UI, maximum utility.

**Attribution and fork visibility:**
- Every published recipe shows "forked from [original]" if applicable
- Fork chains are visible: "Original by Alice -> Remix by Bob -> Branch by Carol"
- Creator name is required for publishing (from recipe.authorName)
- Fork count is displayed as a quality signal ("forked 23 times")

### What Not to Build

- Comments (low value, high moderation cost)
- Likes without votes (vanity metric, doesn't feed intelligence)
- User profiles with avatars and bios (premature social features)
- Following/followers (wrong primitive for this product)
- Notifications (until there's real multi-user activity)

---

## I. Prioritized Roadmap: Now / Next / Later

### NOW (Phase 1): Recipe + Intelligence Wiring — 4-6 weeks

**Objective:** Make the core loop complete and self-improving.

| # | Item | Effort | Files Affected |
|---|------|--------|---------------|
| 1 | Create Recipe model + migration v9 | M | `VortexModels.swift`, `Database.swift`, new `Recipe.swift` |
| 2 | Create RecipeService (CRUD, fork, stats) | M | New `RecipeService.swift` |
| 3 | Create PreferenceEvent table + migration v10 | S | `Database.swift` |
| 4 | Create PreferenceEventService | M | New `PreferenceEventService.swift` |
| 5 | Wire Arena votes through PreferenceEventService | S | `ModelArenaViewModel.swift` |
| 6 | Persist Comparison Theater votes + wire to PreferenceEventService | M | `ComparisonTheaterViewModel.swift` |
| 7 | Wire Scatter-Gather winner to PreferenceEventService | S | `ScatterGatherViewModel.swift` |
| 8 | Add preference-aware strategy to SmartRouter | M | `SmartRouterService.swift` |
| 9 | Update GenerationQueueService to update recipe stats on completion | S | `GenerationQueueService.swift` |
| 10 | Evolve PromptStudioView into RecipeEditorView | L | `PromptStudioView.swift`, `PromptStudioViewModel.swift`, new files |
| 11 | Reorganize sidebar navigation with section groups | S | `VortexTabView.swift`, `VortexEnums.swift` |
| 12 | Fix ABTestingService to actually enqueue generations | S | `ABTestingService.swift` |
| 13 | Fix ComparisonTheater removeSlot observer bug | S | `ComparisonTheaterViewModel.swift` |

**Success:** A user can create a recipe, generate across models, compare results, vote, and the next time they generate with a similar prompt, SmartRouter recommends the model that won.

### NEXT (Phase 2): Publishing + Enhanced Export — 4-6 weeks

| # | Item | Effort | Files Affected |
|---|------|--------|---------------|
| 1 | Design RecipeBundle file format (.openflix) | M | `VortexExportBundle.swift` → `RecipeBundleFormat.swift` |
| 2 | Recipe import with fork attribution | M | `RecipeService.swift`, `ProjectManagerViewModel.swift` |
| 3 | Recipe Library view (replaces Community Gallery) | M | New view, replaces `CommunityGalleryView.swift` |
| 4 | Recipe detail sheet with full provenance | M | New `RecipeDetailSheet.swift` |
| 5 | Recipe lineage graph (fork trees) | M | Extend `LineageGraphView.swift` with recipe mode |
| 6 | Publish recipe to simple cloud service | L | New cloud service, new `PublishingService.swift` |
| 7 | Recipe browser web page (read-only) | L | New web frontend |
| 8 | Fork from URL (`openflix://fork?recipe=...`) | M | `OpenFlixApp.swift` URL handler |
| 9 | Update CLI to support recipe operations | M | CLI commands: `recipe create/fork/list/export` |
| 10 | Update top-level README for new product framing | S | `README.md` |

**Success:** A user can publish a recipe, share a link, and someone else can fork it, modify the prompt, and generate a variation — with full attribution chain visible.

### LATER (Phase 3): Collaboration + Scale — 8-12 weeks

| # | Item | Effort |
|---|------|--------|
| 1 | User accounts + auth service | XL |
| 2 | Team workspaces | XL |
| 3 | Shared projects with sync | XL |
| 4 | Review/approval workflow | L |
| 5 | Permission model (owner/editor/reviewer/viewer) | L |
| 6 | Creator pages | M |
| 7 | Embedding-based category detection | L |
| 8 | Personal taste model from preference history | L |
| 9 | Prompt optimization suggestions from recipe performance data | L |
| 10 | App Sandbox + code signing for Mac App Store | L |

### Strategic Necessity vs Nice-to-Have

| Must Do | Nice to Have | Don't Do |
|---------|-------------|----------|
| Recipe primitive | Recipe lineage visualization | Full social network |
| PreferenceEvent capture | Category auto-detection improvements | Comments/likes/follows |
| SmartRouter preference-awareness | Recipe trending/featured | Real-time multiplayer editing |
| Comparison vote persistence | Cost-quality frontier charts | Mobile app |
| Sidebar reorganization | Recipe search by similarity | Custom ML models |
| ABTesting enqueue fix | CLI recipe commands | Notification system (until Phase 3) |

---

## J. Concrete Implementation Plan by Phase

### Phase 1: Recipe + Intelligence Flywheel (4-6 weeks)

**Week 1-2: Foundation**

_Objective:_ Recipe entity exists and generations can be created from recipes.

Build items:
- `Recipe` struct in `VortexModels.swift` (or new `Recipe.swift`)
- Migration v9 in `Database.swift` (recipe table + alter vortexGeneration + alter vortexStoryboardShot)
- Recipe CRUD methods in `Database.swift`
- `RecipeService.swift`: create, update, fork, delete, updateStats, getForProject, search
- Modify `GenerationQueueService.executeGeneration()`: after successful generation, call `RecipeService.updateStats()` to update executionCount, avgQualityScore, bestGenerationId

Schema implications: Additive only. Existing data untouched.

UX implications: None yet — backend only.

Risks: Recipe model design might need iteration. Keep it simple, extend later.

Success: `RecipeService` unit tests pass. Generations can be created with `recipeId`.

**Week 2-3: Preference System**

_Objective:_ Every vote feeds the intelligence flywheel.

Build items:
- Migration v10 in `Database.swift` (preferenceEvent table)
- `PreferenceEventService.swift`: recordPreference, recordDraw, recordScatterGatherWinner
- Modify `ModelArenaViewModel.voteForWinner()`: call PreferenceEventService instead of EloRatingService directly
- Modify `ModelArenaViewModel.voteDraw()`: same
- Modify `ModelArenaViewModel.performAutoEvaluation()`: same
- Modify `ComparisonTheaterViewModel.vote()`: persist to DB, call PreferenceEventService
- Modify `ScatterGatherViewModel.selectWinner()`: call PreferenceEventService.recordScatterGatherWinner
- Fix `ComparisonTheaterViewModel.removeSlot()` observer re-registration bug

Schema implications: New table only. No migration of existing data.

UX implications: Comparison Theater votes now persist. Users see "Winner" badge persist across sessions.

Risks: Must be careful with PreferenceEventService thread safety — use `@MainActor` or actor isolation.

Success: After 10+ arena matches, `SELECT winnerProvider, COUNT(*) FROM preferenceEvent GROUP BY winnerProvider` returns meaningful data.

**Week 3-4: Smart Routing Upgrade**

_Objective:_ SmartRouter uses accumulated preference data.

Build items:
- Add `.preferenceAware` case to `SmartRouterService.Strategy`
- Implement `rankByPreference()` using PreferenceEvent aggregation
- Make preference-aware the default when sufficient data exists (10+ events)
- Add category detection call in `SmartRouterService.selectProvider()` (currently accepts prompt but ignores it)
- Add preference win-rate display to RecommendationBadge
- Fix `RecommendationService` `let` dependencies to computed `var` (test isolation)

Schema implications: None.

UX implications: "Recommended" badge now shows data-backed reasons. SmartRouter default changes.

Risks: Cold start — new users have zero preference data. Fallback to `.balanced` handles this.

Success: User generates 10 arena matches. Next generation with similar prompt auto-selects the arena winner's model.

**Week 4-6: Recipe Editor UI**

_Objective:_ Users interact with recipes, not bare prompts.

Build items:
- `RecipeEditorView.swift`: evolve from PromptStudioView, left pane shows recipe list instead of prompt history
- `RecipeEditorViewModel.swift`: wraps PromptStudioViewModel, adds recipe CRUD
- `RecipeListView.swift`: sidebar showing recipes with thumbnail, title, quality score
- Recipe card component for Dashboard integration
- "Fork" / "Remix" / "Branch" actions in generation context menus
- Sidebar navigation reorganization (4 groups: Create, Evaluate, Analyze, Browse)
- Category picker in recipe editor (user can assign or auto-detect)

Schema implications: None beyond what's already migrated.

UX implications: Major. The primary interaction surface changes from "write a prompt and hit generate" to "create/select a recipe and execute it." Must feel natural, not heavy.

Risks: Making the recipe abstraction feel lightweight enough. Don't make users think they're filling out a form. The recipe should feel as easy as the current prompt studio, with the recipe structure working behind the scenes. **Default behavior:** typing a prompt and hitting generate auto-creates a recipe. Users discover recipes are objects when they see them in the sidebar with execution history and quality scores.

Success: User can see their recipe history, fork a recipe, see quality improvements across executions, and the interface feels faster than the current prompt studio, not slower.

### Phase 2: Publishing Layer (Weeks 7-12)

_Objective:_ Recipes become shareable, forkable objects with attribution.

Build items: See Section I "NEXT" list.

Affected code: `VortexExportBundle.swift` (major rewrite), new cloud service, new web frontend, URL scheme extensions.

Schema implications: May need `publishedAt`, `publishedUrl` columns on recipe.

UX implications: New "Publish" button on recipe detail. New "Recipe Library" section replacing "Community."

Risks: Cloud service is new infrastructure. Keep it dead simple — a single API endpoint that accepts a file upload and returns a URL. Can start with a static file host (S3 + CloudFront) with no custom backend.

Success: User publishes a recipe. Shares the link. Recipient forks it and generates a variation. Fork chain is visible.

### Phase 3: Collaboration (Weeks 13-24)

Not detailed here because it depends on Phase 1-2 learnings and real user feedback.

---

## K. Risks, Pushback, and What to Avoid

### Where the Current Architecture Fights This Vision

1. **No shared library between app and CLI.** The CLI has its own provider implementations, its own models, its own store format (flat JSON vs SQLite). Recipes in the app can't be used by the CLI without a translation layer. This is the single largest structural problem. A shared Swift package for models + recipe format would solve it, but it's a significant refactoring effort. **Recommendation:** Don't block Phase 1 on this. Build recipes in the app first. Add CLI support in Phase 2 via recipe file import/export.

2. **Singleton test isolation is inconsistent.** Several VMs (`PromptStudioViewModel`, `GenerationDashboardViewModel`, `ProjectManagerViewModel`, `ModelArenaViewModel`) capture `database` or service dependencies as `let` rather than computed `var`. New services (RecipeService, PreferenceEventService) MUST use computed properties. Fix existing VMs opportunistically.

3. **`Database.swift` is already 1,800 lines.** Adding Recipe CRUD and PreferenceEvent CRUD will push it past 2,000. **Recommendation:** Split Database.swift into partial files using extensions: `Database+Recipe.swift`, `Database+Preference.swift`, `Database+Generation.swift`, etc. Do this as prep work before Phase 1.

4. **The player side of the app is a separate product.** The `Player/` directory, `Features/` directory, and half the `UI/` directory have nothing to do with video generation. They're a VLC-based video player. This creates cognitive overhead and architectural confusion. **Recommendation:** Accept the dual nature. Don't try to unify. The player is the hook that gets users in the door; the generation studio is where value accrues.

### Deceptively Attractive But Strategically Wrong

1. **"Build a full community/social platform."** No. You have zero users. A social platform with zero users is worse than no social platform. Build recipes, build publishing, let the sharing happen through direct links. Community features come after you have 100+ published recipes from real users.

2. **"Add more providers."** The current 7 providers and 23+ models are more than enough. Adding provider #8 doesn't make the product more defensible. Making the intelligence layer smarter about the existing 7 providers does.

3. **"Build a mobile app."** No. The target users are creators sitting at desks with monitors. Mobile video generation is a different product for different users. Stay focused on macOS.

4. **"Use ML for category detection."** Keyword matching works for v1. You don't have enough data to train a model. You don't have the infrastructure to serve one. Ship the keyword version, collect data, revisit in 6 months.

5. **"Build real-time collaboration first."** Collaboration requires auth, sync, conflict resolution, permissions — all infrastructure you don't have. Recipes + publishing give you 80% of the collaboration value with 10% of the engineering cost. The remaining 20% requires real users requesting it.

### Where "GitHub for Video" Is Valid

- **Forkable objects with lineage tracking:** Direct analogy. Recipes with `parentRecipeId` are repos with fork relationships.
- **Reproducibility:** A recipe is a Dockerfile for video. Same inputs → same output (modulo model non-determinism, which seeds partially address).
- **Quality signals from community:** Fork count is the new star count. Arena Elo is the new CI badge.
- **Discovery through provenance:** "Forked from" chains are meaningful. They show creative lineage.

### Where the Analogy Breaks

- **AI video is non-deterministic.** Even with the same seed, different provider API versions may produce different outputs. Recipes are reproducible intent, not reproducible output. This is fundamentally different from code, which is deterministic. Don't promise reproducibility — promise reproducible intent.
- **There is no "merge."** Code has merge because text is mergeable. Video is not. You can fork, remix, and branch, but you can't merge two videos into one in any meaningful way. Drop "merge" from the vocabulary.
- **The creation loop is minutes, not days.** Code projects evolve over weeks and months. A video recipe goes from prompt to output in 30 seconds to 5 minutes. This means the iteration velocity is much higher, which is good — but it also means the "version history" of a recipe matters less than the current best execution.
- **The unit of collaboration is smaller.** GitHub collaboration happens on projects with thousands of files. Video collaboration happens on individual shots or scenes. The project container matters less; the recipe matters more.

### What to Cut or Freeze

| Feature | Decision | Rationale |
|---------|----------|-----------|
| Scheduler service | Freeze | Scaffolding, not connected to the loop |
| Soundtrack service | Freeze | Scaffolding, not connected to the loop |
| Community Gallery (current) | Replace | Dead feature (isLocal = true always). Replace with Recipe Library in Phase 2. |
| Media Library | Maintain only | Player feature, not generation loop. Don't invest. |
| Discord bot | Maintain only | Separate codebase, separate users. Add recipe export to bot later if warranted. |
| Homebrew formula | Fix but don't invest | Fix the placeholder SHA, rename to `openflix`. Don't build a tap infrastructure. |
| README stale references | Fix immediately | Trust killer. 15 minutes of work. |

### Final Word

The most dangerous trap is building features instead of building the loop. Every hour spent on a feature that doesn't feed the prompt → generate → compare → evaluate → improve cycle is an hour wasted. The recipe primitive makes the loop explicit. The preference system makes the loop self-improving. The publishing layer makes the loop social. Everything else is noise until those three are working.

Build the recipe. Wire the votes. Ship the loop.
