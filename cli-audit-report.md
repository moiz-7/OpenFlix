# OpenFlix CLI -- Comprehensive Codebase Audit Report

**Date:** 2026-04-11
**Scope:** Every file in `/Users/moizsaeed/Documents/Developer/VidViewer/VortexCLI/`
**Total Swift source files read:** 60 (1 entry point + 24 Core + 27 Commands + 7 Providers + 1 Output)
**Additional files read:** Package.swift, test.sh (1364 lines), README.md (908 lines)

---

## 1. Package.swift

**File:** `/Users/moizsaeed/Documents/Developer/VidViewer/VortexCLI/Package.swift`

- **Package name:** `OpenFlixCLI`
- **Executable product:** `openflix`
- **Swift tools version:** 5.9
- **Platform requirement:** macOS 14+ (Sonoma)
- **Dependencies:** A single dependency -- `swift-argument-parser` 1.3.0+ from Apple
- **Linker settings:** Links the `Security` framework (used for macOS Keychain access in `CLIKeychain.swift`)
- **Source path:** `Sources/openflix/`

Notable: This is an exceptionally lean dependency graph. The entire CLI is built with one external dependency. All HTTP networking uses Foundation's `URLSession` directly. All JSON handling uses Foundation's `JSONSerialization` and `JSONEncoder`/`JSONDecoder`. There are no third-party networking, logging, or concurrency libraries.

---

## 2. Every Source File -- Detailed Findings

### 2.1 Entry Point

**`Sources/openflix/OpenFlixCLI.swift`** -- 84 lines
- `@main struct OpenFlix: AsyncParsableCommand`
- Version string: `"1.0.0"`
- Registers 21 subcommands: Generate, Status, List, Download, Cancel, Delete, Retry, Purge, Health, Providers, Models, Keys, Cost, Batch, ProjectGroup, Daemon, Evaluate, Feedback, Metrics, Budget, MCP
- Discussion text includes quick-start examples, environment variable list, project commands, and batch usage
- No TODOs or stubs

### 2.2 Core/ (24 files)

**`Core/Models.swift`** -- 308 lines
- **Key types:**
  - `CLIGeneration` -- Primary data model with 22 fields. Status enum: queued/submitted/processing/succeeded/failed/cancelled. Has `jsonRepresentation` computed property that outputs snake_case keys with optional-nil elision.
  - `CLIProviderModel` -- Static model info (providerId, modelId, displayName, dimensions, cost, i2v support)
  - `OpenFlixError` -- 12-case error enum with `code` and `errorDescription` computed properties. Cases: noApiKey, httpError, invalidResponse, rateLimited, providerNotFound, timeout, downloadFailed, generationNotFound, generationFailed, notComplete, budgetExceeded, promptBlocked
  - `ErrorCode` -- 18-case string-backed enum for structured error taxonomy (AUTH_MISSING through CONFIG_INVALID). Has `retryable` and `httpEquivalent` computed properties.
  - `StructuredError` -- Bridges `OpenFlixError` to a Codable JSON structure with code, message, details, retryable, retryAfterSeconds
  - `GenerationRequest` -- Value type for provider submissions
  - `GenerationSubmission` -- Return type from provider submit
  - `PollStatus` -- Enum with associated values: queued, processing(progress:), succeeded(videoURL:), failed(message:)
- **Code quality:** Clean. Each `ISO8601DateFormatter()` instantiation inside `jsonRepresentation` creates a new formatter per call -- minor performance note for bulk operations, but negligible in practice.
- **No TODOs, no stubs, no force unwraps.**

**`Core/GenerationStore.swift`** -- 122 lines
- Singleton (`static let shared`), JSON-backed at `~/.openflix/store.json`
- Dual locking: `flock()` for cross-process safety + `NSLock` for in-process thread safety
- Calls `DataMigration.migrateDataDirectoryIfNeeded()` in `init()`
- CRUD operations: `save`, `get`, `all`, `delete`, `update(id:mutate:)`, `filter(status:provider:limit:)`
- Encoder configured with ISO8601 dates, pretty-printed, sorted keys, without escaping slashes
- Error handling: encode/write failures logged to stderr as JSON, never crash
- **No TODOs, no stubs.**

**`Core/GenerationEngine.swift`** -- 292 lines
- Static methods only -- no instance state
- `submit()`: Resolves API key, runs prompt safety check, runs budget pre-flight check, calls provider.submit(), saves to GenerationStore
- `submitAndWait()`: Retry loop wrapping submit + waitForCompletion. Retries on `generation_failed` or `rate_limited` errors. Exponential backoff capped at 30s. Respects Retry-After header for rate limits. Cleans up orphan generations on retry by deleting the previous failed generation.
- `waitForCompletion()`: Poll loop with deadline. On transient errors (URLError, rate_limited, http_error), retries up to 3 times with linear backoff before propagating. On success: records spend via BudgetManager, attempts download, records download failure as warning (generation stays succeeded). On failure: marks generation failed and throws.
- **Design decision:** Download failures are non-fatal. Generation status remains `succeeded` with an `errorMessage` containing a retry hint. This is correct -- the video exists on the provider's servers and is retriable.
- **No TODOs, no stubs, no force unwraps.**

**`Core/CLIKeychain.swift`** -- 141 lines
- Service prefix: `"com.openflix.cli"`
- Migration chain (guarded by UserDefaults flags):
  - V1: `com.meridian.vortex.*` to `com.openflix.cli.*`
  - V2: `com.openflix.vortex.*` to `com.openflix.cli.*`
- Migration deletes old entries after successful copy (only if target doesn't already exist)
- Key resolution priority (6 levels):
  1. `--api-key` flag
  2. `OPENFLIX_{PROVIDER}_KEY` env var
  3. `VORTEX_{PROVIDER}_KEY` env var (legacy)
  4. `OPENFLIX_API_KEY` env var (generic fallback)
  5. `VORTEX_API_KEY` env var (legacy generic)
  6. macOS Keychain
- Known providers: fal, replicate, runway, luma, kling, minimax
- **Security concern:** API keys passed via `--api-key` flag are visible in process listings (`ps aux`). This is documented behavior and consistent with how most CLIs work, but worth noting.
- **No TODOs, no stubs.**

**`Core/DataMigration.swift`** -- 33 lines
- One-time migration of `~/.vortex/` to `~/.openflix/`
- Guarded by UserDefaults flag `"com.openflix.cli.data.migrated"`
- Skips if `~/.openflix/` already exists
- On failure: logs warning to stderr, never crashes
- **Clean, minimal, correct.**

**`Core/VideoDownloader.swift`** -- (read in previous session)
- Static download directory: `~/.openflix/downloads/`
- Downloads via URLSession with 120s request timeout, 3600s resource timeout
- Atomic move from temp to destination
- Creates parent directories as needed
- **No force unwraps.**

**`Core/BudgetManager.swift`** -- 181 lines
- Swift `actor` (proper concurrency isolation)
- Config at `~/.openflix/budget_config.json`: dailyLimitUSD, perGenerationMaxUSD, monthlyLimitUSD, warningThresholdPercent (default 80%)
- Daily spend at `~/.openflix/daily_spend.json`: date, totalUSD, generationCount
- `preFlightCheck()` returns `.approved`, `.warning(remaining:)`, or `.denied(reason:)` -- checked in GenerationEngine.submit()
- `recordSpend()`: increments daily counters
- `statusSummary()`: Returns dictionary for CLI/MCP output
- **Known limitation (lines 142-148):** Monthly tracking is approximated -- `loadMonthlySpend()` only returns the current day's total. The code comments acknowledge this: "A production system would aggregate across days". This means the monthly budget limit is effectively a daily limit with different threshold semantics.
- **No TODOs beyond the acknowledged monthly limitation.**

**`Core/PromptSafetyChecker.swift`** -- 75 lines
- Local heuristic, zero API calls, zero network access
- Two tiers:
  - **Blocked (immediate rejection):** csam, extreme_violence, pii_generation, malware -- 4 categories with 15 keywords total
  - **Warning (flagged, not blocked):** violence, suggestive, deceptive -- 3 categories with 11 keywords total
- Returns `CheckResult` with level (safe/warning/blocked), flags array, and sanitized text
- Only blocked prompts prevent generation (in GenerationEngine.submit). Warnings are recorded but do not prevent submission.
- **Limitation:** Simple substring matching. "how to hack" would block "how to hack a pinata". However, this is acceptable for a local heuristic -- the real safety filtering happens at the provider level.
- **No TODOs, no stubs.**

**`Core/ProviderRouter.swift`** -- (read in previous session)
- 5 routing strategies: cheapest, fastest, quality, manual, scatterGather
- `cheapest`: sorts by costPerSecondUSD, picks lowest
- `fastest`: sorts by maxDurationSeconds (shortest), picks first -- this is a heuristic proxy for actual latency
- `quality`: uses `ProviderMetricsStore.rankedByQuality()`, falls back to cheapest if no quality data
- `manual`: requires provider+model on each shot, throws if missing
- `scatterGather`: picks first viable candidate
- `scatterTargets()`: Prioritizes provider diversity first (one model per unique provider), then fills remaining slots with additional models from already-used providers
- `availableProviders()`: checks which providers have resolved API keys (via `CLIKeychain.resolveKey`)
- **No TODOs, no stubs.**

**`Core/ProviderMetricsStore.swift`** -- (read in previous session)
- Singleton, JSON at `~/.openflix/metrics.json`, flock+NSLock
- Tracks per provider+model: totalGenerations, succeeded, failed, totalLatencyMs, totalCostUSD, qualityScores (last 100), feedbackScores (last 100)
- Computed properties: avgQuality, avgLatencyMs, avgCostUSD, successRate
- Rolling window for quality/feedback (capped at 100 entries)
- **No TODOs, no stubs.**

**`Core/EvaluatorProtocol.swift`** -- (read in previous session)
- `VideoEvaluator` protocol: `func evaluate(videoPath: String, prompt: String, generation: CLIGeneration) async throws -> EvaluationResult`
- `EvaluationResult`: score (0-100), passed, reasoning, evaluator name, dimensions dictionary, evaluatedAt
- `QualityConfig`: enabled, evaluator (.heuristic / .llmVision), threshold (60 default), maxRetries (1), claudeApiKey, claudeModel ("claude-sonnet-4-20250514"), maxFrames (4)
- **No stubs.**

**`Core/HeuristicEvaluator.swift`** -- (read in previous session)
- 100-point scoring system:
  - File exists: 20 points
  - File size 50KB-2GB: 20 points (0 if outside range)
  - Video extension (.mp4/.mov/.webm): 10 points
  - ffprobe duration > 0: 10 points
  - ffprobe resolution > 0: 10 points
  - ffprobe codec detected: 10 points
  - Generation status succeeded: 20 points
- Runs `ffprobe` via `Process()`. If ffprobe is unavailable, awards 5 partial-credit points per ffprobe dimension (15 total) instead of the full 30.
- Pipe file handles closed in defer blocks (fixed in Round 7 robustness audit)
- **No TODOs, no force unwraps.**

**`Core/LLMVisionEvaluator.swift`** -- (read in previous session)
- Extracts N frames from video via `ffmpeg -vf "select=not(mod(n\,...))" -vsync vfn -frames:v N`
- Base64 encodes frames as JPEG
- Calls Claude API at `api.anthropic.com/v1/messages` with multimodal image_content blocks
- System prompt requests JSON with 5 dimensions: prompt_adherence, visual_quality, temporal_coherence, composition, technical_quality (each 0-100)
- Extracts JSON from response, handles markdown code blocks (```json ... ```)
- Uses temp directory with UUID prefix `openflix_eval_`
- **External API call:** Claude API (Anthropic) for vision evaluation
- **No TODOs, no force unwraps.**

**`Core/QualityGate.swift`** -- (read in previous session)
- `evaluate()`: creates evaluator instance (heuristic or LLM vision based on config), calls it, records quality score via ProviderMetricsStore
- `check()`: calls evaluate, returns (passed, result, shouldRetry). Evaluation failure = pass through (quality is advisory, never blocking). This is a deliberate design decision.
- **No stubs.**

**`Core/ProjectModels.swift`** -- (read in previous session)
- **Project:** id, name, description, status (draft/running/paused/succeeded/partialFailure/failed/cancelled), scenes, settings, costBudgetUSD, timestamps. Has `allShots` computed property.
- **Scene:** id, name, orderIndex, shots, referenceAssets, metadata dictionary
- **Shot:** 30+ fields including dependencies array (shot IDs), generationIds array, selectedGenerationId, qualityScore, evaluationReasoning, evaluationDimensions, qualityRetryCount. Status: pending/ready/dispatched/processing/evaluating/succeeded/failed/skipped/cancelled
- **ReferenceAsset:** with AssetType enum (characterReference, styleReference, backgroundReference, frameExtract)
- **ProjectSettings:** defaultProvider, defaultModel, defaultAspectRatio, defaultDuration, maxConcurrency (4), maxRetriesPerShot (2), timeoutPerShot (600s), scatterCount, routingStrategy, qualityConfig
- **ProjectSpec + nested spec types:** with CodingKeys for snake_case JSON input. Supports dependency names (resolved to IDs in ProjectStore.createFromSpec)
- **BatchItem:** simple struct for batch command input
- **No TODOs, no stubs.**

**`Core/ProjectStore.swift`** -- 305 lines
- Singleton, per-project directories at `~/.openflix/projects/<id>/project.json`
- Per-project file locking (each project gets its own lock file)
- CRUD: save, get, list, delete, update(id:mutate:), updateShot(projectId:shotId:mutate:)
- `createFromSpec()`: Builds Project from ProjectSpec. Assigns UUIDs to projects, scenes, and shots. Resolves shot dependency names to IDs. Validates DAG (no cycles) via DAGResolver. Throws `ProjectSpecError` on duplicate shot names or cyclic dependencies.
- **Error types:** ProjectSpecError enum with duplicateShotName, cyclicDependency, invalidSpec cases
- **No TODOs, no stubs, no force unwraps** (except one intentional `!` on line 205 for `shotNameToId[specShot.name]!` which is safe because the name was inserted into the map on lines 151-157 and duplicates were already caught).

**`Core/DAGExecutor.swift`** -- 479 lines
- **DAGResolver:** Kahn's algorithm for topological sort into parallelism "waves". Cycle detection throws `ProjectSpecError.cyclicDependency`. `readyShots()` returns shots whose all dependencies are in succeeded/skipped state.
- **DAGExecutor:** Swift actor. Main dispatch loop:
  1. Validate DAG (no cycles)
  2. Mark project running
  3. Loop: find ready shots, dispatch up to maxConcurrency minus currently running
  4. Per-shot: resolve provider/model via ProviderRouter, check cost budget, dispatch single or scatter-gather
  5. Compute final status: succeeded (all), partialFailure (some failed + some succeeded), failed (all failed), cancelled
- `executeSingleShot()`: Uses GenerationEngine.submitAndWait, links generation to project/shot, records metrics, runs quality gate. Quality retries reset shot to pending with incremented qualityRetryCount.
- `executeScatterGather()`: Uses ScatterGatherExecutor.scatter + selectBest
- `cancel()` / `pause()`: Sets cancelled flag, updates project status
- **Design note:** The main loop polls every 1 second when waiting for running shots. This is acceptable for a CLI tool but would need event-driven notification for higher efficiency.
- **No TODOs, no force unwraps.**

**`Core/ScatterGather.swift`** -- (read in previous session)
- `ScatterResult`: generationId, provider, model, status, costUSD, qualityScore, evaluationResult, errorMessage
- `scatter()`: `withTaskGroup` parallel dispatch to N provider+model targets
- `selectBest()` (simple): first succeeded result
- `selectBest()` (quality-aware): runs quality evaluation on succeeded results, picks highest score
- **No stubs.**

**`Core/DaemonProtocol.swift`** -- (read in previous session)
- DaemonRequest, DaemonResponse, DaemonError, DaemonEvent -- JSON-RPC-like structures
- `AnyCodableValue`: Type-erased Codable enum with cases: string, int, double, bool, dictionary, array, null. Has `toAny()` and `from(Any)` bridging methods. This is the core type used throughout MCP and daemon for heterogeneous JSON.
- DaemonMethods: 13 method string constants
- **No stubs.**

**`Core/DaemonServer.swift`** -- (read in previous session)
- Swift actor, Unix domain socket at `~/.openflix/daemon.sock`, PID at `~/.openflix/daemon.pid`
- Uses `NWListener` with TCP transport over Unix endpoint (Network framework)
- Handles methods: health, projectList, projectStatus, subscribe/unsubscribe, evaluate, feedback, providerMetrics
- Broadcasts events to subscribed sessions
- **No TODOs, no stubs.**

**`Core/DaemonSession.swift`** -- (read in previous session)
- Per-connection state with subscribedProjects set
- Reads newline-delimited JSON from NWConnection
- send() and sendEvent() append newline to payload
- **No stubs.**

**`Core/MCPProtocol.swift`** -- (read in previous session)
- MCPRequest, MCPResponse, MCPError, MCPNotification -- JSON-RPC 2.0 structures
- MCPToolDefinition, MCPResourceDefinition with `toAnyCodable()` methods
- MCPErrorCode constants: parseError (-32700), invalidRequest (-32600), methodNotFound (-32601), invalidParams (-32602), internalError (-32603)
- **No stubs.**

**`Core/MCPServer.swift`** -- 547 lines
- Swift actor, stdio-based (readLine loop)
- Handles: initialize, notifications/initialized, shutdown, tools/list, tools/call, resources/list, resources/read, ping
- 14 tools dispatched: generate, generate_submit, generate_poll, list_generations, get_generation, cancel_generation, retry_generation, list_providers, evaluate_quality, submit_feedback, get_metrics, budget_status, project_run, health_check
- 3 resources: openflix://providers, openflix://metrics, openflix://budget
- Error handling: OpenFlixError instances are returned as content with `isError: true` (not JSON-RPC error responses), preserving structured error info for agents. Other errors return JSON-RPC error responses.
- **Stub: `toolProjectRun` (lines 438-448)** -- Does not actually execute the project. Returns a message telling the user to use the CLI instead: `"use 'openflix project run <id>' for full execution"`. This is the only stub in the entire codebase.
- **No TODOs, no force unwraps.**

**`Core/MCPToolRegistry.swift`** -- 215 lines
- Defines all 14 MCPToolDefinition with JSON Schema inputSchema
- Defines all 3 MCPResourceDefinition
- Helper functions: objectSchema, stringProp, intProp, numberProp, boolProp
- **Schema quality:** All required fields are marked, descriptions are clear and useful for agent consumption
- **No stubs.**

### 2.3 Providers/ (7 files)

**`Providers/ProviderProtocol.swift`** -- 78 lines
- `VideoProvider` protocol: providerId, displayName, models, submit(), poll(), estimateCost(), cancel() (default no-op)
- `ProviderRegistry`: Singleton with dictionary of 6 providers, sorted by displayName for consistent output
- `URLSession.jsonData()`: Shared HTTP helper. Handles 429 (extracts Retry-After header), non-2xx errors (truncates body to 500 chars), non-HTTP responses
- `makeSession()`: Ephemeral config with 30s request timeout, 120s resource timeout
- **No force unwraps** (the protocol and registry are clean).

**`Providers/FalClient.swift`** -- 109 lines
- **Provider ID:** `fal`
- **8 models:**
  - Seedance 2.0 (text-to-video, $0.05/s, max 15s)
  - Seedance 2.0 I2V (image-to-video, $0.06/s, max 15s)
  - Kling v2 Master ($0.06/s, max 10s, i2v support)
  - Hailuo 02 ($0.05/s, max 6s)
  - Luma Dream Machine ($0.08/s, max 5s)
  - Hunyuan Video ($0.04/s, max 5s)
  - Wan 2.1 1080p ($0.03/s, max 5s, 1920x1080 default)
  - Veo 3 ($0.15/s, max 8s)
- **API:** POST to `https://queue.fal.run/{model}`, auth header `Key {apiKey}`
- **Poll:** GET status_url, then GET response_url on COMPLETED. Handles three response shapes: `video.url`, `video_url`, `videos[0].url`
- Duration sent as string (`"\(Int(d))"`) -- this is intentional for fal.ai's API
- **External API calls:** fal.ai queue API
- **No force unwraps.**

**`Providers/ReplicateClient.swift`** -- 98 lines
- **Provider ID:** `replicate`
- **4 models:**
  - MiniMax Video-01 Live ($0.05/s, max 6s)
  - Hunyuan Video ($0.04/s, max 5s)
  - Wan 2.1 ($0.03/s, max 5s)
  - Kling v1.6 Pro ($0.10/s, max 10s, i2v support)
- **API:** POST to `https://api.replicate.com/v1/predictions` with version+input, auth `Bearer`
- **Poll:** GET urls.get URL, output is string array
- Duration converted to frames: `Int(d * 8)` (8 fps estimate)
- Uses `addingPercentEncoding` for safe URL construction in poll fallback
- **No force unwraps.**

**`Providers/RunwayClient.swift`** -- 89 lines
- **Provider ID:** `runway`
- **2 models:**
  - Gen-4 Turbo ($0.05/s, max 10s, i2v)
  - Gen-4.5 ($0.10/s, max 10s, i2v)
- **API version:** `X-Runway-Version: 2024-11-06`
- **API:** POST to `https://api.runwayml.com/v1/text_to_video`, auth `Bearer`
- **Poll:** GET `/v1/tasks/{taskId}`, extracts progress from `progress` field
- Sends resolution as ratio: `"\(w):\(h)"`
- Static base URL pattern (`fatalError` on invalid URL -- safe because it's a compile-time constant)
- **No runtime force unwraps.**

**`Providers/LumaClient.swift`** -- 89 lines
- **Provider ID:** `luma`
- **3 models:**
  - Ray 2 ($0.10/s, max 5s, i2v)
  - Ray Flash 2 ($0.05/s, max 5s, i2v)
  - Ray 3 ($0.20/s, max 10s, i2v)
- **API:** POST to `https://api.lumalabs.ai/dream-machine/v1/generations`, auth `Bearer`
- **Poll:** GET `/generations/{taskId}`, state field: pending/dreaming/completed/failed
- Image-to-video uses keyframes: `frame0: {type: "image", url: ...}`
- Static base URL pattern
- **No runtime force unwraps.**

**`Providers/KlingClient.swift`** -- 94 lines
- **Provider ID:** `kling`
- **3 models:**
  - v2.6 Pro ($0.10/s, max 10s, i2v)
  - v2.6 Standard ($0.05/s, max 10s, i2v)
  - v2.5 Turbo ($0.03/s, max 5s, i2v)
- **Dynamic endpoint:** `image_to_video` vs `text_to_video` based on referenceImageURL presence
- **API:** POST to `https://api.klingapi.com/v1/videos/{endpoint}`, auth `Bearer`
- **Poll:** Uses statusURL with fallback to constructed URL. Success status is `"succeed"` (not `"succeeded"`)
- Response wraps data in `{code: 0, data: {task_id: ...}}` structure
- Static base URL pattern
- **No runtime force unwraps.**

**`Providers/MiniMaxClient.swift`** -- 116 lines
- **Provider ID:** `minimax`
- **3 models:**
  - Hailuo 2.3 ($0.05/s, max 10s)
  - T2V-01 Director ($0.04/s, max 6s)
  - S2V-01 I2V ($0.05/s, max 6s, i2v)
- **3-step flow:**
  1. POST `/v1/video_generation` -- returns task_id
  2. GET `/v1/query/video_generation?task_id=` -- returns status + file_id
  3. GET `/v1/files/retrieve?file_id=` -- returns download_url
- Uses `URLComponents` for safe query parameter construction (no force unwraps)
- Response wraps in `{base_resp: {status_code: 0}, task_id: ...}` structure
- **No force unwraps.**

### 2.4 Output/ (1 file)

**`Output/Output.swift`** -- 94 lines
- Static methods on an enum (no instances)
- `emit<T:Encodable>`: JSONEncoder output to stdout
- `emitDict`: JSONSerialization output for [String: Any] dictionaries
- `emitArray`: JSONSerialization output for arrays
- `emitEvent`: Same as emitDict but flushes stdout immediately for streaming
- `fail`: Writes JSON error to stderr, calls `exit(1)` -- returns `Never`
- `failMessage`: Same but with string message
- `failStructured`: Writes structured error to stderr for MCP/agent consumers
- `writeStructuredError`: Returns structured error dict (non-exiting, for MCP responses)
- Pretty-print toggle via `static var pretty`
- All serialization failures log to stderr
- **No force unwraps, no crashes on serialization failure.**

### 2.5 Commands/ (27 files)

All commands follow the same pattern: `struct X: AsyncParsableCommand` with `mutating func run() async throws`.

**`GenerateCommand.swift`** -- 229 lines
- 17 options/flags: prompt (argument), --provider, --model, --duration, --aspect-ratio, --width, --height, --negative-prompt, --image, --param (repeatable), --wait, --stream, --timeout, --poll-interval, --output, --api-key, --pretty, --skip-download, --retry, --dry-run
- Input validation: empty prompt, negative retry count, duration bounds (>0, <=600, <=model max), image file existence check for local paths
- Extra params: key=value parsing with type inference (bool/int/double/string)
- Dry-run mode: validates key resolution, estimates cost, returns without API call
- **No stubs.**

**`StatusCommand.swift`** -- Terminal status short-circuit (no remote poll for succeeded/failed/cancelled). `--cached` returns store data without any polling. Default: polls once, updates store.

**`ListCommand.swift`** -- Filters by status/provider, supports --limit, --oldest (sort ascending), --search (prompt substring match). Returns generation array with total/returned counts.

**`DownloadCommand.swift`** -- Downloads video for a specific generation. Validates generation exists and has a remote video URL. Supports custom output path.

**`CancelCommand.swift`** -- Validates generation is not in terminal state. Updates store to cancelled.

**`DeleteCommand.swift`** -- Deletes from store. Validates generation exists.

**`RetryCommand.swift`** -- Validates generation is failed. Creates new generation with same parameters.

**`PurgeCommand.swift`** -- Deletes generations by status filter, or all if no filter. Returns count of purged entries.

**`HealthCommand.swift`** -- Reports store file accessibility, downloads directory, and per-provider key configuration status. Returns JSON with per-provider `configured` boolean.

**`ProvidersCommand.swift`** -- Lists all providers with configured status.

**`Models` (subcommand of OpenFlix)** -- Lists all models, optionally filtered by --provider. Returns model array with capabilities.

**`KeysCommand.swift`** -- Subcommands: set, delete, list. `set` stores key in Keychain, `delete` removes it, `list` shows configured providers (boolean, never exposes actual keys).

**`CostCommand.swift`** -- Aggregates costs from GenerationStore. Groups by provider, shows estimated vs actual totals.

**`BatchCommand.swift`** -- JSON array input from --file or stdin. Uses `AsyncSemaphore` actor for concurrency limiting. `ResultsCollector` actor for thread-safe result aggregation. Validates all items before execution. --wait and --concurrency options.

**`ProjectCommand.swift`** -- Groups project subcommands: create, run, status, list, delete, shot, export.

**`ProjectCreateCommand.swift`** -- Reads JSON spec from --file or stdin. Calls ProjectStore.createFromSpec(). Outputs created project.

**`ProjectRunCommand.swift`** -- Creates DAGExecutor with settings from project + CLI overrides. Supports --stream, --max-concurrency, --skip-download, --evaluate, --strategy. Outputs final project status.

**`ProjectStatusCommand.swift`** -- Shows project with optional --detail (full scenes+shots) or summary.

**`ProjectListCommand.swift`** -- Lists all projects sorted by creation date.

**`ProjectDeleteCommand.swift`** -- Deletes project directory.

**`ProjectShotCommand.swift`** -- 5 subcommands: add, retry, skip, update, remove. Shot add assigns orderIndex based on existing count. Shot update can link generation IDs and change status.

**`ProjectExportCommand.swift`** -- Generates ffmpeg concat demuxer file from succeeded shots. Includes quality scores and evaluation data in manifest. Outputs ffmpeg command for video stitching.

**`DaemonCommand.swift`** -- Subcommands: start, stop, status. Start has --foreground flag. Background mode logs `nohup` suggestion (no native fork/exec in Swift). Foreground blocks forever via `withCheckedContinuation`.

**`EvaluateCommand.swift`** -- Evaluates a completed generation. Supports --evaluator (heuristic/llm-vision), --threshold, --claude-key, --claude-model, --frames.

**`FeedbackCommand.swift`** -- Records human quality feedback (0-100 score + optional reason) for a generation via ProviderMetricsStore.

**`MetricsCommand.swift`** -- Displays provider metrics with --sort (quality/latency/cost/success_rate) and --provider filter.

**`BudgetCommand.swift`** -- Subcommands: set, status, reset. Set: --daily, --per-gen, --monthly, --warning-threshold. Status: shows current config and spend. Reset: zeroes daily spend.

**`MCPCommand.swift`** -- Creates MCPServer actor and calls run(). No options -- always stdio.

**Summary of all commands:** 27 command files implementing 21 top-level subcommands (plus nested subcommands for project, keys, budget, daemon, shot). No stubs except the `project_run` MCP tool noted above.

---

## 3. test.sh

**File:** `/Users/moizsaeed/Documents/Developer/VidViewer/VortexCLI/test.sh` -- 1364 lines

- **Test count:** The memory file claims 151/151 pass. The script has 144 numbered test sections but some sections contain multiple assertions.
- **Strategy:** Bash integration tests. Mix of:
  - `--help` output checks (verifying flags/subcommands exist)
  - Source code `grep` checks (verifying patterns exist in Swift files)
  - Runtime behavior tests (budget set/status/reset, project CRUD lifecycle, build verification)
- **Build verification:** Both debug and release builds tested
- **Runtime tests:**
  - Creates actual projects via JSON spec files
  - Tests project CRUD lifecycle (create, status, list, delete)
  - Tests budget commands (set, status, reset)
  - Tests key resolution order via env var unsetting
  - Tests help output for every command
- **No XCTest / Swift unit tests.** All testing is bash-based integration testing.
- **Coverage:** Good surface-level coverage of all commands and options, but no mocking of provider APIs, no testing of error paths with actual HTTP responses, no concurrency testing.
- **Test isolation:** Not documented. Tests modify `~/.openflix/` state which could interfere with real user data.

---

## 4. README.md

**File:** `/Users/moizsaeed/Documents/Developer/VidViewer/VortexCLI/README.md` -- 908 lines

- Comprehensive documentation covering all commands, providers, architecture
- Well-organized with table of contents, examples, flag tables
- Homebrew install: `brew install bubble-research/tap/openflix`

**STALE REFERENCES (27 occurrences across README):**

The README has not been fully updated after the Round 14 internal rename. The following references are stale:

| Line | Stale Reference | Should Be |
|------|----------------|-----------|
| 83 | `~/.vortex/daemon.sock` | `~/.openflix/daemon.sock` |
| 172 | `~/.vortex/downloads/<id>.mp4` | `~/.openflix/downloads/<id>.mp4` |
| 181 | `~/.vortex/store.json` | `~/.openflix/store.json` |
| 267 | `VORTEX_<PROVIDER>_KEY` | `OPENFLIX_<PROVIDER>_KEY` (primary) |
| 268 | `VORTEX_API_KEY` | `OPENFLIX_API_KEY` (primary) |
| 269 | `com.openflix.vortex.<provider>` | `com.openflix.cli.<provider>` |
| 497 | `~/.vortex/daemon.sock`, `~/.vortex/daemon.pid` | `~/.openflix/daemon.sock`, `~/.openflix/daemon.pid` |
| 511 | `VORTEX_<PROVIDER>_KEY` | `OPENFLIX_<PROVIDER>_KEY` |
| 574 | `~/.vortex/budget_config.json`, `~/.vortex/daily_spend.json` | `~/.openflix/budget_config.json`, `~/.openflix/daily_spend.json` |
| 647-649 | `vortex://providers`, `vortex://metrics`, `vortex://budget` | `openflix://providers`, `openflix://metrics`, `openflix://budget` |
| 663 | `~/.vortex/daemon.sock` | `~/.openflix/daemon.sock` |
| 768 | `VortexCLI.swift` | `OpenFlixCLI.swift` |
| 779 | `VortexError` | `OpenFlixError` |
| 781-793 | `~/.vortex/` paths (7 occurrences) | `~/.openflix/` |
| 808-809 | `VortexError.promptBlocked`, `VortexError.budgetExceeded` | `OpenFlixError.promptBlocked`, `OpenFlixError.budgetExceeded` |
| 812 | `~/.vortex/downloads/<id>.mp4` | `~/.openflix/downloads/<id>.mp4` |
| 819-826 | `~/.vortex/` paths (8 occurrences) | `~/.openflix/` |
| 899 | `com.openflix.vortex.<provider>` | `com.openflix.cli.<provider>` |

The key resolution section (lines 267-269) lists env vars with `VORTEX_*` as primary but the code uses `OPENFLIX_*` as primary and `VORTEX_*` as legacy fallback.

---

## 5. Data Models -- What Gets Stored, Where, Schema

### Generation Store
- **Path:** `~/.openflix/store.json`
- **Schema:** `[String: CLIGeneration]` -- dictionary keyed by generation UUID
- **Fields per generation:** id, status, provider, model, prompt, negativePrompt, aspectRatio, widthPx, heightPx, durationSeconds, remoteTaskId, statusURL, remoteVideoURL, localPath, estimatedCostUSD, actualCostUSD, errorMessage, retryCount, projectId, shotId, createdAt, submittedAt, completedAt
- **Encoding:** ISO8601 dates, pretty-printed, sorted keys

### Project Store
- **Path:** `~/.openflix/projects/<project-id>/project.json`
- **Schema:** `Project` struct with nested scenes and shots
- **Project fields:** id, name, description, status, scenes, settings, costBudgetUSD, totalEstimatedCostUSD, totalActualCostUSD, createdAt, updatedAt, completedAt
- **Scene fields:** id, name, description, orderIndex, shots, referenceAssets, metadata
- **Shot fields (30+):** id, sceneId, name, orderIndex, prompt, negativePrompt, status, provider, model, duration, aspectRatio, width, height, referenceImageURL, referenceAssetId, extraParams, dependencies, generationIds, selectedGenerationId, routingDecision, estimatedCostUSD, actualCostUSD, retryCount, maxRetries, errorMessage, qualityScore, evaluationReasoning, evaluationDimensions, qualityRetryCount, createdAt, startedAt, completedAt

### Provider Metrics
- **Path:** `~/.openflix/metrics.json`
- **Schema:** `[String: ProviderModelMetrics]` keyed by `"provider:model"`
- **Fields:** totalGenerations, succeeded, failed, totalLatencyMs, totalCostUSD, qualityScores (array, max 100), feedbackScores (array, max 100)

### Budget Config
- **Path:** `~/.openflix/budget_config.json`
- **Schema:** `BudgetConfig` -- dailyLimitUSD, perGenerationMaxUSD, monthlyLimitUSD, warningThresholdPercent

### Daily Spend
- **Path:** `~/.openflix/daily_spend.json`
- **Schema:** `DailySpend` -- date (YYYY-MM-DD), totalUSD, generationCount

### Downloads
- **Path:** `~/.openflix/downloads/<generation-id>.mp4`

### Daemon
- **Socket:** `~/.openflix/daemon.sock`
- **PID file:** `~/.openflix/daemon.pid`

### Lock Files
- `~/.openflix/store.lock`
- `~/.openflix/projects/<id>/project.lock`

---

## 6. Provider Integrations

### Summary Table

| Provider | ID | Models | API Base URL | Auth | I2V Support |
|---|---|---|---|---|---|
| fal.ai | `fal` | 8 | `https://queue.fal.run/` | `Key {key}` | Seedance I2V, Kling v2 |
| Replicate | `replicate` | 4 | `https://api.replicate.com/v1/` | `Bearer` | Kling v1.6 Pro |
| Runway | `runway` | 2 | `https://api.runwayml.com/v1/` | `Bearer` | Both models |
| Luma | `luma` | 3 | `https://api.lumalabs.ai/dream-machine/v1/` | `Bearer` | All models |
| Kling | `kling` | 3 | `https://api.klingapi.com/v1/` | `Bearer` | All models |
| MiniMax | `minimax` | 3 | `https://api.minimax.io/v1/` | `Bearer` | S2V-01 |

**Total: 6 providers, 23 models** (the README says 24; actual count from source code is 23: 8 fal + 4 replicate + 2 runway + 3 luma + 3 kling + 3 minimax)

### How They Work

All providers follow the same pattern:
1. **Submit:** POST request with prompt, model, duration, and optional parameters. Returns task ID and optional status URL.
2. **Poll:** GET request to check status. Returns PollStatus enum.
3. **Cost estimation:** `costPerSecondUSD * durationSeconds`

Each provider handles its own response format quirks:
- **fal.ai:** Two-step COMPLETED response (status_url -> response_url -> video URL). Three response shape variants for video URL.
- **Replicate:** Output is string array, first element is video URL.
- **Runway:** Adds `X-Runway-Version` header. Output is string array.
- **Luma:** States named differently (pending/dreaming/completed). Video in `assets.video`.
- **Kling:** Success status is `"succeed"` (not "succeeded"). Wrapped in `{code: 0, data: {...}}`.
- **MiniMax:** 3-step flow (submit -> query status + get file_id -> retrieve download_url). Uses URLComponents for safe query params.

---

## 7. MCP Server

**Protocol:** JSON-RPC 2.0 over stdio (stdin/stdout)

### Lifecycle
- `initialize` -> returns protocolVersion "2024-11-05", capabilities {tools, resources}, serverInfo {name: "openflix", version: "1.0.0"}
- `notifications/initialized` -> no response
- `shutdown` -> empty success
- `ping` -> empty success

### Tools (14)

| Tool | Required Params | Description |
|---|---|---|
| `generate` | prompt, provider, model | Submit + poll + download (blocking) |
| `generate_submit` | prompt, provider, model | Submit only (non-blocking) |
| `generate_poll` | generation_id | Check status, optionally wait |
| `list_generations` | (none) | List with status/provider/search/limit filters |
| `get_generation` | generation_id | Get single generation details |
| `cancel_generation` | generation_id | Cancel active generation |
| `retry_generation` | generation_id | Retry failed generation |
| `list_providers` | (none) | All providers + models |
| `evaluate_quality` | generation_id | Run quality evaluation |
| `submit_feedback` | generation_id, score | Record quality feedback |
| `get_metrics` | (none) | Provider performance metrics |
| `budget_status` | (none) | Budget config + spend |
| `project_run` | project_id | **STUB** -- returns message to use CLI |
| `health_check` | (none) | Provider configuration status |

### Resources (3)

| URI | Description |
|---|---|
| `openflix://providers` | All providers with models and capabilities |
| `openflix://metrics` | Provider performance metrics |
| `openflix://budget` | Budget status and daily spend |

### Error Handling
- `OpenFlixError` instances are returned as content with `isError: true` (MCP-compliant). Structured error info (code, message, details, retryable) is preserved in the content text.
- Other errors are returned as JSON-RPC error responses.
- This design allows agents to programmatically distinguish between tool errors (bad input, provider failure) and protocol errors (parse error, method not found).

---

## 8. Security

### API Key Storage
- **Primary storage:** macOS Keychain via Security framework
- **Service prefix:** `com.openflix.cli.<provider>` (e.g., `com.openflix.cli.fal`)
- **Migration:** Automatic one-time migration from `com.meridian.vortex.*` and `com.openflix.vortex.*` prefixes
- **Key resolution chain:** flag > OPENFLIX_*_KEY env > VORTEX_*_KEY env > OPENFLIX_API_KEY > VORTEX_API_KEY > Keychain
- **Keys are never logged, stored in JSON, or output to stdout/stderr**

### Potential Vulnerabilities and Concerns

1. **Process listing exposure:** API keys passed via `--api-key` flag are visible in `ps aux` output. This is standard CLI behavior but worth noting for security-sensitive environments.

2. **No key encryption at rest beyond Keychain:** JSON files in `~/.openflix/` are plain text. Store.json, metrics.json, and project files are readable by any process running as the user. This is acceptable for a CLI tool but worth noting.

3. **No TLS certificate pinning:** All provider API calls use standard URLSession without certificate pinning. Man-in-the-middle attacks are possible on compromised networks (though all URLs are HTTPS).

4. **No rate limiting on local operations:** There is no protection against a runaway script creating millions of store entries. The store is a single JSON file that is loaded entirely into memory.

5. **Daemon socket permissions:** The Unix domain socket at `~/.openflix/daemon.sock` inherits the umask. Any local process running as the same user can connect and issue commands. There is no authentication on the daemon connection.

6. **Prompt safety is advisory:** The PromptSafetyChecker only blocks locally. Providers apply their own content moderation independently. A crafty prompt could bypass the simple substring matching.

7. **Budget limits are local-only:** The BudgetManager enforces limits in-process. Multiple CLI instances or external API calls bypass the budget entirely.

---

## 9. CLI Commands -- Complete Reference

### Generation Lifecycle
| Command | What It Does | Key Options |
|---|---|---|
| `generate` | Submit generation request | --provider, --model, --wait, --stream, --duration, --image, --param, --retry, --dry-run, --skip-download |
| `status` | Check generation status | --wait, --stream, --cached |
| `list` | List generations | --status, --provider, --limit, --search, --oldest, --pretty |
| `download` | Download video | --output |
| `cancel` | Cancel active generation | (generation ID argument) |
| `delete` | Delete from store | (generation ID argument) |
| `retry` | Retry failed generation | (generation ID argument) |
| `purge` | Bulk delete | --status filter or --all |

### Provider Management
| Command | What It Does |
|---|---|
| `providers` | List providers with config status |
| `models` | List all models (--provider filter) |
| `keys set/delete/list` | Keychain management |
| `health` | Check store, downloads, provider keys |

### Cost and Budget
| Command | What It Does |
|---|---|
| `cost` | Per-provider cost breakdown |
| `budget set` | Set limits (--daily, --per-gen, --monthly) |
| `budget status` | Current config + spend |
| `budget reset` | Zero daily spend |

### Projects (Multi-Shot)
| Command | What It Does |
|---|---|
| `project create` | Create from JSON spec |
| `project run` | Execute DAG (--stream, --strategy, --evaluate) |
| `project status` | Show status (--detail for full tree) |
| `project list` | List all projects |
| `project delete` | Delete project |
| `project shot add/retry/skip/update/remove` | Shot-level management |
| `project export` | Generate ffmpeg concat manifest |

### Intelligence and Quality
| Command | What It Does |
|---|---|
| `evaluate` | Quality eval (--evaluator heuristic/llm-vision) |
| `feedback` | Submit human quality score |
| `metrics` | Provider performance metrics |

### Infrastructure
| Command | What It Does |
|---|---|
| `daemon start/stop/status` | Unix socket daemon |
| `mcp` | MCP server (stdio) |

---

## 10. Architectural Patterns

### Overall Architecture
The codebase follows a **layered architecture** with clear separation:

```
Commands (CLI interface, input validation, output formatting)
    |
    v
Core Services (GenerationEngine, DAGExecutor, QualityGate, BudgetManager)
    |
    v
Providers (VideoProvider protocol, 6 concrete implementations)
    |
    v
Storage (GenerationStore, ProjectStore, ProviderMetricsStore, BudgetManager)
```

### Key Design Patterns

1. **Singleton with Dual Locking:** GenerationStore, ProjectStore, ProviderMetricsStore all use `static let shared` with both `flock()` (cross-process) and `NSLock` (in-process thread safety). This is correct for a CLI tool that may have multiple instances running.

2. **Actor Isolation:** BudgetManager, DAGExecutor, DaemonServer, MCPServer are Swift actors, providing proper concurrency isolation without manual locking.

3. **Protocol Abstraction:** `VideoProvider` protocol abstracts all provider differences. New providers require only implementing 4 methods (submit, poll, estimateCost, cancel).

4. **Type-Erased JSON:** `AnyCodableValue` enum provides type-safe heterogeneous JSON throughout MCP and daemon protocols, avoiding `[String: Any]` dictionary casts.

5. **JSON-First Output:** All stdout output is valid JSON. All stderr output is JSON with `code` field. Streaming events are newline-delimited JSON. This makes the CLI fully machine-parseable.

6. **Error Taxonomy:** Two-layer error system. `OpenFlixError` (12 cases) for internal use with human-readable messages. `ErrorCode` (18 cases) with `retryable` and `httpEquivalent` for machine consumption. `StructuredError` bridges the two.

7. **Advisory Quality Gate:** Quality evaluation never blocks generation. Failed evaluations pass through. Quality retries are bounded. This prevents the quality system from causing data loss.

8. **Graceful Degradation:**
   - Download failures don't mark generations as failed
   - Missing ffprobe awards partial credit
   - Prompt safety warnings don't block (only `blocked` level prevents submission)
   - Budget limits that can't be computed (no cost data) are skipped

9. **Migration Chains:** Both Keychain and data directory support multi-hop migration paths, allowing smooth upgrades from any prior version.

---

## Summary of Issues Found

### Critical: None

### High Priority
1. **README stale references (27 occurrences):** `~/.vortex/` paths, `VORTEX_*` env vars listed as primary, `com.openflix.vortex` keychain prefix, `vortex://` resource URIs, `VortexError`/`VortexCLI.swift` references. The source code is correct; only the README is stale.

### Medium Priority
2. **MCP `project_run` tool is a stub:** Returns a message to use the CLI instead of actually executing the project. The tool definition in MCPToolRegistry accepts `strategy` and `evaluate` parameters that are ignored.
3. **Monthly budget tracking is incomplete:** `loadMonthlySpend()` only returns the current day's total, not an aggregate across the month.
4. **README model count discrepancy:** README says "24 models" but source code shows 23 models across all providers.

### Low Priority
5. **No XCTest unit tests:** All testing is bash integration tests. No mocking of HTTP responses, no testing of edge cases in parsing, no concurrency testing.
6. **ISO8601DateFormatter() instantiated per call:** In `CLIGeneration.jsonRepresentation`, a new formatter is created for each date field per generation. Negligible for typical usage but could matter in bulk operations.
7. **Daemon socket has no authentication:** Any local process running as the same user can connect and issue commands.
8. **Store loaded entirely into memory:** GenerationStore loads all records on every operation. This works fine for typical CLI usage (hundreds/thousands of records) but would need pagination for very large stores.
9. **Prompt safety substring matching is naive:** "how to hack a pinata" would be blocked. Acceptable for a local heuristic but could cause false positives.
10. **Test isolation:** Tests modify `~/.openflix/` state, potentially interfering with real user data. Should use a temp directory.
