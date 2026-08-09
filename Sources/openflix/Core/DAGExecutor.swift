import Foundation
import OpenFlixKit

// MARK: - DAG Resolution

struct DAGResolver {

    /// Topological sort with cycle detection (Kahn's algorithm).
    /// Returns shots grouped by parallelism level ("waves").
    static func resolve(shots: [Shot]) throws -> [[Shot]] {
        // Tolerate duplicate ids here rather than trapping — malformed input
        // should surface as a thrown/structured error upstream, never crash.
        let shotMap = Dictionary(shots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]  // id → IDs that depend on it

        for shot in shots {
            inDegree[shot.id] = shot.dependencies.count
            for dep in shot.dependencies {
                dependents[dep, default: []].append(shot.id)
            }
        }

        var waves: [[Shot]] = []
        // Sort the first wave by orderIndex too, so root-shot dispatch order is
        // deterministic and consistent with every later wave (which is sorted).
        var queue = shots.filter { inDegree[$0.id, default: 0] == 0 }
            .sorted { $0.orderIndex < $1.orderIndex }
        var processed = 0

        while !queue.isEmpty {
            waves.append(queue)
            processed += queue.count
            var nextQueue: [Shot] = []
            for shot in queue {
                for depId in dependents[shot.id, default: []] {
                    inDegree[depId, default: 0] -= 1
                    if inDegree[depId, default: 0] == 0 {
                        if let s = shotMap[depId] { nextQueue.append(s) }
                    }
                }
            }
            queue = nextQueue.sorted { $0.orderIndex < $1.orderIndex }
        }

        if processed < shots.count {
            let remaining = shots.filter { inDegree[$0.id, default: 0] > 0 }.map { $0.name }
            throw ProjectSpecError.cyclicDependency(remaining.joined(separator: ", "))
        }

        return waves
    }

    /// Validate that there are no cycles in the shot dependency graph.
    static func validateNoCycles(shots: [Shot]) throws {
        _ = try resolve(shots: shots)
    }

    /// Returns shots whose dependencies are all satisfied (completed or skipped).
    static func readyShots(allShots: [Shot]) -> [Shot] {
        let completedIds = Set(allShots.filter {
            $0.status == .succeeded || $0.status == .skipped
        }.map { $0.id })
        return allShots.filter { shot in
            shot.status == .pending &&
            shot.dependencies.allSatisfy { completedIds.contains($0) }
        }
    }
}

// MARK: - Progress

/// One node reaching a terminal state, reported as it happens.
///
/// This exists because a DAG of N shots takes minutes and a caller that can
/// only see the final result has no way to tell "working" from "hung". The
/// callback fires at the same choke point the run journal is written from, so
/// the two can never disagree about what finished.
struct DAGProgress: Sendable {
    let completed: Int
    let total: Int
    let shotName: String
    /// `Shot.ShotStatus.rawValue` at the moment the node finished.
    let status: String
    /// Billed so far across the whole project, not just this shot.
    let costSoFarUSD: Double
    let errorMessage: String?
}

// MARK: - DAG Executor

actor DAGExecutor {
    private let projectId: String
    private let store: ProjectStore
    private let maxConcurrency: Int
    private let stream: Bool
    private let apiKey: String?
    private let skipDownload: Bool
    private let timeout: Double
    private let maxRetriesPerShot: Int
    /// A caller-supplied ceiling that can only ever make the run *stricter*.
    ///
    /// The project's own `costBudgetUSD` still applies; the gate uses whichever
    /// of the two is tighter. Nothing here can raise a limit — not the
    /// project's, and not `BudgetManager`'s daily/monthly/per-generation ones,
    /// which are enforced further down at `GenerationEngine.submit`.
    private let costCeilingUSD: Double?
    /// Fires once per node reaching a terminal state. Nil for the CLI, which
    /// already streams `--stream` events on stdout.
    private let onProgress: (@Sendable (DAGProgress) -> Void)?
    let qualityConfig: QualityConfig
    private var cancelled = false
    private var paused = false
    // Run journal (step 1 of the agentic engine): one record per node,
    // written incrementally (after each node) and atomically.
    private let journal: RunJournal?
    private let runId: String?
    private let nodeHashes: [String: String]  // shot name → inputs hash
    // reference_from edges (Wave 4): shot name → upstream shot name whose
    // output feeds forward as the I2V reference. Resolution happens lazily at
    // dispatch time (the upstream output does not exist before then).
    private let referenceEdges: [String: String]
    private var resolvedReferencePaths: [String: String] = [:]

    init(
        projectId: String,
        store: ProjectStore = .shared,
        maxConcurrency: Int = 4,
        stream: Bool = false,
        apiKey: String? = nil,
        skipDownload: Bool = false,
        timeout: Double = 600,
        maxRetriesPerShot: Int = 2,
        qualityConfig: QualityConfig = QualityConfig(),
        journal: RunJournal? = nil,
        runId: String? = nil,
        nodeHashes: [String: String] = [:],
        referenceEdges: [String: String] = [:],
        costCeilingUSD: Double? = nil,
        onProgress: (@Sendable (DAGProgress) -> Void)? = nil
    ) {
        self.projectId = projectId
        self.store = store
        // Clamp to >=1: a spec/flag value of 0 (or negative) would make the
        // dispatch loop spin forever with zero available slots — a config-driven
        // hang. At least one shot must always be dispatchable.
        self.maxConcurrency = max(1, maxConcurrency)
        self.stream = stream
        self.apiKey = apiKey
        self.skipDownload = skipDownload
        self.timeout = timeout
        self.maxRetriesPerShot = maxRetriesPerShot
        self.qualityConfig = qualityConfig
        self.journal = journal
        self.runId = runId
        self.nodeHashes = nodeHashes
        self.referenceEdges = referenceEdges
        // A non-finite ceiling is not a ceiling: `spend >= NaN` is always
        // false, so keeping it would silently disable the gate it was meant
        // to tighten. Drop it rather than pretend.
        self.costCeilingUSD = (costCeilingUSD?.isFinite ?? false) ? costCeilingUSD : nil
        self.onProgress = onProgress
    }

    func execute() async throws -> Project {
        guard var project = store.get(projectId) else {
            throw OpenFlixError.generationNotFound(projectId)
        }

        // 1. Validate DAG
        try DAGResolver.validateNoCycles(shots: project.allShots)

        // 2. Mark project running
        store.update(id: projectId) { $0.status = .running }
        project.status = .running

        if stream {
            Output.emitEvent(["event": "project.started", "project_id": projectId,
                              "total_shots": project.allShots.count,
                              "timestamp": now()])
        }

        // 3. Main dispatch loop
        while !cancelled {
            guard let currentProject = store.get(projectId) else { break }
            let allShots = currentProject.allShots
            let ready = DAGResolver.readyShots(allShots: allShots)
            let running = allShots.filter { $0.status == .dispatched || $0.status == .processing }

            if ready.isEmpty && running.isEmpty { break }
            if ready.isEmpty {
                // Wait for running shots to finish
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // Dispatch ready shots up to maxConcurrency - currently running
            let slotsAvailable = max(0, maxConcurrency - running.count)
            let toDispatch = Array(ready.prefix(slotsAvailable))

            if toDispatch.isEmpty {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            await withTaskGroup(of: Void.self) { group in
                for shot in toDispatch {
                    group.addTask { [self] in
                        await self.executeShot(shot, project: currentProject)
                        // Journal choke point: record the node's final state
                        // right after it finishes (incremental, atomic).
                        await self.journalNode(shotId: shot.id)
                        // Same choke point, different consumer: tell whoever is
                        // waiting on this run that one more node is done.
                        await self.reportProgress(shotId: shot.id)
                    }
                }
            }
        }

        // 3b. Drain orphaned shots. A shot whose dependency FAILED can never
        // become ready (readyShots only counts succeeded/skipped deps), so it
        // would otherwise sit .pending forever — and be miscounted as "not
        // failed" in the status math below. Mark such shots .skipped(blocked)
        // so they reach a terminal state and the final status is honest.
        if !cancelled {
            store.update(id: projectId) { p in
                let terminalOK = Set(p.allShots
                    .filter { $0.status == .succeeded || $0.status == .skipped }
                    .map { $0.id })
                for si in p.scenes.indices {
                    for shi in p.scenes[si].shots.indices
                    where p.scenes[si].shots[shi].status == .pending
                        && !p.scenes[si].shots[shi].dependencies.allSatisfy({ terminalOK.contains($0) }) {
                        p.scenes[si].shots[shi].status = .skipped
                        p.scenes[si].shots[shi].errorMessage = Self.blockedByUpstreamMessage
                    }
                }
            }
        }

        // 4. Compute final status
        guard var finalProject = store.get(projectId) else {
            throw OpenFlixError.generationNotFound(projectId)
        }
        let allShots = finalProject.allShots
        let succeeded = allShots.filter { $0.status == .succeeded }.count
        let failed = allShots.filter { $0.status == .failed }.count

        let totalCost = allShots.compactMap { $0.actualCostUSD }.reduce(0, +)

        // Only report .succeeded when there are zero failures. Any residual
        // (a hard failure, or a shot blocked by one) makes the run a partial
        // failure if anything succeeded, otherwise a full failure. The old
        // catch-all `else -> .succeeded` reported failed/empty runs as success.
        if paused {
            finalProject.status = .paused
        } else if cancelled {
            finalProject.status = .cancelled
        } else if failed == 0 {
            finalProject.status = .succeeded
        } else if succeeded > 0 {
            finalProject.status = .partialFailure
        } else {
            finalProject.status = .failed
        }
        finalProject.totalActualCostUSD = totalCost
        finalProject.completedAt = Date()

        store.update(id: projectId) { p in
            p.status = finalProject.status
            p.totalActualCostUSD = totalCost
            p.completedAt = finalProject.completedAt
        }

        if stream {
            Output.emitEvent(["event": "project.completed", "project_id": projectId,
                              "status": finalProject.status.rawValue,
                              "total_actual_cost_usd": totalCost,
                              "timestamp": now()])
        }

        return store.get(projectId) ?? finalProject
    }

    private func executeShot(_ shot: Shot, project: Project) async {
        var shot = shot

        // reference_from resolution: the upstream node has completed (DAG
        // ordering guarantees it — normalization adds the edge to needs), so
        // its selected output — remote video URL, or local path as fallback —
        // is passed through as this shot's reference input. Providers whose
        // request already supports a reference receive it; others ignore it
        // (the plan/journal still record the intent honestly).
        if let from = referenceEdges[shot.name] {
            let upstream = store.get(projectId)?.allShots.first { $0.name == from }
            let resolved = upstream?.selectedGenerationId
                .flatMap { GenerationStore.shared.get($0) }
                .flatMap { $0.remoteVideoURL ?? $0.localPath }
            if let resolved {
                resolvedReferencePaths[shot.name] = resolved
                shot.referenceImageURL = resolved
                store.updateShot(projectId: projectId, shotId: shot.id) { s in
                    s.referenceImageURL = resolved
                }
            }
        }

        // Mark dispatched
        store.updateShot(projectId: projectId, shotId: shot.id) { s in
            s.status = .dispatched
            s.startedAt = Date()
        }

        if stream {
            Output.emitEvent(["event": "shot.dispatched", "project_id": projectId,
                              "shot_id": shot.id, "shot_name": shot.name,
                              "timestamp": now()])
        }

        // Resolve provider/model. The decision itself lives in
        // `plannedTarget`, shared with the dry-run planner: a plan that quotes
        // a different model than the run dispatches is a lie about money.
        let providerID: String
        let modelID: String

        switch Self.plannedTarget(shot: shot, settings: project.settings,
                                  availableProviders: ProviderRouter.availableProviders()) {
        case .pinned(let p, let m), .projectDefault(let p, let m):
            providerID = p
            modelID = m
        case .routed(let decision):
            providerID = decision.provider
            modelID = decision.model
            store.updateShot(projectId: projectId, shotId: shot.id) { s in
                s.provider = decision.provider
                s.model = decision.model
                s.routingDecision = decision.reason
                s.estimatedCostUSD = decision.estimatedCostUSD
            }
        case .routingFailed(let detail):
            markShotFailed(shot.id, error: "Routing failed: \(detail)")
            return
        case .unresolved:
            markShotFailed(shot.id, error: Self.unresolvedTargetMessage)
            return
        }

        // Check cost budget. Count spend already billed (completed shots) PLUS
        // the estimated cost of shots already dispatched but not yet complete —
        // without the in-flight estimate, every shot in a concurrent wave reads
        // $0 billed and dispatches, so total spend could reach maxConcurrency ×
        // budget before the first shot completes.
        if let budget = effectiveCostBudget(project) {
            let shots = store.get(projectId)?.allShots ?? []
            let currentCost = shots.reduce(0.0) { acc, s in
                if let actual = s.actualCostUSD { return acc + actual }        // billed
                if s.status == .processing { return acc + (s.estimatedCostUSD ?? 0) } // reserved
                return acc
            }
            if currentCost >= budget {
                markShotFailed(shot.id, error: "Cost budget exceeded (\(currentCost) >= \(budget) USD)")
                return
            }
        }

        // Reserve this shot's estimated cost synchronously (no await before the
        // dispatch below), so the next shot's budget check above sees it as
        // in-flight. Routed shots already have an estimate; pinned shots don't,
        // so compute one from the pricing table.
        let reservedEstimate = ModelPricing.estimate(
            durationSeconds: shot.duration ?? GenerationEngine.defaultBillableDurationSeconds,
            modelId: modelID, providerId: providerID)
        store.updateShot(projectId: projectId, shotId: shot.id) { s in
            if s.estimatedCostUSD == nil { s.estimatedCostUSD = reservedEstimate }
            s.status = .processing
        }

        // Fanout / scatter-gather / single dispatch
        let maxRetries = shot.maxRetries ?? maxRetriesPerShot

        if let fanout = shot.fanout, fanout > 1 {
            await executeFanoutShot(shot: shot, count: fanout, providerID: providerID, modelID: modelID)
        } else if project.settings.routingStrategy == .scatterGather,
           let count = project.settings.scatterCount, count > 1 {
            await executeScatterGather(shot: shot, count: count, providerID: providerID, modelID: modelID)
        } else {
            await executeSingleShot(shot: shot, providerID: providerID, modelID: modelID, maxRetries: maxRetries)
        }
    }

    /// Workflow fanout: N candidates from the SAME provider/model via the
    /// existing scatter executor, then judge with the existing evaluator
    /// machinery and keep the top K (JudgeSelector is the pure part).
    private func executeFanoutShot(shot: Shot, count rawCount: Int, providerID: String, modelID: String) async {
        // Clamp defensively: workflow specs are bounded by WorkflowSpec.validate,
        // but a project shot can carry an arbitrary `fanout`, and this drives an
        // eager Array(repeating:count:) plus one billed generation each.
        let count = max(1, min(rawCount, WorkflowSpec.maxFanout))
        let targets = Array(repeating: (provider: providerID, model: modelID), count: count)
        let options = GenerationEngine.Options(
            pollInterval: 3,
            timeout: timeout,
            outputURL: nil,
            stream: stream,
            skipDownload: skipDownload,
            maxRetries: 0
        )

        store.updateShot(projectId: projectId, shotId: shot.id) { $0.status = .processing }

        let results = await ScatterGatherExecutor.scatter(
            shot: shot, targets: targets, apiKey: apiKey, options: options
        )

        for r in results where !r.generationId.isEmpty {
            GenerationStore.shared.update(id: r.generationId) { g in
                g.projectId = projectId
                g.shotId = shot.id
            }
        }

        let succeeded = results.filter { $0.status == "succeeded" && !$0.generationId.isEmpty }
        guard !succeeded.isEmpty else {
            let errors = results.compactMap { $0.errorMessage }.joined(separator: "; ")
            markShotFailed(shot.id, error: "All \(count) fanout candidates failed: \(errors)")
            return
        }

        // Judge: score candidates with the existing quality-gate machinery.
        var candidates: [JudgeSelector.Candidate] = []
        if shot.judge != nil || qualityConfig.enabled {
            store.updateShot(projectId: projectId, shotId: shot.id) { $0.status = .evaluating }
            var evalConfig = qualityConfig
            evalConfig.enabled = true
            for r in succeeded {
                var score: Double?
                if let gen = GenerationStore.shared.get(r.generationId),
                   let videoPath = gen.localPath {
                    if let result = try? await QualityGate.evaluate(
                        generation: gen, videoPath: videoPath, shot: shot, config: evalConfig
                    ) {
                        score = result.score
                    }
                }
                candidates.append(.init(id: r.generationId, score: score))
            }
        } else {
            candidates = succeeded.map { .init(id: $0.generationId, score: nil) }
        }

        let keep = shot.judge?.keep ?? 1
        let kept = JudgeSelector.selectTopK(candidates, keep: keep, minScore: shot.judge?.minScore)

        guard let best = kept.first else {
            let bestScore = candidates.compactMap { $0.score }.max()
            let detail = bestScore.map { String(format: "best score %.1f", $0) } ?? "no candidates scored"
            markShotFailed(shot.id, error: "Judge rejected all \(succeeded.count) candidates (min_score \(shot.judge?.minScore ?? 0), \(detail))")
            return
        }

        store.updateShot(projectId: projectId, shotId: shot.id) { s in
            s.status = .succeeded
            s.generationIds = results.filter { !$0.generationId.isEmpty }.map { $0.generationId }
            s.keptGenerationIds = kept.map { $0.id }
            s.selectedGenerationId = best.id
            s.qualityScore = best.score
            s.actualCostUSD = results.compactMap { $0.costUSD }.reduce(0, +)
            s.completedAt = Date()
        }
        if stream {
            var evt: [String: Any] = ["event": "shot.succeeded", "project_id": projectId,
                                      "shot_id": shot.id, "shot_name": shot.name,
                                      "generation_id": best.id,
                                      "fanout": count, "kept": kept.count,
                                      "timestamp": now()]
            if let s = best.score { evt["quality_score"] = s }
            Output.emitEvent(evt)
        }
    }

    /// Write the node's final state to the run journal (no-op without journal).
    private func journalNode(shotId: String) {
        guard let journal, let runId,
              let shot = store.get(projectId)?.allShots.first(where: { $0.id == shotId }) else { return }
        let hash = nodeHashes[shot.name] ?? RunJournal.inputsHash(for: shot)
        let outputPath = shot.selectedGenerationId
            .flatMap { GenerationStore.shared.get($0)?.localPath }
        let reference = referenceEdges[shot.name].map {
            NodeReferenceRecord(from: $0, resolvedPath: resolvedReferencePaths[shot.name])
        }
        journal.upsertNode(runId: runId, NodeRecord(
            nodeId: shot.name,
            inputsHash: hash,
            status: shot.status.rawValue,
            generationId: shot.selectedGenerationId,
            outputPath: outputPath,
            costUSD: shot.actualCostUSD,
            startedAt: shot.startedAt,
            completedAt: shot.completedAt,
            reference: reference
        ))
    }

    private func executeSingleShot(shot: Shot, providerID: String, modelID: String, maxRetries: Int) async {
        let options = GenerationEngine.Options(
            pollInterval: 3,
            timeout: timeout,
            outputURL: nil,
            stream: stream,
            skipDownload: skipDownload,
            maxRetries: maxRetries
        )

        do {
            // Parsed inside the do-block so an unusable reference image fails
            // the shot with a message instead of being silently dropped and
            // billed as a text-to-video generation.
            let imageURL = try GenerationEngine.parseReferenceImage(shot.referenceImageURL)

            store.updateShot(projectId: projectId, shotId: shot.id) { s in
                s.status = .processing
            }

            let gen = try await GenerationEngine.submitAndWait(
                prompt: shot.prompt,
                negativePrompt: shot.negativePrompt,
                provider: providerID,
                model: modelID,
                durationSeconds: shot.duration,
                aspectRatio: shot.aspectRatio,
                width: shot.width,
                height: shot.height,
                referenceImageURL: imageURL,
                extraParams: shot.extraParams.reduce(into: [:]) { $0[$1.key] = $1.value as Any },
                apiKey: apiKey,
                options: options
            )

            // Link generation to project/shot
            GenerationStore.shared.update(id: gen.id) { g in
                g.projectId = projectId
                g.shotId = shot.id
            }

            // Record provider metrics
            let elapsed = Int(Date().timeIntervalSince(gen.createdAt) * 1000)
            ProviderMetricsStore.shared.recordGeneration(
                provider: providerID, model: modelID,
                succeeded: true, latencyMs: elapsed,
                costUSD: gen.actualCostUSD
            )

            // Quality gate
            if qualityConfig.enabled, let videoPath = gen.localPath {
                store.updateShot(projectId: projectId, shotId: shot.id) { s in
                    s.status = .evaluating
                    s.generationIds.append(gen.id)
                    s.selectedGenerationId = gen.id
                    s.actualCostUSD = gen.actualCostUSD
                }

                if stream {
                    Output.emitEvent(["event": "shot.evaluating", "project_id": projectId,
                                      "shot_id": shot.id, "shot_name": shot.name,
                                      "timestamp": now()])
                }

                let currentShot = store.get(projectId)?.allShots.first { $0.id == shot.id }
                let (passed, evalResult, shouldRetry) = await QualityGate.check(
                    generation: gen, videoPath: videoPath, shot: currentShot, config: qualityConfig
                )

                if let result = evalResult {
                    store.updateShot(projectId: projectId, shotId: shot.id) { s in
                        s.qualityScore = result.score
                        s.evaluationReasoning = result.reasoning
                        s.evaluationDimensions = result.dimensions
                    }
                }

                if passed {
                    store.updateShot(projectId: projectId, shotId: shot.id) { s in
                        s.status = .succeeded
                        s.completedAt = Date()
                    }
                    if stream {
                        Output.emitEvent(["event": "shot.succeeded", "project_id": projectId,
                                          "shot_id": shot.id, "shot_name": shot.name,
                                          "generation_id": gen.id,
                                          "quality_score": evalResult?.score ?? 0,
                                          "timestamp": now()])
                    }
                } else if shouldRetry {
                    store.updateShot(projectId: projectId, shotId: shot.id) { s in
                        s.status = .pending
                        s.qualityRetryCount += 1
                        s.selectedGenerationId = nil
                        s.startedAt = nil
                    }
                    if stream {
                        Output.emitEvent(["event": "shot.quality_retry", "project_id": projectId,
                                          "shot_id": shot.id, "shot_name": shot.name,
                                          "quality_score": evalResult?.score ?? 0,
                                          "timestamp": now()])
                    }
                } else {
                    // Quality is advisory — mark succeeded anyway
                    store.updateShot(projectId: projectId, shotId: shot.id) { s in
                        s.status = .succeeded
                        s.completedAt = Date()
                    }
                    if stream {
                        Output.emitEvent(["event": "shot.succeeded", "project_id": projectId,
                                          "shot_id": shot.id, "shot_name": shot.name,
                                          "generation_id": gen.id,
                                          "quality_score": evalResult?.score ?? 0,
                                          "quality_below_threshold": true,
                                          "timestamp": now()])
                    }
                }
            } else {
                // No quality gate — original behavior
                store.updateShot(projectId: projectId, shotId: shot.id) { s in
                    s.status = .succeeded
                    s.generationIds.append(gen.id)
                    s.selectedGenerationId = gen.id
                    s.actualCostUSD = gen.actualCostUSD
                    s.completedAt = Date()
                }

                if stream {
                    Output.emitEvent(["event": "shot.succeeded", "project_id": projectId,
                                      "shot_id": shot.id, "shot_name": shot.name,
                                      "generation_id": gen.id,
                                      "timestamp": now()])
                }
            }
        } catch {
            let msg = (error as? OpenFlixError)?.errorDescription ?? error.localizedDescription
            // Record failure metrics
            ProviderMetricsStore.shared.recordGeneration(
                provider: providerID, model: modelID,
                succeeded: false, latencyMs: 0, costUSD: nil
            )
            markShotFailed(shot.id, error: msg)
        }
    }

    private func executeScatterGather(shot: Shot, count: Int, providerID: String, modelID: String) async {
        let available = ProviderRouter.availableProviders()
        let targets = ProviderRouter.scatterTargets(shot: shot, count: count, availableProviders: available)
        guard !targets.isEmpty else {
            markShotFailed(shot.id, error: "No scatter targets available — configure provider API keys or relax the shot's model constraints.")
            return
        }

        let options = GenerationEngine.Options(
            pollInterval: 3,
            timeout: timeout,
            outputURL: nil,
            stream: stream,
            skipDownload: skipDownload,
            maxRetries: 0
        )

        let results = await ScatterGatherExecutor.scatter(
            shot: shot, targets: targets, apiKey: apiKey, options: options
        )

        // Link all generations to project
        for r in results {
            GenerationStore.shared.update(id: r.generationId) { g in
                g.projectId = projectId
                g.shotId = shot.id
            }
        }

        let best: ScatterResult?
        if qualityConfig.enabled {
            best = await ScatterGatherExecutor.selectBest(results, qualityConfig: qualityConfig)
        } else {
            best = ScatterGatherExecutor.selectBest(results)
        }

        if let best = best {
            store.updateShot(projectId: projectId, shotId: shot.id) { s in
                s.status = .succeeded
                s.generationIds = results.map { $0.generationId }
                s.selectedGenerationId = best.generationId
                s.actualCostUSD = results.compactMap { $0.costUSD }.reduce(0, +)
                s.completedAt = Date()
            }
            if stream {
                Output.emitEvent(["event": "shot.succeeded", "project_id": projectId,
                                  "shot_id": shot.id, "shot_name": shot.name,
                                  "generation_id": best.generationId,
                                  "scatter_results": results.count,
                                  "timestamp": now()])
            }
        } else {
            let errors = results.compactMap { $0.errorMessage }.joined(separator: "; ")
            markShotFailed(shot.id, error: "All scatter targets failed: \(errors)")
        }
    }

    /// The budget the gate actually enforces: the tighter of the project's own
    /// `costBudgetUSD` and any caller-supplied ceiling.
    ///
    /// Non-finite values are dropped rather than compared, because `spend >=
    /// NaN` is false and an infinite budget is the same as none — both are
    /// "no gate" today, and both stay "no gate" here.
    private func effectiveCostBudget(_ project: Project) -> Double? {
        [project.costBudgetUSD, costCeilingUSD].compactMap { $0 }.filter { $0.isFinite }.min()
    }

    /// Tell the caller one more node has finished. No-op without a callback.
    private func reportProgress(shotId: String) {
        guard let onProgress, let project = store.get(projectId) else { return }
        let all = project.allShots
        guard let shot = all.first(where: { $0.id == shotId }) else { return }
        onProgress(DAGProgress(
            completed: all.filter { Self.isTerminal($0.status) }.count,
            total: all.count,
            shotName: shot.name,
            status: shot.status.rawValue,
            costSoFarUSD: all.compactMap { $0.actualCostUSD }.reduce(0, +),
            errorMessage: shot.errorMessage))
    }

    private func markShotFailed(_ shotId: String, error: String) {
        store.updateShot(projectId: projectId, shotId: shotId) { s in
            s.status = .failed
            s.errorMessage = error
            s.completedAt = Date()
        }
        if stream {
            Output.emitEvent(["event": "shot.failed", "project_id": projectId,
                              "shot_id": shotId, "error": error,
                              "timestamp": now()])
        }
    }

    func cancel() {
        cancelled = true
        store.update(id: projectId) { $0.status = .cancelled }
    }

    func pause() {
        paused = true
        cancelled = true
        store.update(id: projectId) { $0.status = .paused }
    }

    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}

// MARK: - Shared decisions (planner ⇄ executor)

extension DAGExecutor {

    /// The message the orphan drain writes, and the marker `resetStaleShots`
    /// recognises. One spelling, because a resume that cannot identify the
    /// shots the drain touched leaves them dead forever.
    static let blockedByUpstreamMessage = "Blocked by upstream failure"

    /// The refusal for a shot with nothing to dispatch to. `test.sh` and the
    /// DAG tests both pin this string.
    static let unresolvedTargetMessage =
        "No provider/model specified and no routing strategy configured"

    static func isTerminal(_ status: Shot.ShotStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .skipped, .cancelled: return true
        default: return false
        }
    }

    /// Where a shot would be dispatched, decided **exactly** as `executeShot`
    /// decides it.
    ///
    /// Extracted so the dry-run plan and the real run cannot drift. The order
    /// is load-bearing: an explicitly pinned provider/model always wins, then
    /// routing (for any strategy other than `.manual`), then the project
    /// defaults. `availableProviders` is an autoclosure so a pinned shot still
    /// does not read the Keychain.
    static func plannedTarget(shot: Shot,
                              settings: ProjectSettings,
                              availableProviders: @autoclosure () -> [String]) -> PlannedTarget {
        if let p = shot.provider, let m = shot.model {
            return .pinned(provider: p, model: m)
        }
        if settings.routingStrategy != .manual {
            do {
                return .routed(try ProviderRouter.route(
                    shot: shot, strategy: settings.routingStrategy,
                    availableProviders: availableProviders()))
            } catch {
                return .routingFailed(error.localizedDescription)
            }
        }
        if let p = settings.defaultProvider, let m = settings.defaultModel {
            return .projectDefault(provider: p, model: m)
        }
        return .unresolved
    }

    enum PlannedTarget {
        case pinned(provider: String, model: String)
        case routed(ProviderRouter.RoutingDecision)
        case projectDefault(provider: String, model: String)
        case routingFailed(String)
        case unresolved

        var providerModel: (provider: String, model: String)? {
            switch self {
            case .pinned(let p, let m), .projectDefault(let p, let m): return (p, m)
            case .routed(let d): return (d.provider, d.model)
            case .routingFailed, .unresolved: return nil
            }
        }

        var refusal: String? {
            switch self {
            case .routingFailed(let detail): return "Routing failed: \(detail)"
            case .unresolved: return DAGExecutor.unresolvedTargetMessage
            default: return nil
            }
        }
    }

    /// Resume: bring shots that a previous run left un-runnable back to
    /// `.pending`, and report how many were reset.
    ///
    /// Three groups, and the third is the one that is easy to miss:
    ///
    /// 1. `.dispatched` / `.processing` / `.evaluating` — a run that died mid
    ///    flight. Nothing will ever move them.
    /// 2. `.failed` — the shots the user is resuming *for*.
    /// 3. `.skipped` **with the drain's own marker** — a shot downstream of a
    ///    failure. Without this the resumed run fixes shot 3 and leaves 4-7
    ///    dead, and then reports `succeeded` because `failed == 0`. The marker
    ///    is checked rather than the status alone so nothing else that ever
    ///    means "skipped" gets resurrected by accident.
    ///
    /// `ProjectRunCommand` carries an equivalent inline block that predates
    /// this and is missing group 3; it should adopt this helper.
    @discardableResult
    static func resetStaleShots(projectId: String, store: ProjectStore = .shared) -> Int {
        var reset = 0
        store.update(id: projectId) { p in
            for si in p.scenes.indices {
                for shi in p.scenes[si].shots.indices {
                    let shot = p.scenes[si].shots[shi]
                    let stale = shot.status == .dispatched
                        || shot.status == .processing
                        || shot.status == .evaluating
                    let failed = shot.status == .failed
                    let blocked = shot.status == .skipped
                        && shot.errorMessage == blockedByUpstreamMessage
                    guard stale || failed || blocked else { continue }
                    p.scenes[si].shots[shi].status = .pending
                    p.scenes[si].shots[shi].startedAt = nil
                    p.scenes[si].shots[shi].completedAt = nil
                    p.scenes[si].shots[shi].errorMessage = nil
                    if failed { p.scenes[si].shots[shi].retryCount = 0 }
                    reset += 1
                }
            }
        }
        return reset
    }
}

// MARK: - Dry-run plan

/// What a project run *would* do, computed without submitting anything.
///
/// This exists because a run spends real money, per shot, on the user's own
/// provider credit. An agent that can start one must be able to see the bill
/// first — "just run it and find out" is not an answer for a 20-shot DAG.
///
/// Every number here comes from the same code the executor uses:
/// `DAGExecutor.plannedTarget` for the provider/model, `ProviderRouter`'s own
/// estimate or `ModelPricing.estimate` for the cost, and the same clamp
/// `executeFanoutShot` applies for the candidate count. A plan that quotes a
/// different model, or a different price, than the run dispatches would be
/// worse than no plan.
struct ProjectRunPlan {

    struct ShotPlan {
        let id: String
        let name: String
        let provider: String?
        let model: String?
        let durationSeconds: Double?
        /// Generations this shot bills — >1 for fanout and scatter-gather.
        let candidates: Int
        let estimatedCostUSD: Double
        let routingReason: String?
        /// Why this shot cannot run at all. Set means it is refused locally,
        /// before any provider call, so it costs nothing.
        let blockedReason: String?

        var jsonRepresentation: [String: Any] {
            var d: [String: Any] = [
                "shot_id": id,
                "name": name,
                "candidates": candidates,
                "estimated_cost_usd": (estimatedCostUSD * 10000).rounded() / 10000,
            ]
            if let provider { d["provider"] = provider }
            if let model { d["model"] = model }
            if let durationSeconds, durationSeconds.isFinite { d["duration_seconds"] = durationSeconds }
            if let routingReason { d["routing"] = routingReason }
            if let blockedReason { d["blocked_reason"] = blockedReason }
            return d
        }
    }

    let projectId: String
    let projectName: String
    /// Only the shots this run would attempt.
    let shots: [ShotPlan]
    let waveCount: Int
    let totalEstimatedCostUSD: Double
    /// Shots already terminal that this run will not touch.
    let alreadyDoneCount: Int
    /// Set when the graph itself is unrunnable.
    let graphError: String?
    let caveats: [String]

    var runnableShots: [ShotPlan] { shots.filter { $0.blockedReason == nil } }
    var blockedShots: [ShotPlan] { shots.filter { $0.blockedReason != nil } }
    var wouldSpend: Bool { !runnableShots.isEmpty }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "shots_to_run": runnableShots.count,
            "shots_blocked": blockedShots.count,
            "shots_already_terminal": alreadyDoneCount,
            "waves": waveCount,
            "estimated_cost_usd": (totalEstimatedCostUSD * 10000).rounded() / 10000,
            "estimated_cost_is_upper_bound": true,
            "shots": shots.map { $0.jsonRepresentation },
            "caveats": caveats,
        ]
        if let graphError { d["graph_error"] = graphError }
        return d
    }
}

/// Builds a `ProjectRunPlan`. Reads only: the provider catalog, the pricing
/// table, the local metrics store and the Keychain (to know which providers
/// have a key). It writes nothing, contacts nothing, and — importantly — does
/// **not** run the pre-generate hook, which has side effects and belongs to a
/// real submission.
enum ProjectRunPlanner {

    /// Whether this run will attempt the shot at all.
    ///
    /// `DAGResolver.readyShots` only ever dispatches `.pending`, so everything
    /// else is out of scope unless `resume` first resets it — which is exactly
    /// what `DAGExecutor.resetStaleShots` does.
    static func willRun(_ shot: Shot, resume: Bool) -> Bool {
        if shot.status == .pending { return true }
        guard resume else { return false }
        switch shot.status {
        case .failed, .dispatched, .processing, .evaluating:
            return true
        case .skipped:
            return shot.errorMessage == DAGExecutor.blockedByUpstreamMessage
        default:
            return false
        }
    }

    /// Generations one shot bills. Mirrors `executeFanoutShot`'s clamp and
    /// `executeScatterGather`'s target count.
    static func candidateCount(shot: Shot, settings: ProjectSettings) -> Int {
        if let fanout = shot.fanout, fanout > 1 {
            return max(1, min(fanout, WorkflowSpec.maxFanout))
        }
        if settings.routingStrategy == .scatterGather,
           let count = settings.scatterCount, count > 1 {
            return count
        }
        return 1
    }

    static func plan(project: Project, resume: Bool) -> ProjectRunPlan {
        let allShots = project.allShots
        let available = ProviderRouter.availableProviders()
        let catalog = ProviderRegistry.shared.allModels
        let registered = Set(ProviderRegistry.shared.all.map { $0.providerId })

        var waveCount = 0
        var graphError: String?
        do {
            waveCount = try DAGResolver.resolve(shots: allShots).count
        } catch {
            graphError = (error as? ProjectSpecError)?.errorDescription ?? error.localizedDescription
        }

        var plans: [ProjectRunPlan.ShotPlan] = []
        var total = 0.0
        var usedNominalDuration = false
        var usedScatter = false

        for shot in allShots where willRun(shot, resume: resume) {
            let target = DAGExecutor.plannedTarget(shot: shot, settings: project.settings,
                                                   availableProviders: available)
            guard let (providerID, modelID) = target.providerModel else {
                plans.append(.init(id: shot.id, name: shot.name, provider: nil, model: nil,
                                   durationSeconds: shot.duration, candidates: 0,
                                   estimatedCostUSD: 0, routingReason: nil,
                                   blockedReason: target.refusal))
                continue
            }
            var routingReason: String?
            if case .routed(let decision) = target { routingReason = decision.reason }

            let modelInfo = catalog.first { $0.providerId == providerID && $0.modelId == modelID }
            let blocked = localRefusal(shot: shot, providerID: providerID, modelID: modelID,
                                       modelInfo: modelInfo, registered: registered,
                                       available: available)

            let candidates = candidateCount(shot: shot, settings: project.settings)
            if candidates > 1, shot.fanout == nil { usedScatter = true }
            if shot.duration == nil { usedNominalDuration = true }

            var unit = 0.0
            if blocked == nil {
                if case .routed(let decision) = target,
                   let estimate = decision.estimatedCostUSD, estimate.isFinite, estimate >= 0 {
                    unit = estimate
                } else {
                    unit = ModelPricing.estimate(
                        durationSeconds: shot.duration ?? GenerationEngine.defaultBillableDurationSeconds,
                        modelId: modelID, providerId: providerID)
                }
            }
            let shotCost = unit * Double(candidates)
            total += shotCost

            plans.append(.init(id: shot.id, name: shot.name,
                               provider: providerID, model: modelID,
                               durationSeconds: shot.duration,
                               candidates: blocked == nil ? candidates : 0,
                               estimatedCostUSD: shotCost,
                               routingReason: routingReason,
                               blockedReason: blocked))
        }

        var caveats = [
            "Upper bound: every listed shot is counted as if it dispatches. A shot whose dependency fails is skipped and costs nothing.",
            "Prices come from OpenFlix's built-in table, not from the provider. The provider's own invoice is the authority.",
            "Per-shot retries (max_retries_per_shot = \(project.settings.maxRetriesPerShot)) are not multiplied in.",
        ]
        if usedNominalDuration {
            caveats.append("Shots with no explicit duration are priced at the nominal \(Int(GenerationEngine.defaultBillableDurationSeconds))s billable default; the provider bills its own default.")
        }
        if usedScatter {
            caveats.append("scatter_count is an upper bound — a shot may find fewer distinct provider targets than requested.")
        }

        return ProjectRunPlan(
            projectId: project.id,
            projectName: project.name,
            shots: plans,
            waveCount: waveCount,
            totalEstimatedCostUSD: total.isFinite ? total : 0,
            alreadyDoneCount: allShots.filter { !willRun($0, resume: resume) }.count,
            graphError: graphError,
            caveats: caveats)
    }

    /// The gates `GenerationEngine.submit` applies before it reaches a
    /// provider, replayed here without side effects, in the same order.
    ///
    /// Only the *free, local, deterministic* ones: unknown provider, missing
    /// key, reference-image scheme, duration, prompt safety. The pre-generate
    /// hook is deliberately not run — it is a user program with side effects,
    /// and a plan must not trip it. Nor is the budget gate, which is a live
    /// number reported separately alongside the plan.
    static func localRefusal(shot: Shot,
                             providerID: String,
                             modelID: String,
                             modelInfo: CLIProviderModel?,
                             registered: Set<String>,
                             available: [String]) -> String? {
        guard registered.contains(providerID) else {
            return "Unknown provider '\(providerID)'."
        }
        guard available.contains(providerID) else {
            return "No API key configured for '\(providerID)' — run `openflix keys set \(providerID)`."
        }
        do {
            let url = try GenerationEngine.parseReferenceImage(shot.referenceImageURL)
            try GenerationEngine.validateReferenceImage(url, providerID: providerID)
        } catch {
            return (error as? OpenFlixError)?.errorDescription ?? error.localizedDescription
        }
        do {
            try GenerationEngine.validateDuration(shot.duration, providerID: providerID,
                                                  model: modelID, modelInfo: modelInfo)
        } catch {
            return (error as? OpenFlixError)?.errorDescription ?? error.localizedDescription
        }
        let safety = PromptSafetyChecker.check(shot.prompt)
        if safety.level == .blocked {
            return "Prompt blocked by the local safety check (\(safety.flags.joined(separator: ", ")))."
        }
        return nil
    }
}
