import Foundation
import OpenFlixKit

/// Every action the CLI offers, behind one door.
///
/// `run` is the only way in. The MCP server calls it, `openflix action run`
/// calls it, and a network bridge will call it: each surface translates its
/// own wire format into a name plus JSON arguments and gets back the same
/// result, after the same argument validation. Before this existed, each
/// surface parsed arguments its own way, which is how a flag checked at one
/// door went unchecked at another.
///
/// What each action *is* — its schema, its effect, what it tells a client —
/// lives in `CLIActionCatalog`. What it *does* lives below, one `tool…`
/// function per action. The spending gates are unchanged: everything that
/// creates video still reaches a provider only through
/// `GenerationEngine.submit`.
enum CLIActions {

    typealias Handler = @Sendable ([String: AnyCodableValue], ActionContext) async throws -> [String: Any]

    /// Runs one action. Throws `ActionInputError` when the arguments do not
    /// match the action's schema (nothing has run), and otherwise whatever the
    /// action throws (`OpenFlixError`, `MCPToolRefusal`).
    static func run(_ name: String, arguments: [String: AnyCodableValue],
                    context: ActionContext) async throws -> [String: Any] {
        guard let descriptor = CLIActionCatalog.descriptor(named: name),
              let handler = handlers[name] else {
            throw OpenFlixError.invalidResponse("Unknown tool: \(name)")
        }
        try ActionValidator.validate(JSONValue(.dictionary(arguments)), against: descriptor.inputSchema)
        return try await handler(arguments, context)
    }

    /// One handler per catalog entry. `CLIActionCatalogTests` asserts the two
    /// lists name exactly the same actions.
    static let handlers: [String: Handler] = [
        "generate":          { args, _ in try await toolGenerate(args) },
        "generate_submit":   { args, _ in try await toolGenerateSubmit(args) },
        "generate_poll":     { args, _ in try await toolGeneratePoll(args) },
        "list_generations":  { args, _ in toolListGenerations(args) },
        "get_generation":    { args, _ in try toolGetGeneration(args) },
        "cancel_generation": { args, _ in try await toolCancelGeneration(args) },
        "retry_generation":  { args, _ in try await toolRetryGeneration(args) },
        "list_providers":    { _, _ in toolListProviders() },
        "evaluate_quality":  { args, _ in try await toolEvaluateQuality(args) },
        "submit_feedback":   { args, _ in try toolSubmitFeedback(args) },
        "submit_vote":       { args, _ in try await toolSubmitVote(args) },
        "get_metrics":       { args, _ in toolGetMetrics(args) },
        "budget_status":     { _, _ in await toolBudgetStatus() },
        "project_run":       { args, context in try await toolProjectRun(args, context: context) },
        "health_check":      { _, _ in try await toolHealthCheck() },
    ]

    /// Any error an action can throw, in the envelope's terms.
    static func failure(from error: Error) -> ActionFailure {
        switch error {
        case let failure as ActionFailure:
            return failure
        case let input as ActionInputError:
            return ActionFailure(input)
        case let refusal as MCPToolRefusal:
            // A refusal is a decision about this call — the project, the
            // ceiling, the plan — made before anything was spent.
            return ActionFailure(code: refusal.code, errorClass: .policy, message: refusal.message,
                                 retryable: false, details: JSONValue(any: refusal.details))
        case let error as OpenFlixError:
            let structured = StructuredError.from(error)
            return ActionFailure(code: structured.code.rawValue,
                                 errorClass: errorClass(for: structured.code),
                                 message: structured.message,
                                 retryable: structured.retryable,
                                 details: structured.details.map { JSONValue(.dictionary($0)) })
        case let network as URLError:
            // A provider (or a local server like ComfyUI) that could not be
            // reached is the world failing, not this code — and it is worth
            // retrying once it is back.
            return ActionFailure(code: "NETWORK_ERROR", errorClass: .upstream,
                                 message: network.localizedDescription, retryable: true,
                                 details: .object(["url_error_code": .int(network.code.rawValue)]))
        default:
            return ActionFailure(code: ErrorCode.internalError.rawValue, errorClass: .internal,
                                 message: error.localizedDescription)
        }
    }

    static func errorClass(for code: ErrorCode) -> ActionErrorClass {
        switch code {
        case .inputInvalid, .inputTooLarge, .configInvalid: return .invalidInput
        case .generationNotFound: return .notFound
        case .promptUnsafe, .budgetExceeded, .quotaExceeded, .hookVeto: return .policy
        case .authMissing, .authInvalid, .authExpired, .diskFull: return .unavailable
        case .providerRateLimited: return .rateLimited
        case .providerUnavailable, .providerTimeout, .providerServerError,
             .generationFailed, .downloadFailed, .qualityBelowThreshold: return .upstream
        case .notComplete: return .conflict
        case .internalError: return .internal
        }
    }

    /// One line describing a shot's progress. Shared by the MCP progress
    /// notification and any other surface that shows progress.
    static func progressMessage(_ p: DAGProgress) -> String {
        var message = "\(p.shotName): \(p.status)"
        if let error = p.errorMessage, !error.isEmpty { message += " — \(error)" }
        message += String(format: " · %d/%d shots · $%.2f billed so far",
                          p.completed, p.total, p.costSoFarUSD.isFinite ? p.costSoFarUSD : 0)
        return message
    }

    // MARK: - Tool Implementations

    /// Resolve provider/model for the generate tools: explicit pair, or
    /// route == "smart" → PreferenceRouter (community win rates). Returns the
    /// routing JSON for the response when smart routing decided.
    static func resolveProviderModel(_ args: [String: AnyCodableValue]) async throws
        -> (provider: String, model: String, routing: [String: Any]?) {
        if let provider = optionalString(args, "provider"),
           let model = optionalString(args, "model") {
            return (provider, model, nil)
        }
        guard optionalString(args, "route") == "smart" else {
            throw OpenFlixError.invalidResponse("provider and model are required unless route == \"smart\"")
        }
        let decision = try await PreferenceRouter.decide(
            category: optionalString(args, "category"),
            needsImageToVideo: false,
            duration: optionalDouble(args, "duration_seconds")
        )
        return (decision.provider, decision.model, decision.json)
    }

    static func toolGenerate(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let prompt = try requireString(args, "prompt")
        let (provider, model, routing) = try await resolveProviderModel(args)

        let options = GenerationEngine.Options(
            pollInterval: 3,
            timeout: optionalDouble(args, "timeout") ?? 300,
            outputURL: nil,
            stream: false,
            skipDownload: false,
            maxRetries: optionalInt(args, "max_retries") ?? 0
        )

        let gen = try await GenerationEngine.submitAndWait(
            prompt: prompt,
            negativePrompt: optionalString(args, "negative_prompt"),
            provider: provider,
            model: model,
            durationSeconds: optionalDouble(args, "duration_seconds"),
            aspectRatio: optionalString(args, "aspect_ratio"),
            width: optionalInt(args, "width"),
            height: optionalInt(args, "height"),
            options: options
        )
        var result = gen.jsonRepresentation
        if let routing { result["routing"] = routing }
        return result
    }

    static func toolGenerateSubmit(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let prompt = try requireString(args, "prompt")
        let (provider, model, routing) = try await resolveProviderModel(args)

        let gen = try await GenerationEngine.submit(
            prompt: prompt,
            negativePrompt: optionalString(args, "negative_prompt"),
            provider: provider,
            model: model,
            durationSeconds: optionalDouble(args, "duration_seconds"),
            aspectRatio: optionalString(args, "aspect_ratio"),
            width: optionalInt(args, "width"),
            height: optionalInt(args, "height")
        )
        var result = gen.jsonRepresentation
        if let routing { result["routing"] = routing }
        return result
    }

    static func toolGeneratePoll(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard var gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }

        let shouldWait = optionalBool(args, "wait") ?? false
        if shouldWait && !gen.status.isTerminal {
            let timeout = optionalDouble(args, "timeout") ?? 300
            let options = GenerationEngine.Options(pollInterval: 3, timeout: timeout)
            gen = try await GenerationEngine.waitForCompletion(gen: &gen, apiKey: nil, options: options)
        }
        return gen.jsonRepresentation
    }

    static func toolListGenerations(_ args: [String: AnyCodableValue]) -> [String: Any] {
        var gens = GenerationStore.shared.all()

        if let status = optionalString(args, "status") {
            gens = gens.filter { $0.status.rawValue == status }
        }
        if let provider = optionalString(args, "provider") {
            gens = gens.filter { $0.provider == provider }
        }
        if let search = optionalString(args, "search") {
            let lower = search.lowercased()
            gens = gens.filter { $0.prompt.lowercased().contains(lower) }
        }

        let limit = optionalInt(args, "limit") ?? 20
        let results = Array(gens.prefix(limit))

        return [
            "generations": results.map { $0.jsonRepresentation },
            "total": gens.count,
            "returned": results.count,
        ]
    }

    static func toolGetGeneration(_ args: [String: AnyCodableValue]) throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        return gen.jsonRepresentation
    }

    static func toolCancelGeneration(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard !gen.status.isTerminal else {
            throw OpenFlixError.invalidResponse("Generation is already in terminal state: \(gen.status.rawValue)")
        }
        // Route through the real provider cancel path (same as `openflix cancel`),
        // preserving the local state flip as fallback when the provider has no
        // cancel API (cancelNotSupported) or the call fails.
        var remoteCancelled = false
        var note: String?
        switch await CancelService.attemptRemoteCancel(gen: gen, apiKey: nil) {
        case .cancelled:
            remoteCancelled = true
        case .notSupported(let error):
            note = "\(error.errorDescription ?? "cancel not supported") — cancelled locally only"
        case .bestEffortFailed:
            note = "provider cancel failed — cancelled locally only"
        case .noRemoteTask:
            note = "no remote task — cancelled locally only"
        }
        GenerationStore.shared.update(id: genId) {
            $0.status = .cancelled
            $0.completedAt = Date()
        }
        var result: [String: Any] = [
            "status": "cancelled",
            "generation_id": genId,
            "remote_cancelled": remoteCancelled,
        ]
        if let note { result["note"] = note }
        return result
    }

    static func toolRetryGeneration(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard gen.status == .failed else {
            throw OpenFlixError.invalidResponse("Can only retry failed generations (current: \(gen.status.rawValue))")
        }

        let newGen = try await GenerationEngine.submit(
            prompt: gen.prompt,
            negativePrompt: gen.negativePrompt,
            provider: gen.provider,
            model: gen.model,
            durationSeconds: gen.durationSeconds,
            aspectRatio: gen.aspectRatio,
            width: gen.widthPx,
            height: gen.heightPx,
            // Reproduce the original inputs — dropping these silently resubmits a
            // different, still-billed generation (see RetryCommand).
            referenceImageURL: gen.referenceImageURL.flatMap { URL(string: $0) },
            extraParams: gen.extraParams?.mapValues { $0.toAny() } ?? [:]
        )
        return newGen.jsonRepresentation
    }

    static func toolListProviders() -> [String: Any] {
        let models = ProviderRegistry.shared.allModels
        return [
            "providers": models.map { $0.jsonRepresentation },
            "count": models.count,
        ]
    }

    static func toolEvaluateQuality(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard gen.status == .succeeded else {
            throw OpenFlixError.invalidResponse("Can only evaluate succeeded generations")
        }
        guard let localPath = gen.localPath else {
            throw OpenFlixError.invalidResponse("No local video file for evaluation")
        }

        let evaluatorStr = optionalString(args, "evaluator") ?? "heuristic"
        let threshold = optionalDouble(args, "threshold") ?? 0
        let evaluatorType: QualityConfig.EvaluatorType = evaluatorStr == "llm-vision" ? .llmVision : .heuristic

        let config = QualityConfig(
            enabled: true,
            evaluator: evaluatorType,
            threshold: threshold
        )

        let result = try await QualityGate.evaluate(
            generation: gen,
            videoPath: localPath,
            shot: nil,
            config: config
        )

        return [
            "generation_id": genId,
            "score": result.score,
            "evaluator": result.evaluator,
            "reasoning": result.reasoning as Any,
            "dimensions": result.dimensions as Any,
            "passed": result.score >= threshold,
        ]
    }

    static func toolSubmitFeedback(_ args: [String: AnyCodableValue]) throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        let score = try requireDouble(args, "score")
        _ = optionalString(args, "reason") // accepted but not stored by CLI metrics

        guard score >= 0 && score <= 100 else {
            throw OpenFlixError.invalidResponse("Score must be between 0 and 100")
        }

        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }

        ProviderMetricsStore.shared.recordFeedback(
            provider: gen.provider,
            model: gen.model,
            score: score
        )

        return [
            "status": "recorded",
            "generation_id": genId,
            "provider": gen.provider,
            "model": gen.model,
            "score": score,
        ]
    }

    static func toolSubmitVote(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let origin = try VoteOrigin.requireShareable(optionalString(args, "origin"))
        let winnerId = try requireIdentifier(args, "winner_generation_id")
        let loserId = try requireIdentifier(args, "loser_generation_id")

        let result = try await PreferenceVoteClient.vote(
            winnerId: winnerId, loserId: loserId,
            category: optionalString(args, "category"),
            context: origin.registryContext
        )

        return [
            "status": "shared",
            "origin": origin.rawValue,
            "winner_generation_id": winnerId,
            "loser_generation_id": loserId,
            "accepted": result.accepted,
            "duplicates_ignored": result.duplicatesIgnored,
        ]
    }

    static func toolGetMetrics(_ args: [String: AnyCodableValue]) -> [String: Any] {
        var metrics = ProviderMetricsStore.shared.allMetrics()
        if let provider = optionalString(args, "provider") {
            metrics = metrics.filter { $0.provider == provider }
        }

        let sortKey = optionalString(args, "sort") ?? "quality"
        switch sortKey {
        case "latency":
            metrics.sort { $0.avgLatencyMs < $1.avgLatencyMs }
        case "cost":
            metrics.sort { $0.totalCostUSD < $1.totalCostUSD }
        case "success_rate":
            metrics.sort { $0.successRate > $1.successRate }
        default: // quality
            metrics.sort { $0.avgQuality > $1.avgQuality }
        }

        return [
            "metrics": metrics.map { $0.jsonRepresentation },
            "count": metrics.count,
        ]
    }

    static func toolBudgetStatus() async -> [String: Any] {
        return await BudgetManager.shared.statusSummary()
    }

    // MARK: - project_run
    //
    // The most consequential tool on either server: it spends real money, per
    // shot, across a whole graph, on the user's own provider credit.
    //
    // Three properties hold it together, and none of them is optional:
    //
    //  1. **It cannot spend by accident.** `confirm: true` AND a numeric
    //     `max_cost_usd` are both required. A call with only `project_id`
    //     returns a plan and submits nothing, so the cheapest thing an agent
    //     can do is find out the price.
    //  2. **The ceiling is enforced twice.** Up front against the plan's
    //     estimate, and again inside `DAGExecutor` as a per-shot budget gate —
    //     because an estimate is a guess and the provider's invoice is not.
    //     It can only ever narrow: `BudgetManager`'s daily/monthly/
    //     per-generation limits and the project's own `costBudgetUSD` still
    //     apply underneath.
    //  3. **Nothing here reaches a provider.** Execution is `DAGExecutor`,
    //     which reaches `GenerationEngine.submit`, which is where the budget
    //     pre-flight, the prompt-safety check, the reference-image rule and
    //     the pre/post-generate hooks live. There is no second path.

    /// Default wall-clock ceiling on one `tools/call`. A DAG of long shots can
    /// otherwise outlive any client's patience: 20 shots × a 600 s per-shot
    /// timeout is over three hours of silence on a request/response pipe.
    static let projectRunDefaultTimeout: Double = 900
    static let projectRunMaxTimeout: Double = 3600

    static func toolProjectRun(_ args: [String: AnyCodableValue],
                                context: ActionContext) async throws -> [String: Any] {
        let projectId = try requireIdentifier(args, "project_id")
        guard let project = ProjectStore.shared.get(projectId) else {
            throw OpenFlixError.generationNotFound("Project '\(projectId)' not found")
        }

        let resume = optionalBool(args, "resume") ?? false
        let confirm = optionalBool(args, "confirm") ?? false
        let plan = ProjectRunPlanner.plan(project: project, resume: resume)
        let budget = await BudgetManager.shared.statusSummary()

        var base: [String: Any] = [
            "project_id": projectId,
            "name": project.name,
            "project_status": project.status.rawValue,
            "resume": resume,
        ]
        base.merge(plan.jsonRepresentation) { a, _ in a }
        base["budget"] = budget

        // A graph that cannot be ordered is refused in both modes: planning a
        // cyclic project would quote a price for something that can never run.
        if let graphError = plan.graphError {
            throw MCPToolRefusal(code: "invalid_graph", message: graphError, details: base)
        }

        // ---- Plan mode. Spends nothing, submits nothing, writes nothing. ----
        if !confirm {
            var out = base
            out["executed"] = false
            out["mode"] = "plan"
            out["next_step"] = planNextStep(plan: plan, project: project, resume: resume, budget: budget)
            return out
        }

        // ---- Everything below this line is a request to spend. ----

        // Same gate as `openflix project run`, for the same reason: a project
        // already `.running` may have a live executor in another process, and
        // two executors on one DAG is a double bill.
        let runnable: Set<Project.ProjectStatus> = [.draft, .paused, .partialFailure, .failed]
        guard runnable.contains(project.status) else {
            throw MCPToolRefusal(
                code: "project_not_runnable",
                message: "Project '\(projectId)' has status '\(project.status.rawValue)' — only draft, paused, partially failed or failed projects can be run. A project left 'running' by a crashed run must be reset before it can be re-run.",
                details: base)
        }

        guard plan.wouldSpend else {
            throw MCPToolRefusal(
                code: "nothing_to_run",
                message: plan.blockedShots.isEmpty
                    ? "Nothing to run: every shot in '\(project.name)' is already in a terminal state. Pass resume: true to retry the ones that failed."
                    : "Nothing to run: all \(plan.blockedShots.count) candidate shot(s) would be refused locally before any provider call. See shots[].blocked_reason.",
                details: base)
        }

        // The ceiling. Required, finite and positive — an agent that cannot
        // name a number it is willing to spend has not decided to spend.
        guard let ceiling = optionalDouble(args, "max_cost_usd"), ceiling.isFinite, ceiling > 0 else {
            throw MCPToolRefusal(
                code: "cost_ceiling_required",
                message: "Refusing to run: max_cost_usd is required (a finite, positive number of US dollars) whenever confirm is true. This plan estimates \(usd(plan.totalEstimatedCostUSD)) across \(plan.runnableShots.count) shot(s). Show the user the plan, then call project_run again with confirm: true and max_cost_usd set to a ceiling they accept.",
                details: base)
        }
        guard plan.totalEstimatedCostUSD <= ceiling else {
            var details = base
            details["cost_ceiling_usd"] = round4(ceiling)
            throw MCPToolRefusal(
                code: "cost_ceiling_too_low",
                message: "Refusing to run: the plan estimates \(usd(plan.totalEstimatedCostUSD)), above the \(usd(ceiling)) ceiling you set. Nothing was submitted. Either raise max_cost_usd, or reduce the project (fewer shots, shorter durations, a cheaper provider) and plan again.",
                details: details)
        }

        // ---- Committed. From here money can be spent. ----

        if resume { DAGExecutor.resetStaleShots(projectId: projectId) }

        var qualityConfig = project.settings.qualityConfig
        let threshold = optionalDouble(args, "quality_threshold")
        if optionalBool(args, "evaluate") == true || threshold != nil { qualityConfig.enabled = true }
        if let threshold, threshold.isFinite { qualityConfig.threshold = threshold }

        let deadline = clampedRunTimeout(args)
        let journal = RunJournal()
        let runId = UUID().uuidString
        var initialNodes: [String: NodeRecord] = [:]
        if let current = ProjectStore.shared.get(projectId) {
            for shot in current.allShots {
                initialNodes[shot.name] = NodeRecord(
                    nodeId: shot.name,
                    inputsHash: RunJournal.inputsHash(for: shot),
                    status: shot.status == .succeeded ? "succeeded" : "pending",
                    generationId: shot.selectedGenerationId,
                    outputPath: nil, costUSD: shot.actualCostUSD,
                    startedAt: shot.startedAt, completedAt: shot.completedAt)
            }
        }
        _ = journal.create(runId: runId, kind: "project", name: project.name,
                           projectId: projectId, nodes: initialNodes)

        // A shot may not outlive the call it was started by. Without this, one
        // shot with the default 600 s poll timeout can burn the whole deadline.
        let perShotBase = project.settings.timeoutPerShot
        let perShotTimeout = (perShotBase.isFinite && perShotBase > 0)
            ? Swift.min(perShotBase, deadline) : deadline

        let timedOutFlag = MCPTimeoutFlag()
        let executor = DAGExecutor(
            projectId: projectId,
            maxConcurrency: optionalInt(args, "concurrency") ?? project.settings.maxConcurrency,
            stream: false,
            apiKey: nil,
            skipDownload: false,
            timeout: perShotTimeout,
            maxRetriesPerShot: project.settings.maxRetriesPerShot,
            qualityConfig: qualityConfig,
            journal: journal,
            runId: runId,
            costCeilingUSD: ceiling,
            onProgress: context.progress.map { sink in
                { @Sendable (p: DAGProgress) in
                    sink(ActionProgress(completed: p.completed, total: p.total, message: progressMessage(p)))
                }
            })

        context.progress?(ActionProgress(
            completed: 0, total: plan.runnableShots.count,
            message: "Starting '\(project.name)': \(plan.runnableShots.count) shot(s), "
                                 + "estimated \(usd(plan.totalEstimatedCostUSD)), ceiling \(usd(ceiling)). "
                                 + "Run journal \(runId)."))

        // Wall-clock bound. `pause()` rather than `cancel()` on purpose: a
        // paused project is resumable and a cancelled one is not (the status
        // gate above refuses `.cancelled`), so timing out must never be the
        // thing that strands a half-finished run.
        let watchdog = Task { [deadline] in
            try? await Task.sleep(nanoseconds: nanoseconds(deadline))
            guard !Task.isCancelled else { return }
            timedOutFlag.set()
            await executor.pause()
        }

        let finished: Project
        do {
            finished = try await executor.execute()
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            var details = base
            details["run_id"] = runId
            details["cost_ceiling_usd"] = round4(ceiling)
            throw MCPToolRefusal(
                code: "run_failed",
                message: (error as? OpenFlixError)?.errorDescription ?? error.localizedDescription,
                details: details)
        }

        return executionResult(project: finished, plan: plan, runId: runId,
                               ceiling: ceiling, timedOut: timedOutFlag.isSet,
                               budget: await BudgetManager.shared.statusSummary())
    }

    // MARK: project_run helpers

    static func executionResult(project: Project, plan: ProjectRunPlan, runId: String,
                                 ceiling: Double, timedOut: Bool,
                                 budget: [String: Any]) -> [String: Any] {
        let shots = project.allShots
        let succeeded = shots.filter { $0.status == .succeeded }
        let failed = shots.filter { $0.status == .failed }
        let skipped = shots.filter { $0.status == .skipped }
        let pending = shots.filter { !DAGExecutor.isTerminal($0.status) }
        let actual = shots.compactMap { $0.actualCostUSD }.reduce(0, +)

        var out: [String: Any] = [
            "executed": true,
            "mode": "execute",
            "project_id": project.id,
            "name": project.name,
            "status": project.status.rawValue,
            "run_id": runId,
            "run_journal_path": "~/.openflix/runs/\(runId).json",
            "timed_out": timedOut,
            "waves": plan.waveCount,
            "shots_total": shots.count,
            "shots_succeeded": succeeded.count,
            "shots_failed": failed.count,
            "shots_skipped": skipped.count,
            "shots_pending": pending.count,
            "estimated_cost_usd": round4(plan.totalEstimatedCostUSD),
            "estimated_cost_is_upper_bound": true,
            "actual_cost_usd": round4(actual),
            "cost_ceiling_usd": round4(ceiling),
            "budget": budget,
            // Every shot, not just the failures: "what ran, what did not, what
            // it cost" has to be answerable from one result.
            "shots": shots.map { shot -> [String: Any] in
                var d: [String: Any] = ["shot_id": shot.id, "name": shot.name,
                                        "status": shot.status.rawValue]
                if let v = shot.provider            { d["provider"] = v }
                if let v = shot.model               { d["model"] = v }
                if let v = shot.selectedGenerationId {
                    d["generation_id"] = v
                    d["resource_uri"] = "openflix://generation/\(v)"
                }
                if let v = shot.actualCostUSD       { d["actual_cost_usd"] = round4(v) }
                if let v = shot.qualityScore        { d["quality_score"] = round4(v) }
                if let v = shot.errorMessage        { d["error"] = v }
                return d
            },
        ]
        out["next_step"] = runNextStep(project: project, failed: failed.count,
                                       skipped: skipped.count, pending: pending.count,
                                       timedOut: timedOut, ceiling: ceiling,
                                       spent: actual)
        return out
    }

    static func planNextStep(plan: ProjectRunPlan, project: Project,
                              resume: Bool, budget: [String: Any]) -> String {
        if !plan.wouldSpend {
            if plan.blockedShots.isEmpty {
                return "Nothing would run — every shot is already terminal. Pass resume: true to retry the ones that failed."
            }
            return "Nothing would run — all \(plan.blockedShots.count) candidate shot(s) would be refused locally. Fix the reasons in shots[].blocked_reason first; none of them costs anything."
        }
        var lines = [
            "NOTHING HAS BEEN SPENT. This is an estimate of what running '\(project.name)' would cost: "
            + "\(usd(plan.totalEstimatedCostUSD)) across \(plan.runnableShots.count) shot(s) in \(plan.waveCount) wave(s).",
        ]
        if !plan.blockedShots.isEmpty {
            lines.append("\(plan.blockedShots.count) further shot(s) would be refused locally before any provider call — see shots[].blocked_reason.")
        }
        if let remaining = budget["daily_remaining_usd"] as? Double,
           plan.totalEstimatedCostUSD > remaining {
            lines.append("WARNING: the estimate exceeds today's remaining budget (\(usd(remaining))). The per-generation budget gate will refuse shots partway through the run.")
        }
        let suggested = suggestedCeiling(plan.totalEstimatedCostUSD)
        lines.append("Show this to the user. If they agree, call project_run again with "
                     + "{\"project_id\": \"\(project.id)\", \"confirm\": true, \"max_cost_usd\": \(suggested)"
                     + (resume ? ", \"resume\": true" : "") + "}.")
        return lines.joined(separator: " ")
    }

    static func runNextStep(project: Project, failed: Int, skipped: Int, pending: Int,
                             timedOut: Bool, ceiling: Double, spent: Double) -> String {
        let resumeCall = "call project_run again with {\"project_id\": \"\(project.id)\", \"resume\": true, "
            + "\"confirm\": true, \"max_cost_usd\": <a new ceiling>} — resume retries the failed shots and the ones "
            + "that were blocked behind them. Already-succeeded shots are not re-billed."
        if timedOut {
            return "The run hit its timeout and was PAUSED after spending \(usd(spent)); \(pending) shot(s) never started. "
                + "Any shot already submitted to a provider is still billed and will finish there. To continue, \(resumeCall)"
        }
        if failed == 0 && skipped == 0 && pending == 0 {
            return "All shots succeeded. Spent \(usd(spent)) of the \(usd(ceiling)) ceiling. "
                + "Each shot's video is at shots[].generation_id — read openflix://generation/<id> for the file path."
        }
        var lines = ["\(failed) shot(s) failed"]
        if skipped > 0 { lines.append("\(skipped) were skipped because an upstream shot failed") }
        if pending > 0 { lines.append("\(pending) never ran") }
        return lines.joined(separator: ", ")
            + ". Spent \(usd(spent)). Read shots[].error for the reason on each failure — if it is a budget refusal, "
            + "raise the ceiling or the daily budget; if it is a provider error, fix the shot. Then \(resumeCall)"
    }

    /// A ceiling a little above the estimate, so a provider billing slightly
    /// more than the table says does not halt the run at shot 6 of 7.
    static func suggestedCeiling(_ estimate: Double) -> Double {
        guard estimate.isFinite, estimate > 0 else { return 1 }
        return ((estimate * 1.2) * 100).rounded(.up) / 100
    }

    static func clampedRunTimeout(_ args: [String: AnyCodableValue]) -> Double {
        guard let requested = optionalDouble(args, "timeout_seconds"), requested.isFinite,
              requested > 0 else { return Self.projectRunDefaultTimeout }
        return Swift.min(requested, Self.projectRunMaxTimeout)
    }

    static func round4(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return (v * 10000).rounded() / 10000
    }

    static func usd(_ v: Double) -> String {
        guard v.isFinite else { return "$0.00" }
        return String(format: "$%.2f", v)
    }

    static func toolHealthCheck() async throws -> [String: Any] {
        let available = ProviderRouter.availableProviders()
        let all = ProviderRegistry.shared.all.map { $0.providerId }
        return [
            "providers": all.map { id in
                [
                    "provider": id,
                    "configured": available.contains(id),
                ] as [String : Any]
            },
            "configured_count": available.count,
            "total_count": all.count,
        ]
    }

    static func requireString(_ args: [String: AnyCodableValue], _ key: String) throws -> String {
        guard case .string(let v) = args[key] else {
            throw OpenFlixError.invalidResponse("Missing required parameter: \(key)")
        }
        return v
    }

    /// A record id from tool arguments, checked against the same grammar the
    /// resource templates use.
    ///
    /// `GenerationStore`, `RecipeStore` and `ProjectStore` all turn an id into a
    /// filename with `appendingPathComponent`, and every id arriving here was
    /// chosen by a model that may have been reading attacker-controlled text.
    /// Real ids are UUIDs, so this refuses nothing a caller legitimately has.
    static func requireIdentifier(_ args: [String: AnyCodableValue], _ key: String) throws -> String {
        let value = try requireString(args, key)
        guard MCPIdentifier.isWellFormed(value) else {
            throw OpenFlixError.invalidResponse(
                "Parameter '\(key)' is not a valid id (letters, digits, '.', '_' and '-' only, max \(MCPIdentifier.maxLength) characters)")
        }
        return value
    }

    static func requireDouble(_ args: [String: AnyCodableValue], _ key: String) throws -> Double {
        switch args[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: throw OpenFlixError.invalidResponse("Missing required parameter: \(key)")
        }
    }

    static func optionalString(_ args: [String: AnyCodableValue], _ key: String) -> String? {
        if case .string(let v) = args[key] { return v }
        return nil
    }

    static func optionalInt(_ args: [String: AnyCodableValue], _ key: String) -> Int? {
        if case .int(let v) = args[key] { return v }
        return nil
    }

    static func optionalDouble(_ args: [String: AnyCodableValue], _ key: String) -> Double? {
        switch args[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    static func optionalBool(_ args: [String: AnyCodableValue], _ key: String) -> Bool? {
        if case .bool(let v) = args[key] { return v }
        return nil
    }
}


// Extension for terminal status check
private extension CLIGeneration.GenerationStatus {
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }
}
