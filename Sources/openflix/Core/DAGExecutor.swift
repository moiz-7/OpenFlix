import Foundation

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
        referenceEdges: [String: String] = [:]
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
                        p.scenes[si].shots[shi].errorMessage = "Blocked by upstream failure"
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

        // Resolve provider/model
        let providerID: String
        let modelID: String

        if let p = shot.provider, let m = shot.model {
            providerID = p
            modelID = m
        } else if project.settings.routingStrategy != .manual {
            do {
                let available = ProviderRouter.availableProviders()
                let decision = try ProviderRouter.route(
                    shot: shot, strategy: project.settings.routingStrategy,
                    availableProviders: available
                )
                providerID = decision.provider
                modelID = decision.model
                store.updateShot(projectId: projectId, shotId: shot.id) { s in
                    s.provider = decision.provider
                    s.model = decision.model
                    s.routingDecision = decision.reason
                    s.estimatedCostUSD = decision.estimatedCostUSD
                }
            } catch {
                markShotFailed(shot.id, error: "Routing failed: \(error.localizedDescription)")
                return
            }
        } else if let p = project.settings.defaultProvider, let m = project.settings.defaultModel {
            providerID = p
            modelID = m
        } else {
            markShotFailed(shot.id, error: "No provider/model specified and no routing strategy configured")
            return
        }

        // Check cost budget
        if let budget = project.costBudgetUSD {
            let currentCost = store.get(projectId)?.allShots
                .compactMap { $0.actualCostUSD }.reduce(0, +) ?? 0
            if currentCost >= budget {
                markShotFailed(shot.id, error: "Cost budget exceeded (\(currentCost) >= \(budget) USD)")
                return
            }
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
    private func executeFanoutShot(shot: Shot, count: Int, providerID: String, modelID: String) async {
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

        let imageURL = shot.referenceImageURL.flatMap { URL(string: $0) }

        do {
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
