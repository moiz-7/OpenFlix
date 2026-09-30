import Foundation
import OpenFlixKit

/// What every CLI action is: its schema, its effect, and what it tells a
/// client. `MCPToolRegistry.allTools` and `openflix action list` are both
/// derived from this list, so neither can describe an action differently.
///
/// **Effects, not hand-set hints.** Each entry declares what it does to the
/// world (`ActionEffect`); the MCP annotations follow from that. MCP has no
/// "costs money" hint and a client uses `destructiveHint` to decide whether to
/// ask the human first, so every `.spend` action is destructive by
/// construction — it can no longer be annotated otherwise by mistake.
///
/// **Bounds are part of the schema.** Arguments are validated against these
/// schemas before any action runs (`CLIActions.run`). Unknown arguments are
/// refused: on a paid call, a misspelled `duration_seconds` silently ignored
/// is a default duration silently billed.
enum CLIActionCatalog {

    static func descriptor(named name: String) -> ActionDescriptor? {
        all.first { $0.name == name }
    }

    static var manifest: JSONValue {
        ActionManifest.document(host: "openflix-cli", version: OpenFlixVersion.current, actions: all)
    }

    /// Ids are path components in `~/.openflix`; the handlers also check the
    /// grammar (`MCPIdentifier`), this bounds the length up front.
    private static func id(_ description: String) -> JSONValue {
        JSONSchema.string(description, maxLength: MCPIdentifier.maxLength)
    }

    private static let statuses = ["queued", "submitted", "processing", "succeeded", "failed", "cancelled"]

    static let all: [ActionDescriptor] = [
        ActionDescriptor(
            name: "generate",
            title: "Generate a video (spends money)",
            description: "Submit a video generation request, poll until complete, and download the result. Returns the full generation object. SPENDS THE USER'S OWN PROVIDER CREDIT and cannot be undone; the charge is subject to the local budget pre-flight and may be refused. Either pass provider+model, or route=\"smart\" to auto-select by community preference win rate.",
            effect: .spend, openWorld: true,
            inputSchema: JSONSchema.object(
                required: ["prompt"],
                properties: [
                    "prompt": JSONSchema.string("Text prompt describing the video to generate"),
                    "provider": JSONSchema.string("Provider ID (fal, replicate, runway, luma, kling, minimax, local). Required unless route=\"smart\""),
                    "model": JSONSchema.string("Model ID (provider-specific). Required unless route=\"smart\""),
                    "route": JSONSchema.enumeration("Set to \"smart\" to auto-select provider+model from community preference data", ["smart"]),
                    "category": JSONSchema.string("Category hint for smart routing (e.g. cinematic, anime, product)"),
                    "negative_prompt": JSONSchema.string("Negative prompt (what to avoid)"),
                    "width": JSONSchema.integer("Video width in pixels", minimum: 1),
                    "height": JSONSchema.integer("Video height in pixels", minimum: 1),
                    "duration_seconds": JSONSchema.number("Video duration in seconds"),
                    "aspect_ratio": JSONSchema.string("Aspect ratio (e.g. 16:9, 9:16)"),
                    "timeout": JSONSchema.number("Timeout in seconds (default 300)", minimum: 0),
                    "max_retries": JSONSchema.integer("Max retry attempts on failure (default 0). Each retry is billed.", minimum: 0, maximum: 10),
                ]
            ),
            outputSchema: generationSchema,
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "generate_submit",
            title: "Submit a generation without waiting (spends money)",
            description: "Submit a video generation request without waiting. Returns a generation ID for later polling. SPENDS THE USER'S OWN PROVIDER CREDIT and cannot be undone. Either pass provider+model, or route=\"smart\" to auto-select by community preference win rate.",
            effect: .spend, openWorld: true,
            inputSchema: JSONSchema.object(
                required: ["prompt"],
                properties: [
                    "prompt": JSONSchema.string("Text prompt describing the video"),
                    "provider": JSONSchema.string("Provider ID. Required unless route=\"smart\""),
                    "model": JSONSchema.string("Model ID. Required unless route=\"smart\""),
                    "route": JSONSchema.enumeration("Set to \"smart\" to auto-select provider+model from community preference data", ["smart"]),
                    "category": JSONSchema.string("Category hint for smart routing"),
                    "negative_prompt": JSONSchema.string("Negative prompt"),
                    "width": JSONSchema.integer("Video width in pixels", minimum: 1),
                    "height": JSONSchema.integer("Video height in pixels", minimum: 1),
                    "duration_seconds": JSONSchema.number("Video duration in seconds"),
                    "aspect_ratio": JSONSchema.string("Aspect ratio"),
                ]
            ),
            outputSchema: generationSchema,
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "generate_poll",
            title: "Poll a generation",
            description: "Poll the status of an existing generation. Returns current status and progress. Does not start new work and adds no new charge, but it does contact the provider and records the final cost of a generation that has just finished.",
            // Not read-only: a poll that finds a terminal state writes the
            // record and the spend ledger. Repeating it changes nothing further.
            effect: .refresh, openWorld: true, idempotent: true,
            inputSchema: JSONSchema.object(
                required: ["generation_id"],
                properties: [
                    "generation_id": id("The generation ID to poll"),
                    "wait": JSONSchema.boolean("If true, block until generation completes"),
                    "timeout": JSONSchema.number("Timeout in seconds when waiting", minimum: 0),
                ]
            ),
            outputSchema: generationSchema,
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "list_generations",
            title: "List generations",
            description: "List generations with optional filtering by status, provider, or search term. Reads this machine's local generation store; makes no network call.",
            effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(
                properties: [
                    "status": JSONSchema.enumeration("Filter by status (queued, submitted, processing, succeeded, failed, cancelled)", statuses),
                    "provider": JSONSchema.string("Filter by provider ID"),
                    // A negative limit used to reach `Array.prefix(_:)`, which
                    // traps — one bad argument took the whole server down.
                    "limit": JSONSchema.integer("Max number of results (default 20)", minimum: 0, maximum: 1000),
                    "search": JSONSchema.string("Search term to filter by prompt text"),
                ]
            ),
            outputSchema: JSONSchema.result(
                required: ["generations", "total", "returned"],
                properties: [
                    "generations": JSONSchema.array("Matching generations", items: generationSchema),
                    "total": JSONSchema.integer("Number of generations matching the filters"),
                    "returned": JSONSchema.integer("Number actually returned after the limit"),
                ]
            ),
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "get_generation",
            title: "Get one generation",
            description: "Get detailed information about a single generation from this machine's local store.",
            effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(
                required: ["generation_id"],
                properties: ["generation_id": id("The generation ID")]
            ),
            outputSchema: generationSchema,
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "cancel_generation",
            title: "Cancel a generation",
            description: "Cancel an active (queued/submitted/processing) generation. Asks the provider to stop, then marks the local record cancelled. Work already billed is not refunded and the generation cannot be un-cancelled.",
            // Irreversible, and a second call fails rather than being a no-op,
            // so it is not idempotent.
            effect: .destructive, openWorld: true,
            inputSchema: JSONSchema.object(
                required: ["generation_id"],
                properties: ["generation_id": id("The generation ID to cancel")]
            ),
            outputSchema: JSONSchema.result(
                required: ["status", "generation_id", "remote_cancelled"],
                properties: [
                    "status": JSONSchema.string("Always \"cancelled\""),
                    "generation_id": JSONSchema.string("The generation that was cancelled"),
                    "remote_cancelled": JSONSchema.boolean("True when the provider confirmed the cancel; false means local-only"),
                    "note": JSONSchema.string("Why the remote cancel did not happen, when it did not"),
                ]
            )
        ),
        ActionDescriptor(
            name: "retry_generation",
            title: "Retry a failed generation (spends money)",
            description: "Retry a failed generation with the same parameters, including its reference image and extra params. This submits a NEW generation and SPENDS THE USER'S OWN PROVIDER CREDIT again.",
            effect: .spend, openWorld: true,
            inputSchema: JSONSchema.object(
                required: ["generation_id"],
                properties: ["generation_id": id("The failed generation ID to retry")]
            ),
            outputSchema: generationSchema,
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "list_providers",
            title: "List providers and models",
            description: "List available video generation providers and their models, including capabilities and pricing. Reads a built-in table; makes no network call and spends nothing.",
            effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(properties: [:]),
            outputSchema: JSONSchema.result(
                required: ["providers", "count"],
                properties: [
                    "providers": JSONSchema.array("Known provider/model pairs", items: .object(["type": .string("object")])),
                    "count": JSONSchema.integer("How many models are listed"),
                ]
            )
        ),
        ActionDescriptor(
            name: "evaluate_quality",
            title: "Evaluate a finished video",
            description: "Run quality evaluation on a completed generation's downloaded video. The default \"heuristic\" evaluator is local and free; \"llm-vision\" calls a remote model and spends money. Either way the score is written to this machine's provider metrics.",
            // Annotated for its worst case, like project_run: a client reads
            // annotations before it knows which evaluator will be asked for,
            // and llm-vision bills the user's model account.
            effect: .spend, openWorld: true,
            inputSchema: JSONSchema.object(
                required: ["generation_id"],
                properties: [
                    "generation_id": id("The generation ID to evaluate"),
                    "evaluator": JSONSchema.enumeration("Evaluator type: heuristic (default, local, free) or llm-vision (remote, paid)", ["heuristic", "llm-vision"]),
                    "threshold": JSONSchema.number("Quality threshold (0-100)", minimum: 0, maximum: 100),
                ]
            ),
            outputSchema: JSONSchema.result(
                required: ["generation_id", "score", "evaluator", "passed"],
                properties: [
                    "generation_id": JSONSchema.string("The generation that was evaluated"),
                    "score": JSONSchema.number("Quality score, 0-100"),
                    "evaluator": JSONSchema.string("Which evaluator produced the score"),
                    "passed": JSONSchema.boolean("Whether the score met the threshold"),
                    "reasoning": JSONSchema.string("Evaluator explanation, when it produced one"),
                ]
            ),
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "submit_feedback",
            title: "Score a generation (local only)",
            description: "Submit quality feedback (0-100 score) for a generation. Local-only: feeds this machine's provider metrics, never leaves the machine.",
            // openWorld: false is the load-bearing claim here — this is the tool
            // whose whole promise is that the score never leaves the machine.
            effect: .localWrite, openWorld: false,
            inputSchema: JSONSchema.object(
                required: ["generation_id", "score"],
                properties: [
                    "generation_id": id("The generation ID"),
                    "score": JSONSchema.number("Quality score (0-100)", minimum: 0, maximum: 100),
                    "reason": JSONSchema.string("Optional reason for the score"),
                ]
            ),
            outputSchema: JSONSchema.result(
                required: ["status", "generation_id", "provider", "model", "score"],
                properties: [
                    "status": JSONSchema.string("Always \"recorded\""),
                    "generation_id": JSONSchema.string("The generation the score was recorded against"),
                    "provider": JSONSchema.string("Provider the score was attributed to"),
                    "model": JSONSchema.string("Model the score was attributed to"),
                    "score": JSONSchema.number("The score recorded"),
                ]
            )
        ),
        ActionDescriptor(
            name: "submit_vote",
            title: "Share a preference vote with the community",
            description: "Record the USER's pairwise preference (winner beat loser) and share it with the community registry — the same data smart routing reads back. The pool is human preference only: vote only after the user has said which one they prefer, with origin \"owner_relayed\". Your own judgment (origin \"agent_judgment\") is refused. Sends only provider/model names and a category, never the prompt or the video; deduplicated server-side, safe to retry.",
            // Leaves the machine, and the registry dedupes — "safe to retry" in
            // the description and `idempotent` are the same claim.
            effect: .share, openWorld: true, idempotent: true,
            inputSchema: JSONSchema.object(
                required: ["winner_generation_id", "loser_generation_id", "origin"],
                properties: [
                    "winner_generation_id": id("Generation ID that was preferred"),
                    "loser_generation_id": id("Generation ID it beat (must be a different provider/model)"),
                    "origin": JSONSchema.enumeration(
                        "Who chose the winner: \"owner_relayed\" if the user did, \"agent_judgment\" if you did (refused — never shared)",
                        VoteOrigin.allCases.map(\.rawValue)),
                    "category": JSONSchema.string("Category hint (e.g. cinematic, anime, product)"),
                ]
            ),
            outputSchema: JSONSchema.result(
                required: ["status", "origin", "winner_generation_id", "loser_generation_id", "accepted"],
                properties: [
                    "status": JSONSchema.string("Always \"shared\""),
                    "origin": JSONSchema.string("Always \"owner_relayed\" — the only origin that is shared"),
                    "winner_generation_id": JSONSchema.string("The winning generation"),
                    "loser_generation_id": JSONSchema.string("The losing generation"),
                    "accepted": JSONSchema.integer("How many votes the registry accepted"),
                    "duplicates_ignored": JSONSchema.integer("How many were dropped as duplicates"),
                ]
            )
        ),
        ActionDescriptor(
            name: "get_metrics",
            title: "Provider metrics",
            description: "Get this machine's provider performance metrics (quality, latency, cost, success rate). Local read.",
            effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(
                properties: [
                    "provider": JSONSchema.string("Filter by provider ID"),
                    "sort": JSONSchema.enumeration("Sort by: quality, latency, cost, success_rate (default: quality)",
                                                   ["quality", "latency", "cost", "success_rate"]),
                ]
            ),
            outputSchema: JSONSchema.result(
                required: ["metrics", "count"],
                properties: [
                    "metrics": JSONSchema.array("Per provider/model metrics", items: .object(["type": .string("object")])),
                    "count": JSONSchema.integer("How many rows were returned"),
                ]
            )
        ),
        ActionDescriptor(
            name: "budget_status",
            title: "Budget status",
            description: "Get current budget status including daily spend, limits, and remaining budget. Local read — this is the gate every generation is checked against, so call it before spending.",
            effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(properties: [:])
        ),
        ActionDescriptor(
            name: "project_run",
            title: "Run a multi-shot project (spends money per shot)",
            description: """
                Execute a multi-shot project's DAG in dependency order. Every shot goes through the same budget pre-flight, \
                prompt-safety, reference-image and hook gates as `openflix project run`. SPENDS THE USER'S OWN PROVIDER \
                CREDIT once per shot (more for fanout/scatter shots) and cannot be undone.

                TWO STEPS, BY DESIGN. Called with only `project_id` this SPENDS NOTHING: it returns a plan — the \
                provider and model each shot would use, the per-shot and total cost estimate, which shots would be \
                refused locally and why, and the current budget. To actually execute, call again with `confirm: true` \
                AND `max_cost_usd` set to a ceiling you are willing to spend. The run is refused before anything is \
                submitted if the estimate exceeds that ceiling, and halted mid-run if billed spend reaches it. Show the \
                plan to the user and get their agreement before executing.

                Partial completion is the normal outcome for a DAG. The result always reports what ran, what did not, \
                what it cost, the run journal id, and the exact call that resumes it.
                """,
            // Pessimistic on purpose, and NOT softened by the safe default.
            // A client reads annotations from `tools/list`, before it knows
            // what arguments will be passed, so the only honest annotation is
            // the tool's worst case: this one can charge a provider account
            // once per shot, irreversibly.
            effect: .spend, openWorld: true,
            inputSchema: JSONSchema.object(
                required: ["project_id"],
                properties: [
                    "project_id": id("The project ID to plan or run"),
                    "confirm": JSONSchema.boolean("Set to true to ACTUALLY EXECUTE and spend money. Omitted or false returns a cost plan and spends nothing. Requires max_cost_usd."),
                    "max_cost_usd": JSONSchema.number("Hard ceiling in USD for this run. Required when confirm is true. The run is refused up front if the estimate exceeds it, and stops dispatching once billed spend reaches it. It can only make the run stricter — it never raises the project's own budget or the daily/monthly limits."),
                    "resume": JSONSchema.boolean("Reset shots a previous run left failed, in-flight, or blocked by an upstream failure back to pending, so this run retries them. Applies to the plan too."),
                    "concurrency": JSONSchema.integer("Max shots dispatched in parallel (default: the project's own setting)", minimum: 1, maximum: 16),
                    "evaluate": JSONSchema.boolean("Run the quality evaluator after each shot. The heuristic evaluator is local and free; llm-vision spends money."),
                    "quality_threshold": JSONSchema.number("Quality threshold 0-100 (implies evaluate)", minimum: 0, maximum: 100),
                    "timeout_seconds": JSONSchema.number("Stop dispatching new shots after this many seconds and return what completed (default 900, max 3600). Shots already submitted are still billed."),
                ]
            ),
            outputSchema: JSONSchema.result(
                required: ["executed", "mode", "project_id"],
                properties: [
                    "executed": JSONSchema.boolean("False for a plan — nothing was submitted and nothing was billed. True only when shots were actually dispatched."),
                    "mode": JSONSchema.string("\"plan\" or \"execute\""),
                    "project_id": JSONSchema.string("The project"),
                    "name": JSONSchema.string("Project name"),
                    "status": JSONSchema.string("Project status after the run: succeeded, partial_failure, failed, paused or cancelled"),
                    "run_id": JSONSchema.string("Run journal id — ~/.openflix/runs/<run_id>.json, readable after the call and after a crash"),
                    "timed_out": JSONSchema.boolean("True when timeout_seconds stopped the run; the project is left paused and resumable"),
                    "waves": JSONSchema.integer("Number of dependency levels in the graph"),
                    "shots_to_run": JSONSchema.integer("Shots this run would attempt"),
                    "shots_blocked": JSONSchema.integer("Shots that would be refused locally, before any provider call"),
                    "shots_already_terminal": JSONSchema.integer("Shots this run will not touch"),
                    "shots_succeeded": JSONSchema.integer("Shots that succeeded"),
                    "shots_failed": JSONSchema.integer("Shots that failed"),
                    "shots_skipped": JSONSchema.integer("Shots skipped because an upstream shot failed"),
                    "shots_pending": JSONSchema.integer("Shots never reached"),
                    "estimated_cost_usd": JSONSchema.number("Total pre-flight estimate in USD"),
                    "estimated_cost_is_upper_bound": JSONSchema.boolean("Always true — see caveats"),
                    "actual_cost_usd": JSONSchema.number("Billed cost in USD, after execution"),
                    "cost_ceiling_usd": JSONSchema.number("The ceiling this run was held to"),
                    "shots": JSONSchema.array("Per-shot plan or outcome", items: .object(["type": .string("object")])),
                    "budget": JSONSchema.freeformObject("Current budget status, the same object budget_status returns"),
                    "caveats": JSONSchema.array("What the estimate does not capture", items: .object(["type": .string("string")])),
                    "next_step": JSONSchema.string("The exact call to make next"),
                ]
            ),
            returnsUntrustedText: true
        ),
        ActionDescriptor(
            name: "health_check",
            title: "Which providers are configured",
            description: "Report which providers have a usable API key on this machine. Reads the local Keychain only — it does not contact any provider, so a provider listed as configured may still be down.",
            effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(properties: [:]),
            outputSchema: JSONSchema.result(
                required: ["providers", "configured_count", "total_count"],
                properties: [
                    "providers": JSONSchema.array("Every known provider with whether a key is present", items: .object(["type": .string("object")])),
                    "configured_count": JSONSchema.integer("How many have a key"),
                    "total_count": JSONSchema.integer("How many providers exist"),
                ]
            )
        ),
    ]

    /// One shape for every action that returns a generation record. The five
    /// keys marked required are the five `CLIGeneration.jsonRepresentation`
    /// always writes; everything else is conditional on the record.
    static let generationSchema: JSONValue = JSONSchema.result(
        required: ["id", "status", "provider", "model", "prompt"],
        properties: [
            "id": JSONSchema.string("Generation ID"),
            "status": JSONSchema.string("queued, submitted, processing, succeeded, failed or cancelled"),
            "provider": JSONSchema.string("Provider that ran it"),
            "model": JSONSchema.string("Model that ran it"),
            "prompt": JSONSchema.string("The prompt that was submitted"),
            "retry_count": JSONSchema.integer("How many times it has been retried"),
            "created_at": JSONSchema.string("ISO-8601 creation time"),
            "local_path": JSONSchema.string("Path to the downloaded video, once downloaded"),
            "remote_video_url": JSONSchema.string("Provider-hosted video URL, once available"),
            "estimated_cost_usd": JSONSchema.number("Pre-flight cost estimate in USD"),
            "actual_cost_usd": JSONSchema.number("Billed cost in USD, once known"),
            "error_message": JSONSchema.string("Why it failed, when it failed"),
        ]
    )
}

// MARK: - Bridging to the MCP wire types

extension JSONValue {
    init(_ value: AnyCodableValue) {
        switch value {
        case .string(let v):     self = .string(v)
        case .int(let v):        self = .int(v)
        case .double(let v):     self = .double(v)
        case .bool(let v):       self = .bool(v)
        case .dictionary(let v): self = .object(v.mapValues { JSONValue($0) })
        case .array(let v):      self = .array(v.map { JSONValue($0) })
        case .null:              self = .null
        }
    }
}

extension AnyCodableValue {
    init(_ value: JSONValue) {
        switch value {
        case .string(let v): self = .string(v)
        case .int(let v):    self = .int(v)
        case .double(let v): self = .double(v)
        case .bool(let v):   self = .bool(v)
        case .object(let v): self = .dictionary(v.mapValues { AnyCodableValue($0) })
        case .array(let v):  self = .array(v.map { AnyCodableValue($0) })
        case .null:          self = .null
        }
    }
}

extension MCPToolDefinition {
    /// The MCP view of an action. The annotations are derived from its effect,
    /// never written by hand.
    init(_ descriptor: ActionDescriptor) {
        let hints = descriptor.annotations
        self.init(
            name: descriptor.name,
            title: descriptor.title,
            description: descriptor.description,
            inputSchema: AnyCodableValue(descriptor.inputSchema).objectValue ?? [:],
            annotations: MCPToolAnnotations(readOnly: hints.readOnlyHint,
                                            destructive: hints.destructiveHint ?? true,
                                            idempotent: hints.idempotentHint ?? false,
                                            openWorld: hints.openWorldHint),
            outputSchema: descriptor.outputSchema.flatMap { AnyCodableValue($0).objectValue })
    }
}
