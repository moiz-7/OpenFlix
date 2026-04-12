# OpenFlix: Product Manager Technical Audit

**Date:** 2026-04-11
**Auditor:** Claude Opus 4.6
**Scope:** Full VidViewer monorepo — macOS app, CLI, Discord bot, CI, docs
**Files read:** ~150 Swift files, ~20 Python files, YAML/configs, all tests, all docs

---

## 1. Executive Summary

### What this is

OpenFlix is a **three-surface AI video generation platform** paired with a **full-featured macOS video player**:

1. **OpenFlix (macOS app)** — A SwiftUI video player (VLC-powered) with an integrated "Studio" tab that serves as a GUI for AI video generation across 7 providers and 23+ models. Think VLC + RunwayML in one app.

2. **openflix (CLI)** — A JSON-first command-line tool for the same video generation workflow, designed for scripting, automation, and agentic (MCP) integration. 21 commands, 6 providers, 23 models.

3. **Discord bot** — A BYOK (Bring Your Own Key) Discord bot letting server members generate AI videos using their own API keys. 6 providers, 23 models, 8 slash commands.

All three share the same conceptual model: submit a text prompt to an AI video provider, poll for completion, download the result. The app and CLI share the same provider set but are independent codebases (no shared library). The bot is a separate Python codebase.

### Who it's for

- **Primary persona:** AI video creators/hobbyists who want a unified tool to try multiple providers without vendor lock-in
- **Secondary persona:** Developers who want scriptable/automatable video generation (CLI + MCP)
- **Tertiary persona:** Discord communities that want to offer AI video generation to members

### Maturity

**Late MVP / Early Growth.** The feature surface is impressively wide — 60 features across 3 phases in the app alone — but the product has zero real users yet. No code signing, no Homebrew formula with a real SHA, no deployed Discord bot, no App Store submission, no Sentry DSN configured. The engineering is solid; the go-to-market is at zero.

---

## 2. Core Functionality Map

### 2.1 macOS App — Feature Inventory

**Player (fully built):**
| Feature | Status | Notes |
|---------|--------|-------|
| Video playback (VLC-powered) | Complete | All major formats: mp4, mkv, webm, avi, mov, flv |
| Audio/subtitle track switching | Complete | Auto-detect language, external subtitle loading |
| Resume playback | Complete | SHA-256 hash-based, survives renames |
| Bookmarks | Complete | Timestamped per-file |
| Playlist (folder-based) | Complete | Natural sort, shuffle, repeat modes, next-episode countdown |
| Watch history | Complete | Session-based with stats |
| A-B loop | Complete | Clean state machine |
| Speed control (0.1x-4x) | Complete | |
| Multi-view (1/2/4 panes) | Complete | Independent VLC engines per pane |
| Mini player / PiP | Complete | |
| AirPlay | Complete | AVRoutePickerView integration |
| 10-band EQ + presets | Complete | |
| Video filters (brightness/contrast/etc) | Complete | |
| Blue light filter | Complete | |
| Pinch-to-zoom, swipe gestures | Complete | |
| Keyboard shortcuts (37 defaults) | Complete | Customizable, cheat sheet overlay |
| OpenSubtitles integration | Complete | Hash-based search, excellent security |
| Screenshot capture | Complete | Clipboard + file + notification |
| Dual subtitles | Complete | |
| Silence detection + skip | Complete | RMS-based analysis |
| Intro detection | **Stub** | `detectIntroPattern()` returns nil |
| Sleep prevention | Complete | IOPMAssertion |
| Incognito mode | Complete | |
| Panic hide | Complete | |
| Stream analytics HUD | Complete | Real-time codec/bitrate/buffer display |
| Deep focus / break reminders | Complete | |
| URL scheme (`openflix://`) | Complete | open, play, pause |
| Sparkle auto-update | Complete | Appcast configured |
| TMDB enrichment | Complete | Title, overview, genres, rating, poster |

**Studio / Video Generation (fully built):**
| Feature | Status | Notes |
|---------|--------|-------|
| Prompt Studio | Complete | Editor, history, templates, structured builder |
| 7 providers / 23+ models | Complete | fal, Replicate, Runway, Luma, Kling, MiniMax, Seedance |
| Generation queue + polling | Complete | Concurrent, retry, download |
| Prompt enhancement | Complete | AI-powered expansion |
| Prompt safety | Complete | Keyword + pattern blocking |
| Smart router | Complete | Cheapest/fastest/quality/balanced strategies |
| Model recommendation | Complete | Prompt analysis-based |
| Prompt suggestions | Complete | Context-aware |
| Style presets | Complete | |
| Comparison theater | Complete | 2/3/4-up, A/B toggle, voting |
| Model arena (Elo) | Complete | Matchmaking, leaderboard, category rankings |
| Projects + storyboards | Complete | Multi-shot with sort order |
| Moodboards | Complete | Visual canvas |
| Lineage graph | Complete | Parent-child generation tracking |
| Cost tracker + budget | Complete | Daily/monthly limits |
| Provider metrics | Complete | Success rate, latency, quality, cost |
| Quality trend charts | Complete | Time-series visualization |
| Provider hub + capability matrix | Complete | |
| Seed explorer | Complete | |
| Scatter-gather | Complete | Multi-provider parallel gen |
| A/B testing | Complete | Prompt variant testing |
| Library indexer | Complete | Folder scanning, smart collections, FTS5 |
| Scheduler | Scaffolding | Service exists but limited implementation |
| Soundtrack | Scaffolding | Service exists but limited implementation |
| Export presets | Complete | Instagram, TikTok, YouTube Shorts, 4K, ProRes |
| Community gallery | Complete | Shared prompts |
| Global search | Complete | FTS5-powered |
| Extend/Upscale/Reframe | Complete | Post-generation tools |

### 2.2 CLI — Feature Inventory

| Command | Status | Notes |
|---------|--------|-------|
| `generate` (submit + stream + wait) | Complete | 6 providers, 23 models |
| `status` / `list` / `download` | Complete | JSON output |
| `cancel` / `delete` / `retry` / `purge` | Complete | |
| `keys` (set/get/delete/list) | Complete | macOS Keychain + migration chain |
| `providers` / `models` | Complete | |
| `health` | Complete | Provider connectivity check |
| `cost` / `budget` | Complete | Daily/monthly limits |
| `project` (create/run/status/list/delete/shot/export) | Complete | Multi-shot DAG execution |
| `evaluate` / `feedback` / `metrics` | Complete | Quality scoring |
| `batch` | Complete | Bulk generation |
| `daemon` (start/stop/status) | Complete | Background process |
| `mcp` (serve) | Complete | 14 tools, 3 resources, JSON-RPC 2.0 |

### 2.3 Discord Bot — Feature Inventory

| Command | Status | Notes |
|---------|--------|-------|
| `/generate` | Complete | Full pipeline with safety + rate limiting |
| `/keys set/list/delete` | Complete | BYOK with Fernet encryption |
| `/status` | Complete | Ownership-scoped |
| `/models` / `/providers` / `/help` | Complete | |
| I2V (image-to-video) | **Wired but unreachable** | 13 models support it, no command parameter |

### 2.4 User Journeys

**Journey 1: First-time CLI user**
```
Install binary → `openflix keys set fal <key>` → `openflix generate "prompt" --provider fal --model ... --wait`
→ Poll completes → `openflix download <id>` → Video saved locally
```

**Journey 2: App user exploring providers**
```
Open app → Studio tab → Prompt Studio → Type prompt → Smart Router recommends provider
→ Submit → Watch queue → Compare results in Comparison Theater → Vote in Arena
→ Track costs in Cost Tracker → Export to Instagram preset
```

**Journey 3: Discord server member**
```
DM bot: `/keys set fal <key>` → In channel: `/generate prompt:... provider:fal model:...`
→ Bot posts embed → Polls → Attaches video (if <25MB) or posts URL
```

---

## 3. Technical Architecture

### 3.1 System Architecture

**Monorepo, three independent applications.** No shared libraries between them.

```
VidViewer/
├── OpenFlix/          SwiftUI macOS app (~120 .swift files, ~15K LOC)
├── VortexCLI/         Swift CLI (~60 .swift files, ~8K LOC)
├── discord-bot/       Python Discord bot (~20 .py files, ~1.4K LOC)
├── project.yml        XcodeGen project definition
├── Podfile            CocoaPods (VLCKit)
└── .github/workflows/ CI (2 jobs: CLI tests + app build/test)
```

### 3.2 macOS App Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | SwiftUI (macOS 14+) |
| State Management | Swift 5.9 `@Observable` macro (not Combine) |
| Architecture | MVVM with singleton services |
| Media Engine | VLCKit 3.7.2 (via CocoaPods) |
| Database | GRDB 6.24.1+ (SQLite, WAL mode) |
| Auto-update | Sparkle 2.4.0+ |
| Crash reporting | Sentry 8.0.0+ (DSN not configured — dead code) |
| Networking | Foundation URLSession |
| Project generation | XcodeGen |

### 3.3 CLI Stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 5.9, macOS 14+ |
| CLI framework | swift-argument-parser 1.3.0 |
| Keychain | Security.framework (direct) |
| Networking | Foundation URLSession (ephemeral) |
| Storage | Flat JSON files in `~/.openflix/` |
| Output | JSON-first (structured errors, all commands) |
| MCP | JSON-RPC 2.0 over stdio |

**One external dependency.** Everything else is Foundation. This is impressively lean.

### 3.4 Discord Bot Stack

| Layer | Technology |
|-------|-----------|
| Language | Python 3.11 |
| Framework | discord.py 2.3.0+ |
| HTTP | aiohttp 3.9.0+ |
| Database | aiosqlite 0.19.0+ (SQLite, WAL mode) |
| Encryption | cryptography 41.0.0+ (Fernet / AES-128-CBC + HMAC) |

### 3.5 Database Models

**App (GRDB/SQLite) — 26 tables across 8 migrations:**

| Domain | Tables |
|--------|--------|
| Player | `resumePoint`, `watchHistoryEntry`, `preference`, `bookmark` |
| Studio Core | `vortexProject`, `vortexTag`, `vortexProjectTag`, `vortexProviderConfig`, `vortexPrompt`, `vortexPromptTemplate`, `vortexGeneration` |
| Comparison | `vortexComparison`, `vortexComparisonEntry`, `vortexArenaSession` |
| Cost | `vortexCostEntry` |
| Quality | `vortexProviderMetrics`, `vortexGenerationFeedback`, `vortexHealthCheck`, `vortexMetricSnapshot` |
| Library | `mediaFolder`, `mediaItem`, `collection`, `collectionItem` |
| Studio Other | `vortexStylePreset`, `vortexEloRating`, `vortexStoryboardShot`, `vortexCommunityPrompt` |
| Search | `vortexSearchIndex` (FTS5 virtual) |

16 indexes. Foreign keys with CASCADE/SET NULL. Self-referencing for lineage (generation parent) and prompt versioning.

**CLI (flat JSON files):**
| File | Content |
|------|---------|
| `~/.openflix/store.json` | Generation records (dictionary) |
| `~/.openflix/projects/<id>/project.json` | Per-project data |
| `~/.openflix/metrics.json` | Provider metrics |
| `~/.openflix/budget_config.json` | Budget settings |
| `~/.openflix/daily_spend.json` | Daily cost tracking |

**Bot (SQLite):** 3 tables (`user_keys`, `generations`, `rate_limits`). No migration versioning.

### 3.6 Third-Party Integrations

| Service | Used By | Purpose |
|---------|---------|---------|
| fal.ai | All three | Video generation (8 models) |
| Replicate | All three | Video generation (4 models) |
| Runway | All three | Video generation (2 models) |
| Luma | All three | Video generation (3 models) |
| Kling | All three | Video generation (3 models) |
| MiniMax | All three | Video generation (3 models) |
| Seedance (ByteDance) | App only | Video generation |
| OpenSubtitles | App | Subtitle search/download |
| TMDB | App | Movie metadata enrichment |
| Sparkle | App | Auto-update |
| Sentry | App (inactive) | Crash reporting |
| Discord API | Bot | Chat platform |
| macOS Keychain | App + CLI | API key storage |

---

## 4. Code Quality & Health Assessment

### 4.1 Project Structure

**App:** Well-organized. Clear separation into App/, Persistence/, Features/, Player/, UI/, Utilities/, Vortex/ (with Models/, Providers/, Services/, ViewModels/, Views/ subdirs). ~120 files, easy to navigate.

**CLI:** Excellent structure. Sources/openflix/ with Commands/, Core/, Providers/, Output/. 60 files, each with a single clear responsibility.

**Bot:** Clean and small. Core modules + providers/ + cogs/ separation. 20 files, ~1,350 LOC.

**Verdict:** Structure is a strength across all three. No file dumping, no confused responsibilities.

### 4.2 Testing

| Codebase | Tests | Strategy | Coverage Gaps |
|----------|-------|----------|---------------|
| App | 182 XCTest | Unit tests on business logic (DB CRUD, Elo, budget, safety, routing, playlist, etc.) | No VLC integration tests, no AirPlay, 1 UI test, no screenshot/gesture/window tests |
| CLI | 151 bash | Integration tests (help text, source grep, runtime behavior) | No XCTest unit tests, no provider API mocking, all tests are bash scripts |
| Bot | **0** | None | **Everything.** Bot handles encrypted API keys with zero test coverage. |

**Honest assessment:** App testing is good for business logic but has no integration or UI testing. CLI testing is creative (bash-based) but brittle and non-standard — source code grep tests will break if formatting changes. Bot having zero tests while handling encryption is a red flag.

### 4.3 Error Handling

**App:** Proper. Database operations wrapped in try-catch with `OpenFlixLogger`. Provider errors map to `VortexProviderError` (6 cases). UI shows errors via alerts/toasts.

**CLI:** Excellent. Two-layer error taxonomy — `OpenFlixError` (11 user-facing cases with structured JSON output) plus `StructuredError` for machine-readable errors with domain/code/message/details. Every error path outputs valid JSON.

**Bot:** Adequate for user-facing errors (ephemeral messages for auth/validation failures, embed updates for generation failures). But: poll task exceptions leak `active_count` permanently (`cogs/generate.py`), and there's no global error handler for unexpected exceptions.

### 4.4 Security Posture

**Strengths (impressive for a solo project):**
- macOS Keychain for API key storage (app + CLI) with proper access levels
- Multi-hop keychain migration chain (Meridian → OpenFlix)
- Fernet encryption at rest for Discord bot keys
- Prompt safety across all three (keyword blocklist + injection detection)
- OpenSubtitles security: file size limits (2MB), extension sanitization, path traversal prevention, HTTPS-only
- File size limits on all downloads (references 25MB, imports 10MB, moodboard images 15MB)
- Hardened runtime on macOS app
- Rate limiting on Discord bot (cooldown + concurrent + daily)
- Ownership checks on bot status queries

**Weaknesses:**
| Issue | Severity | Location |
|-------|----------|----------|
| `--api-key` CLI flag visible in `ps` output | Medium | CLI |
| Daemon socket has no authentication | Medium | `DaemonServer.swift` |
| Budget limits are local-only (trivially bypassed) | Low | CLI + App |
| Prompt safety uses naive substring matching | Low | All three |
| Single shared encryption key for all bot users | Medium | `crypto.py` |
| No key rotation mechanism for bot | Medium | Bot |
| Slash command params visible to other users momentarily | Medium | Discord platform limitation |
| No App Sandbox (not Mac App Store ready) | Low | App |
| Library validation disabled (VLCKit requirement) | Low | App entitlements |

### 4.5 Performance

**Good practices observed:**
- VLC time callback throttled from 30-60Hz to ~4Hz (`PlayerEngine.swift`)
- Database uses WAL mode + NORMAL synchronous (both app and bot)
- Dual locking on CLI stores (flock + NSLock)
- FTS5 for search (not LIKE queries)
- URLSession ephemeral configuration in CLI (no disk caching)
- Chunk-based audio analysis in SmartSkip (1-second chunks)

**Potential issues:**
- `Database.swift` is ~1,800 lines — not a perf issue but a maintainability one
- `PlayerViewModel.swift` at ~1,140 lines with many forwarding computed properties
- CLI stores load/save entire JSON files (fine at current scale, won't scale to thousands of generations)
- No lazy loading for generation history in app dashboard
- Bot `tree.sync()` on every startup is Discord-rate-limited

### 4.6 Technical Debt Inventory

| Debt | Severity | Location | Notes |
|------|----------|----------|-------|
| `Database.swift` at 1,800 lines | Medium | App | Should split into per-entity files |
| `PlayerViewModel.swift` at 1,140 lines | Medium | App | Forwarding properties add verbosity |
| Zero shared code between CLI and app providers | Medium | Architecture | 6 providers implemented twice (Swift) plus a third time (Python) |
| README still says `vortex` binary, `~/.vortex/` paths | High | `README.md` | Confuses new users |
| Homebrew formula has `PLACEHOLDER_SHA256` | High | `homebrew-tap/vortex.rb` | Non-functional |
| CI uses `-project` instead of `-workspace` | High | `ci.yml:55` | **Will fail** — xcodegen wipes CocoaPods xcconfig refs |
| Bot still uses "Vortex" naming everywhere | Medium | All bot files | Inconsistent with rebrand |
| No migration versioning in bot DB | Low | `database.py` | Will break on schema changes |
| `SchedulerService` and `SoundtrackService` are scaffolding | Low | App | Limited real implementation |
| App icon PNGs missing from asset catalog | High | `Assets.xcassets` | App has no icon |
| Sentry DSN not configured | Low | `Info.plist` | Crash reporting is dead code |
| `SmartSkip.detectIntroPattern()` is a stub | Low | App | Returns nil |
| `increment_active` SQL has dead-code assignment | Low | `database.py:188` | Works by accident |
| `__pycache__/` committed to repo | Low | `discord-bot/` | Should be gitignored |

---

## 5. Data & State Management

### 5.1 Data Flow

**App generation flow:**
```
PromptStudioView → PromptStudioViewModel → PromptSafetyService (validate)
  → BudgetService (check limits) → SmartRouterService (pick provider)
  → GenerationQueueService (enqueue) → ProviderRegistry → FalProvider.submit()
  → Poll loop → Download → VideoEvaluatorService (score quality)
  → QualityGateService (enforce threshold) → CostTrackerService (record cost)
  → ProviderMetricsService (update stats) → Database (persist)
```

**CLI generation flow:**
```
GenerateCommand (parse args) → CLIKeychain.resolveKey() (env → keychain)
  → PromptSafetyChecker (validate) → BudgetManager (check limits)
  → GenerationEngine (submit + poll + download) → GenerationStore (persist JSON)
  → Output.print() (structured JSON to stdout)
```

**Bot generation flow:**
```
/generate (slash command) → KeyVault.decrypt() → SafetyChecker (validate)
  → RateLimiter (check limits) → Provider.submit() → Background poll task
  → Provider.poll() → Download video → Attach to Discord message
  → Database (update generation record)
```

### 5.2 State Management

**App:** `@Observable` singletons with computed `database` property for test isolation. `AppState.shared` for global state. `@Environment` injection for ViewModels. `@AppStorage` for simple preferences. This is clean and modern — no Combine, no `@Published`.

**CLI:** Flat JSON files with dual locking. No in-memory caching (load/save on every operation). Simple and correct.

**Bot:** SQLite for persistence, in-memory dict for active polls, in-memory cooldown tracking.

### 5.3 API Contracts

All three enforce the same provider API contract pattern: submit → get task ID → poll by ID → get video URL. Each normalizes to internal types:
- App: `GenerationSubmission` / `GenerationPollStatus`
- CLI: `GenerationSubmission` / `PollStatus`
- Bot: `SubmitResult` / `PollResult`

No formal API validation (no JSON Schema, no OpenAPI spec). Provider responses are parsed ad-hoc with manual key extraction.

### 5.4 Database Migration

**App:** Proper versioned migration system (GRDB migrator, v1-v8). Additive-only changes. Data migration from old app directory on init. Well-executed.

**CLI:** No migration needed — flat JSON files. Directory migration from `~/.vortex/` to `~/.openflix/` with `DataMigration.swift`.

**Bot:** `CREATE TABLE IF NOT EXISTS` only. No versioning. Adding a column will require manual SQL or a new migration system.

---

## 6. DX & Operational Readiness

### 6.1 README & Onboarding

| Aspect | Rating | Notes |
|--------|--------|-------|
| Top-level README | Outdated | Still says `vortex` binary, `~/.vortex/` paths, `brew install vortex` |
| CLI README (in VortexCLI/) | Good | 908 lines, comprehensive but has 27 stale references post-rename |
| Bot README | Good | Clean setup instructions, all commands documented |
| App onboarding | N/A | No user-facing docs; the app is self-explanatory |

### 6.2 Environment Setup

**App:**
```bash
xcodegen generate && pod install && open OpenFlix.xcworkspace
```
Chicken-and-egg problem if `Pods/` is deleted (need placeholder xcconfigs). Documented in memory but not in README.

**CLI:**
```bash
cd VortexCLI && swift build
```
Single dependency. Dead simple.

**Bot:**
```bash
cd discord-bot && pip install -r requirements.txt && export DISCORD_TOKEN=... && python bot.py
```
No `python-dotenv` — must manually export env vars. Mild friction.

### 6.3 Logging & Observability

| Codebase | Logging | Monitoring | Observability |
|----------|---------|-----------|---------------|
| App | OS unified logging (`os.Logger`) with 5 categories | Sentry (not configured) | Local-only `FeatureAnalytics` (UserDefaults counters, explicitly no-network) |
| CLI | Structured JSON to stderr for warnings/errors | None | Provider metrics stored locally |
| Bot | Python `logging` module, INFO level | None | Generation records in SQLite |

**No telemetry, no APM, no dashboards.** This is appropriate for current stage but will need addressing before any scale.

### 6.4 Feature Flags & A/B Testing

The app has a full `ABTestingService` — but it's for testing **prompt variants** against video generation models, not for testing app features. There are no feature flags in any of the three codebases.

---

## 7. Dependencies & Risk Analysis

### 7.1 Key Dependencies

| Dependency | Version | Used By | Risk |
|-----------|---------|---------|------|
| VLCKit | 3.7.2 | App | Core media engine. CocoaPods-only. Complex build integration. |
| GRDB | 6.24.1+ | App | SQLite layer. Active, well-maintained. Low risk. |
| Sparkle | 2.4.0+ | App | Auto-update. Mature, standard macOS. Low risk. |
| Sentry | 8.0.0+ | App (inactive) | Not configured. Dead weight. |
| swift-argument-parser | 1.3.0+ | CLI | Apple-maintained. Very low risk. |
| discord.py | 2.3.0+ | Bot | Active community project. Medium risk (breaking changes possible). |
| cryptography | 41.0.0+ | Bot | Industry standard. Low risk. |

### 7.2 Vendor Lock-in

**Low overall.** The provider abstraction layer (`VideoGenerationProvider` protocol / `BaseProvider` ABC) makes switching providers trivial. No single provider is privileged.

The biggest lock-in is **VLCKit** — the entire player is built on it. Replacing VLC with AVPlayer would be a multi-week effort, but VLCKit is open source and well-maintained, so this is acceptable.

### 7.3 Single Points of Failure

| SPOF | Impact | Mitigation |
|------|--------|-----------|
| VLCKit | Player is non-functional without it | VLCKit is LGPL, unlikely to disappear |
| macOS Keychain | All API keys inaccessible | Standard OS service, reliable |
| Bot `ENCRYPTION_KEY` | All user keys unrecoverable if lost | No backup/rotation mechanism |
| Bot SQLite file | All user data lost if corrupted | No backup strategy |
| Solo developer | All knowledge in one person | Codebase is well-structured and readable |

### 7.4 Bus Factor

**Bus factor: 1.** Solo developer project. However, the code is surprisingly readable and well-organized. The biggest complexity hotspots that would challenge a new developer:

1. `Database.swift` (1,800 lines, 8 migrations, 26 tables) — needs domain knowledge to modify safely
2. VLCKit integration in `PlayerEngine.swift` — requires understanding VLC's callback model
3. Keychain migration chain (3 prefixes across 2 products) — subtle, easy to break
4. CocoaPods/XcodeGen build pipeline — fragile, documented only in memory files

---

## 8. Product Gaps & Opportunities

### 8.1 Missing Features Users Would Expect

| Gap | Impact | Notes |
|-----|--------|-------|
| **No image-to-video in bot** | High | 13 models support I2V, architecture is ready, just needs a command parameter |
| **No progress indication during generation** | Medium | CLI `--stream` exists, but app shows no real-time progress from providers |
| **No generation history export** | Medium | Can't export generation records for analysis |
| **No multi-user support in app** | Low | Single-user assumption throughout |
| **No batch operations in app** | Medium | CLI has `batch` but app has no bulk generation UI |
| **No undo for delete/purge** | Low | Destructive operations are immediate |
| **No notification when generation completes** | Medium | App doesn't notify if in background; could use macOS notifications |

### 8.2 UX Rough Edges

1. **App has no icon.** The asset catalog references 10 PNG sizes but none exist. Users see a generic macOS app icon.
2. **"Vortex" naming persists in app** — `VortexModels.swift`, `VortexEnums.swift`, `VortexViewModel.swift`, all database table names start with `vortex`. Internal consistency matters for contributors.
3. **Studio tab is called "Studio" in the UI but "Vortex" in code** — mental model mismatch for anyone reading the source.
4. **README says `brew install vortex`** but the formula has a placeholder SHA and the binary is now `openflix`. First impressions matter.
5. **No onboarding flow in app** for setting up API keys — user must know to go to Settings > Studio tab.
6. **Welcome view is called `OrbitaWelcomeView`** — a third naming convention (Orbita?) alongside OpenFlix and Vortex.

### 8.3 Low-Hanging Fruit

| Improvement | Effort | Impact |
|-------------|--------|--------|
| Add `image_url` parameter to Discord `/generate` | S | Unlocks 13 I2V models |
| Fix CI to use `-workspace` instead of `-project` | S | Unbreaks CI |
| Update top-level README for post-rename | S | First impressions |
| Create actual app icon PNGs | S | Basic polish |
| Add `python-dotenv` to bot for local dev | S | Better DX |
| Fix `active_count` leak in bot poll task | S | Prevents stuck users |
| Add `__pycache__` to `.gitignore` | S | Clean repo |
| Configure Sentry DSN or remove dependency | S | Remove dead code |
| Add macOS notification when generation completes | M | Users don't have to watch |
| Add basic bot tests (at least for crypto + safety) | M | Security confidence |

### 8.4 Architectural Changes Before Scaling

1. **Shared provider library.** Three independent implementations of the same 6 providers is a maintenance nightmare. A shared Swift package (app + CLI) would cut provider code by ~40%. The Python bot could auto-generate from the same model definitions.

2. **CLI storage migration.** Flat JSON files won't scale past hundreds of generations. SQLite (via GRDB, matching the app) would solve this if the CLI gains heavier use.

3. **App Sandbox.** Required for Mac App Store distribution. Currently blocked by VLCKit's need for `disable-library-validation`. Would need to investigate VLCKit in-process loading or XPC helper.

4. **Code signing.** Currently ad-hoc. Need Developer ID Application certificate + notarization for distribution outside the App Store.

---

## 9. Prioritized Recommendations

| # | Recommendation | Why | Effort | Impact |
|---|---------------|-----|--------|--------|
| **1** | **Fix CI (`-workspace` not `-project`)** | CI is likely broken. If not tested on push, regressions ship silently. | S | Critical |
| **2** | **Update top-level README post-rename** | First thing anyone sees on GitHub. Currently says `vortex` everywhere. Erodes trust. | S | High |
| **3** | **Create app icon PNGs** | An app without an icon looks abandoned. | S | High |
| **4** | **Add basic Discord bot tests** | Zero tests on code that handles encrypted API keys. At minimum: crypto roundtrip, safety checker, rate limiter. | M | High |
| **5** | **Fix bot `active_count` leak** | If poll task throws, user is permanently stuck at max concurrent. Add try/finally around the poll loop. | S | High |
| **6** | **Add I2V support to Discord bot** | 13 models already support it. Just add `image_url` parameter to `/generate`. Maximum feature per line of code. | S | Medium |
| **7** | **Rebrand bot from "Vortex" to "OpenFlix"** | Class names, DB name, systemd service, README — all still say Vortex. Inconsistent branding across the product. | M | Medium |
| **8** | **Configure Sentry or remove it** | Dead dependency. Either use it (add DSN) or remove it to reduce binary size and attack surface. | S | Low |
| **9** | **Split `Database.swift` into per-entity files** | 1,800 lines is too large. Hard to review, hard to find things. No functional change needed — just file splitting. | M | Medium |
| **10** | **Implement shared provider library (CLI + App)** | Maintaining 6 providers in two Swift codebases doubles the work for every API change. Extract into a Swift package. | XL | High (long-term) |

---

## Appendix: What's Impressive

This report is deliberately critical, so it's worth calling out what's genuinely well-done:

1. **CLI dependency count: 1.** `swift-argument-parser` is the only external dependency. Everything else is Foundation. This is remarkable discipline.

2. **Error taxonomy.** The CLI's two-layer error system (`OpenFlixError` for user-facing + `StructuredError` for machine-readable) with JSON output is better than most production CLIs.

3. **Provider abstraction.** The protocol-based provider layer in all three codebases is clean. Adding a new provider is ~80 lines of code that follows a clear pattern.

4. **Security in OpenSubtitles.** File size validation, extension sanitization, path traversal prevention, HTTPS-only — this is the kind of defensive coding most projects skip.

5. **Test isolation pattern.** The computed `database` property pattern for singleton test isolation is elegant and was applied consistently across all 11 services.

6. **MCP server.** 14 tools and 3 resources for agentic integration is forward-thinking. Most video generation tools don't have this.

7. **Feature breadth.** For a solo developer, shipping 60 features across a macOS app + CLI + Discord bot with 333 passing tests is genuinely impressive output.

---

*Report generated 2026-04-11. All ~150 Swift files, ~20 Python files, and all config/test/doc files read in full.*
