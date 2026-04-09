import Foundation

// MARK: - DAG Resolution

struct DAGResolver {

    /// Topological sort with cycle detection (Kahn's algorithm).
    /// Returns shots grouped by parallelism level ("waves").
    static func resolve(shots: [Shot]) throws -> [[Shot]] {
        let shotMap = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]  // id → IDs that depend on it

        for shot in shots {
            inDegree[shot.id] = shot.dependencies.count
            for dep in shot.dependencies {
                dependents[dep, default: []].append(shot.id)
            }
        }

        var waves: [[Shot]] = []
        var queue = shots.filter { inDegree[$0.id, default: 0] == 0 }
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

    init(
        projectId: String,
        store: ProjectStore = .shared,
        maxConcurrency: Int = 4,
        stream: Bool = false,
        apiKey: String? = nil,
        skipDownload: Bool = false,
        timeout: Double = 600,
        maxRetriesPerShot: Int = 2,
        qualityConfig: QualityConfig = QualityConfig()
    ) {
        self.projectId = projectId
        self.store = store
        self.maxConcurrency = maxConcurrency
        self.stream = stream
        self.apiKey = apiKey
        self.skipDownload = skipDownload
        self.timeout = timeout
        self.maxRetriesPerShot = maxRetriesPerShot
        self.qualityConfig = qualityConfig
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
        let total = allShots.count

        let totalCost = allShots.compactMap { $0.actualCostUSD }.reduce(0, +)

        if cancelled {
            finalProject.status = .cancelled
        } else if succeeded == total {
            finalProject.status = .succeeded
        } else if failed > 0 && succeeded > 0 {
            finalProject.status = .partialFailure
        } else if failed == total {
            finalProject.status = .failed
        } else {
            finalProject.status = .succeeded
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

        // Scatter-gather or single dispatch
        let maxRetries = shot.maxRetries ?? maxRetriesPerShot

        if project.settings.routingStrategy == .scatterGather,
           let count = project.settings.scatterCount, count > 1 {
            await executeScatterGather(shot: shot, count: count, providerID: providerID, modelID: modelID)
        } else {
            await executeSingleShot(shot: shot, providerID: providerID, modelID: modelID, maxRetries: maxRetries)
        }
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
        cancelled = true
        store.update(id: projectId) { $0.status = .paused }
    }

    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
