import ArgumentParser
import Foundation

struct RecipeBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Run a recipe across multiple providers and compare results",
        discussion: """
        Benchmarks a recipe by generating videos with multiple providers,
        evaluating quality, and comparing cost/latency/quality.

        EXAMPLES
          openflix recipe benchmark <recipe-id> --providers fal,kling,luma --wait
          openflix recipe benchmark recipe.openflix --providers fal,kling --stream
        """
    )

    @Argument(help: "Recipe ID or path to .openflix file")
    var identifier: String

    @Option(name: .long, help: "Comma-separated provider IDs (default: all with API keys)")
    var providers: String?

    @Flag(name: .long, help: "Stream progress events")
    var stream: Bool = false

    @Option(name: .long, help: "Max seconds to wait per generation (default: 300)")
    var timeout: Double = 300

    @Option(name: .long, help: "Poll interval in seconds (default: 3)")
    var pollInterval: Double = 3

    @Option(name: .long, help: "Output directory for downloaded videos")
    var outputDir: String?

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Validate without submitting")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Publish benchmark results to registry")
    var publish: Bool = false

    @Option(name: .long, help: "Author name for published benchmark")
    var author: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // 1. Load recipe from store or .openflix file
        let recipe: CLIRecipe
        if identifier.hasSuffix(".openflix") || identifier.contains("/") {
            // Try loading as file path
            let path = (identifier as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Output.failMessage("Recipe file not found: \(identifier)", code: "file_not_found")
            }
            do {
                let bundle = try RecipeBundle.decode(fromFile: url)
                guard let first = bundle.recipes.first else {
                    Output.failMessage("Recipe file contains no recipes", code: "invalid_input")
                }
                recipe = CLIRecipe(from: first)
            } catch {
                Output.failMessage("Failed to parse recipe file: \(error.localizedDescription)", code: "invalid_input")
            }
        } else {
            // Try loading from store by ID
            guard let stored = RecipeStore.shared.get(identifier) else {
                Output.failMessage("Recipe '\(identifier)' not found in store", code: "not_found")
            }
            recipe = stored
        }

        // 2. Determine target providers
        let targetProviderIDs: [String]
        if let provStr = providers {
            targetProviderIDs = provStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            // Validate all provider IDs exist
            for pid in targetProviderIDs {
                guard (try? ProviderRegistry.shared.provider(for: pid)) != nil else {
                    Output.failMessage("Provider '\(pid)' not found. Run: openflix providers", code: "provider_not_found")
                }
            }
        } else {
            targetProviderIDs = ProviderRouter.availableProviders()
            if targetProviderIDs.isEmpty {
                Output.failMessage("No providers with configured API keys. Run: openflix keys set <provider> <key>", code: "no_api_key")
            }
        }

        // 3. For each provider, pick the first/default model
        let registry = ProviderRegistry.shared
        var targets: [(provider: String, model: String, modelInfo: CLIProviderModel)] = []
        for pid in targetProviderIDs {
            guard let prov = try? registry.provider(for: pid) else { continue }
            guard let firstModel = prov.models.first else { continue }
            targets.append((provider: pid, model: firstModel.modelId, modelInfo: firstModel))
        }

        guard !targets.isEmpty else {
            Output.failMessage("No valid provider/model targets found", code: "invalid_input")
        }

        // 4. Dry run
        if dryRun {
            let targetDicts: [[String: Any]] = targets.map { t in
                var d: [String: Any] = [
                    "provider": t.provider,
                    "model": t.model,
                    "display_name": t.modelInfo.displayName,
                ]
                if let cps = t.modelInfo.costPerSecondUSD {
                    let dur = recipe.durationSeconds ?? 5.0
                    d["estimated_cost_usd"] = (cps * dur * 10000).rounded() / 10000
                }
                return d
            }
            Output.emitDict([
                "dry_run": true,
                "recipe_id": recipe.id,
                "recipe_name": recipe.name,
                "prompt": recipe.promptText,
                "targets": targetDicts,
                "target_count": targets.count,
            ])
            return
        }

        // 5. Run benchmark for each provider+model
        var results: [[String: Any]] = []
        let benchmarkStartedAt = Date()

        for target in targets {
            if stream {
                Output.emitEvent([
                    "event": "benchmark_start",
                    "provider": target.provider,
                    "model": target.model,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ])
            }

            let startTime = Date()
            do {
                // Build output URL if outputDir specified
                var outputURL: URL?
                if let dir = outputDir {
                    let dirPath = (dir as NSString).expandingTildeInPath
                    try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
                    let filename = "\(recipe.name.replacingOccurrences(of: " ", with: "_"))_\(target.provider).mp4"
                    outputURL = URL(fileURLWithPath: dirPath).appendingPathComponent(filename)
                }

                let opts = GenerationEngine.Options(
                    pollInterval: pollInterval,
                    timeout: timeout,
                    outputURL: outputURL,
                    stream: stream,
                    skipDownload: false,
                    maxRetries: 0
                )

                // Parse extra params from recipe
                var extras: [String: Any] = [:]
                if let json = recipe.parametersJSON, let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    extras = dict
                }

                let gen = try await GenerationEngine.submitAndWait(
                    prompt: recipe.promptText,
                    negativePrompt: recipe.negativePromptText.isEmpty ? nil : recipe.negativePromptText,
                    provider: target.provider,
                    model: target.model,
                    durationSeconds: recipe.durationSeconds,
                    aspectRatio: recipe.aspectRatio,
                    width: recipe.widthPx,
                    height: recipe.heightPx,
                    extraParams: extras,
                    apiKey: apiKey,
                    options: opts
                )

                let endTime = Date()
                let latencySeconds = endTime.timeIntervalSince(startTime)

                // Run heuristic quality evaluation if video exists
                var qualityScore: Double?
                if let localPath = gen.localPath, FileManager.default.fileExists(atPath: localPath) {
                    var config = QualityConfig()
                    config.enabled = true
                    config.evaluator = .heuristic
                    if let evalResult = try? await QualityGate.evaluate(
                        generation: gen, videoPath: localPath, shot: nil, config: config
                    ) {
                        qualityScore = evalResult.score
                    }
                }

                var resultDict: [String: Any] = [
                    "provider": target.provider,
                    "model": target.model,
                    "status": gen.status.rawValue,
                    "latency_seconds": (latencySeconds * 10).rounded() / 10,
                    "generation_id": gen.id,
                ]
                if let cost = gen.actualCostUSD ?? gen.estimatedCostUSD {
                    resultDict["cost_usd"] = (cost * 10000).rounded() / 10000
                }
                if let qs = qualityScore {
                    resultDict["quality_score"] = (qs * 10).rounded() / 10
                }
                if let lp = gen.localPath {
                    resultDict["local_path"] = lp
                }

                results.append(resultDict)

                if stream {
                    Output.emitEvent([
                        "event": "benchmark_complete",
                        "provider": target.provider,
                        "model": target.model,
                        "status": "succeeded",
                        "latency_seconds": (latencySeconds * 10).rounded() / 10,
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                    ])
                }

            } catch {
                // Record failure but continue with other providers
                let endTime = Date()
                let latencySeconds = endTime.timeIntervalSince(startTime)
                let errorMsg: String
                if let e = error as? OpenFlixError {
                    errorMsg = e.errorDescription ?? e.code
                } else {
                    errorMsg = error.localizedDescription
                }

                results.append([
                    "provider": target.provider,
                    "model": target.model,
                    "status": "failed",
                    "error": errorMsg,
                    "latency_seconds": (latencySeconds * 10).rounded() / 10,
                ])

                if stream {
                    Output.emitEvent([
                        "event": "benchmark_failed",
                        "provider": target.provider,
                        "model": target.model,
                        "error": errorMsg,
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                    ])
                }
            }
        }

        // 6. Determine winner (highest quality score among succeeded)
        let succeeded = results.filter { ($0["status"] as? String) == "succeeded" }
        var winner: [String: Any]?
        if !succeeded.isEmpty {
            // Prefer quality score, then cheapest cost, then fastest
            let sorted = succeeded.sorted { a, b in
                let qa = a["quality_score"] as? Double ?? 0
                let qb = b["quality_score"] as? Double ?? 0
                if qa != qb { return qa > qb }
                let ca = a["cost_usd"] as? Double ?? Double.greatestFiniteMagnitude
                let cb = b["cost_usd"] as? Double ?? Double.greatestFiniteMagnitude
                if ca != cb { return ca < cb }
                let la = a["latency_seconds"] as? Double ?? Double.greatestFiniteMagnitude
                let lb = b["latency_seconds"] as? Double ?? Double.greatestFiniteMagnitude
                return la < lb
            }
            if let best = sorted.first {
                let qs = best["quality_score"] as? Double
                let reason: String
                if let q = qs {
                    reason = "Highest quality (\(q))"
                } else {
                    let cost = best["cost_usd"] as? Double
                    if let c = cost {
                        reason = "Lowest cost ($\(c))"
                    } else {
                        reason = "Fastest completion"
                    }
                }
                winner = [
                    "provider": best["provider"] as Any,
                    "model": best["model"] as Any,
                    "reason": reason,
                ]
            }
        }

        // 7. Build and emit output
        var output: [String: Any] = [
            "recipe_id": recipe.id,
            "recipe_name": recipe.name,
            "prompt": recipe.promptText,
            "results": results,
            "benchmarked_at": ISO8601DateFormatter().string(from: benchmarkStartedAt),
        ]
        if let w = winner {
            output["winner"] = w
        }

        if publish {
            do {
                let (benchmarkId, benchmarkUrl) = try await RegistryClient.publishBenchmark(
                    results: output, author: author
                )
                output["benchmark_id"] = benchmarkId
                output["benchmark_url"] = benchmarkUrl
            } catch {
                output["publish_error"] = error.localizedDescription
            }
        }

        Output.emitDict(output)
    }
}
