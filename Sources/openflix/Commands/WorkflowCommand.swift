import ArgumentParser
import Foundation

// MARK: - workflow group

struct WorkflowGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Run declarative multi-stage generation pipelines",
        subcommands: [WorkflowRun.self]
    )
}

// MARK: - workflow run

struct WorkflowRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Execute a workflow file (JSON pipeline over the DAG engine)",
        discussion: """
        Executes a declarative pipeline: stages with DAG edges (needs),
        optional fanout (N candidates via scatter-gather), and an optional
        judge (keep top K by quality score). Runs on the existing DAG
        executor; every run writes a journal to ~/.openflix/runs/<run-id>.json.

        FORMAT (v1, JSON — "JSON now, YAML later"; see docs/workflows-engine.md)
          {
            "name": "my-film",
            "budget_usd": 5.0,
            "stages": [
              {"id": "wide", "prompt": "...", "provider": "fal", "model": "fal-ai/veo3",
               "duration": 5, "fanout": 4, "judge": {"keep": 1, "min_score": 60}},
              {"id": "close", "needs": ["wide"], "prompt_from": "wide", "route": "smart"}
            ]
          }

        EXAMPLES
          openflix workflow run film.json --dry-run
          openflix workflow run film.json --max-spend 2.50 --yes --stream
          openflix workflow run film.json --resume <run-id>
        """
    )

    @Argument(help: "Workflow file path (.json)")
    var file: String

    @Flag(name: .long, help: "Print the resolved plan (stages, fanout, est. cost) without generating")
    var dryRun: Bool = false

    @Option(name: .long, help: "Resume a previous run: completed nodes with unchanged inputs are skipped")
    var resume: String?

    @Option(name: .long, help: "Budget approval threshold in USD (overrides budget_usd in the file)")
    var maxSpend: Double?

    @Flag(name: .long, help: "Approve the run even if the estimate exceeds the budget threshold")
    var yes: Bool = false

    @Option(name: .long, help: "Max parallel stages (default: 4)")
    var concurrency: Int = 4

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events")
    var stream: Bool = false

    @Flag(name: .long, help: "Skip downloading videos after generation")
    var skipDownload: Bool = false

    @Option(name: .long, help: "Timeout per stage in seconds (default: 600)")
    var timeout: Double = 600

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // 1. Parse + validate
        let path = (file as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            Output.failMessage("Workflow file not found: \(path)", code: "file_not_found")
        }
        var spec: WorkflowSpec
        let prompts: [String: String]
        do {
            spec = try WorkflowParser.parse(data: data, path: path)
            // Composition: inline recipe-backed stages from the local store,
            // applying declared args with stage-provided values.
            for i in spec.stages.indices where spec.stages[i].recipe != nil {
                let recipe = spec.stages[i].recipe.flatMap { RecipeStore.shared.get($0) }
                spec.stages[i] = try WorkflowRecipeResolver.inline(stage: spec.stages[i], recipe: recipe)
            }
            prompts = try WorkflowParser.resolvedPrompts(spec)
        } catch let e as WorkflowSpecError {
            Output.failMessage(e.errorDescription ?? "invalid workflow", code: e.code)
        } catch let e as RecipeArgError {
            Output.failMessage(e.errorDescription ?? "invalid recipe arg", code: e.code)
        }

        // 2. Resolve plan (provider/model per stage + up-front cost estimate)
        var resolved: [ResolvedStage] = []
        for stage in spec.stages {
            let provider: String
            let model: String
            var routing: [String: Any]?
            if let p = stage.provider, let m = stage.model {
                provider = p
                model = m
            } else {
                // route: smart — reuse the preference router
                do {
                    let decision = try await PreferenceRouter.decide(
                        category: stage.category,
                        needsImageToVideo: false,
                        duration: stage.duration
                    )
                    provider = decision.provider
                    model = decision.model
                    routing = decision.json
                } catch let e as OpenFlixError {
                    Output.fail(e)
                }
            }
            let fanout = stage.fanout ?? 1
            let cps = ProviderRegistry.shared.allModels
                .first { $0.providerId == provider && $0.modelId == model }?
                .costPerSecondUSD
            let est = WorkflowCost.estimate(costPerSecondUSD: cps, duration: stage.duration, fanout: fanout)
            resolved.append(ResolvedStage(
                stage: stage, prompt: prompts[stage.id] ?? "",
                provider: provider, model: model,
                fanout: fanout, estCostUSD: est, routing: routing
            ))
        }
        let totalEstimate = resolved.compactMap { $0.estCostUSD }.reduce(0, +)

        // 3. Dry run: print the resolved plan, generate nothing
        if dryRun {
            var dict: [String: Any] = [
                "dry_run": true,
                "name": spec.name,
                "stages": resolved.map { $0.planJSON },
                "total_estimated_cost_usd": round4(totalEstimate),
                "total_candidates": resolved.reduce(0) { $0 + $1.fanout },
            ]
            if let limit = maxSpend ?? spec.budgetUsd {
                dict["budget_limit_usd"] = limit
                dict["budget_approval_required"] = totalEstimate > limit && !yes
            }
            Output.emitDict(dict)
            return
        }

        // 4. Budget approval gate (up-front estimate vs --max-spend/budget_usd)
        let limit = maxSpend ?? spec.budgetUsd
        if case .approvalRequired(let est, let lim) = WorkflowBudgetGate.check(
            estimatedTotalUSD: totalEstimate, limitUSD: limit, approved: yes
        ) {
            Output.failMessage(
                "Estimated cost $\(String(format: "%.4f", est)) exceeds budget $\(String(format: "%.4f", lim)). Re-run with --yes to approve.",
                code: "budget_approval_required"
            )
        }
        // Reuse BudgetManager's pre-flight (daily/monthly/per-gen limits).
        if totalEstimate > 0 {
            let check = await BudgetManager.shared.preFlightCheck(estimatedCost: totalEstimate)
            if case .denied(let reason) = check {
                Output.fail(.budgetExceeded(reason))
            }
        }

        // 5. Resume: load prior journal (unknown run-id is an error)
        let journal = RunJournal()
        var priorRecord: RunRecord?
        if let resumeId = resume {
            guard let record = journal.load(runId: resumeId) else {
                Output.failMessage("Run '\(resumeId)' not found in ~/.openflix/runs", code: "run_not_found")
            }
            priorRecord = record
        }
        let runId = resume ?? UUID().uuidString

        // 6. Build a project from the workflow (stages → shots) and reuse
        //    the existing DAG executor.
        let projectSpec = buildProjectSpec(spec: spec, resolved: resolved)
        let project: Project
        do { project = try ProjectStore.createFromSpec(projectSpec) }
        catch let e as ProjectSpecError {
            Output.failMessage(e.errorDescription ?? "invalid workflow", code: e.code)
        }
        ProjectStore.shared.save(project)

        // Attach fanout/judge and compute inputs hashes per stage.
        var nodeHashes: [String: String] = [:]
        var skipped = 0
        var initialNodes: [String: NodeRecord] = [:]
        for r in resolved {
            let hash = r.inputsHash
            nodeHashes[r.stage.id] = hash
            ProjectStore.shared.update(id: project.id) { p in
                for si in p.scenes.indices {
                    for shi in p.scenes[si].shots.indices where p.scenes[si].shots[shi].name == r.stage.id {
                        p.scenes[si].shots[shi].fanout = r.fanout > 1 ? r.fanout : nil
                        p.scenes[si].shots[shi].judge = r.stage.judge
                    }
                }
            }
            // Resume decision: skip completed nodes whose inputs are unchanged.
            let prior = priorRecord?.nodes[r.stage.id]
            if ResumePolicy.shouldSkip(prior: prior, currentHash: hash), let prior {
                skipped += 1
                ProjectStore.shared.update(id: project.id) { p in
                    for si in p.scenes.indices {
                        for shi in p.scenes[si].shots.indices where p.scenes[si].shots[shi].name == r.stage.id {
                            p.scenes[si].shots[shi].status = .skipped
                            p.scenes[si].shots[shi].selectedGenerationId = prior.generationId
                            p.scenes[si].shots[shi].actualCostUSD = prior.costUSD
                            if let g = prior.generationId {
                                p.scenes[si].shots[shi].generationIds = [g]
                            }
                            p.scenes[si].shots[shi].completedAt = prior.completedAt
                        }
                    }
                }
                initialNodes[r.stage.id] = NodeRecord(
                    nodeId: r.stage.id, inputsHash: hash, status: "skipped",
                    generationId: prior.generationId, outputPath: prior.outputPath,
                    costUSD: prior.costUSD, startedAt: prior.startedAt, completedAt: prior.completedAt
                )
            } else {
                initialNodes[r.stage.id] = NodeRecord(
                    nodeId: r.stage.id, inputsHash: hash, status: "pending",
                    generationId: nil, outputPath: nil, costUSD: nil,
                    startedAt: nil, completedAt: nil
                )
            }
        }
        _ = journal.create(runId: runId, kind: "workflow", name: spec.name,
                           projectId: project.id, nodes: initialNodes)

        // 7. Execute via the existing DAG executor with the journal attached.
        let executor = DAGExecutor(
            projectId: project.id,
            maxConcurrency: concurrency,
            stream: stream,
            apiKey: apiKey,
            skipDownload: skipDownload,
            timeout: timeout,
            journal: journal,
            runId: runId,
            nodeHashes: nodeHashes
        )

        do {
            let result = try await executor.execute()
            var out = result.jsonRepresentation
            out["run_id"] = runId
            out["workflow"] = spec.name
            out["resumed"] = [
                "skipped": skipped,
                "executed": resolved.count - skipped,
            ]
            out["total_estimated_cost_usd"] = round4(totalEstimate)
            Output.emitDict(out)
        } catch let error as OpenFlixError {
            Output.fail(error)
        } catch let error as ProjectSpecError {
            Output.failMessage(error.errorDescription ?? error.localizedDescription, code: error.code)
        } catch {
            Output.failMessage(error.localizedDescription, code: "run_failed")
        }
    }

    // MARK: - Helpers

    private func buildProjectSpec(spec: WorkflowSpec, resolved: [ResolvedStage]) -> ProjectSpec {
        let shots = resolved.map { r in
            ProjectSpec.ProjectSpecShot(
                name: r.stage.id,
                prompt: r.prompt,
                negativePrompt: r.stage.negativePrompt,
                provider: r.provider,
                model: r.model,
                duration: r.stage.duration,
                aspectRatio: r.stage.aspectRatio,
                width: nil,
                height: nil,
                referenceImageUrl: nil,
                referenceAssetName: nil,
                extraParams: r.stage.params,
                dependencies: r.stage.needs,
                orderIndex: nil,
                maxRetries: nil
            )
        }
        return ProjectSpec(
            name: spec.name,
            description: "workflow run",
            settings: ProjectSpec.ProjectSpecSettings(
                defaultProvider: nil, defaultModel: nil,
                defaultAspectRatio: nil, defaultDuration: nil,
                maxConcurrency: concurrency, maxRetriesPerShot: nil,
                timeoutPerShot: timeout, scatterCount: nil,
                routingStrategy: "manual", costBudgetUsd: spec.budgetUsd,
                qualityEnabled: nil, qualityEvaluator: nil,
                qualityThreshold: nil, qualityMaxRetries: nil
            ),
            scenes: [ProjectSpec.ProjectSpecScene(
                name: "stages", description: nil, orderIndex: 0,
                referenceAssets: nil, shots: shots
            )]
        )
    }

    private func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}

// MARK: - Resolved stage (plan entry)

struct ResolvedStage {
    let stage: WorkflowStage
    let prompt: String
    let provider: String
    let model: String
    let fanout: Int
    let estCostUSD: Double?
    let routing: [String: Any]?

    /// Stable inputs hash for resume decisions. Raw route fields are hashed
    /// (not the smart-routing resolution) so a smart stage does not re-execute
    /// merely because preference data shifted; the resolved prompt IS hashed
    /// so prompt_from chains invalidate downstream stages when upstream
    /// prompts change.
    var inputsHash: String {
        var spec: [String: Any] = [
            "prompt": prompt,
            "needs": (stage.needs ?? []).sorted(),
            "fanout": fanout,
        ]
        if let v = stage.provider       { spec["provider"] = v }
        if let v = stage.model          { spec["model"] = v }
        if let v = stage.recipe         { spec["recipe"] = v }
        if let v = stage.args           { spec["recipe_args"] = v }
        if let v = stage.route          { spec["route"] = v }
        if let v = stage.category       { spec["category"] = v }
        if let v = stage.duration       { spec["duration"] = v }
        if let v = stage.aspectRatio    { spec["aspect_ratio"] = v }
        if let v = stage.negativePrompt { spec["negative_prompt"] = v }
        if let v = stage.params         { spec["params"] = v }
        if let j = stage.judge {
            var jd: [String: Any] = ["keep": j.keep]
            if let m = j.minScore { jd["min_score"] = m }
            spec["judge"] = jd
        }
        return RunJournal.inputsHash(spec)
    }

    var planJSON: [String: Any] {
        var d: [String: Any] = [
            "id": stage.id,
            "provider": provider,
            "model": model,
            "prompt": prompt,
            "fanout": fanout,
            "needs": stage.needs ?? [],
        ]
        if let v = stage.recipe { d["recipe"] = v }
        if let v = stage.duration { d["duration"] = v }
        if let v = estCostUSD { d["estimated_cost_usd"] = (v * 10000).rounded() / 10000 }
        if let j = stage.judge {
            var jd: [String: Any] = ["keep": j.keep, "note": "judging skipped in dry-run"]
            if let m = j.minScore { jd["min_score"] = m }
            d["judge"] = jd
        }
        if let r = routing { d["routing"] = r }
        return d
    }
}
