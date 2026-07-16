import Foundation

struct ScatterResult: Codable {
    var generationId: String
    var provider: String
    var model: String
    var status: String
    var videoURL: String?
    var costUSD: Double?
    var durationMs: Int?
    var errorMessage: String?
    var qualityScore: Double?
    var evaluationResult: EvaluationResult?
}

struct ScatterGatherExecutor {

    /// Upper bound on simultaneous provider submissions per scatter/fanout, so a
    /// user-supplied `fanout: 200` (or a wide scatter) can't fire 200 concurrent
    /// HTTP requests and trigger rate-limit storms / socket exhaustion. Shots in
    /// flight already multiply this by the DAG's maxConcurrency.
    static let maxConcurrentScatter = 8

    /// Send same shot to N providers in parallel (windowed), return all results.
    static func scatter(
        shot: Shot,
        targets: [(provider: String, model: String)],
        apiKey: String?,
        options: GenerationEngine.Options
    ) async -> [ScatterResult] {
        let imageURL = shot.referenceImageURL.flatMap { URL(string: $0) }
        let window = max(1, min(maxConcurrentScatter, targets.count))

        return await withTaskGroup(of: ScatterResult.self) { group in
            var next = 0
            // Prime the window, then refill one task per completion so at most
            // `window` submissions are ever in flight at once.
            while next < window {
                let target = targets[next]; next += 1
                group.addTask { await runTarget(shot: shot, target: target, imageURL: imageURL, apiKey: apiKey, options: options) }
            }

            var results: [ScatterResult] = []
            for await result in group {
                results.append(result)
                if next < targets.count {
                    let target = targets[next]; next += 1
                    group.addTask { await runTarget(shot: shot, target: target, imageURL: imageURL, apiKey: apiKey, options: options) }
                }
            }
            return results
        }
    }

    /// One provider submission — the unit of work windowed by `scatter`.
    private static func runTarget(
        shot: Shot,
        target: (provider: String, model: String),
        imageURL: URL?,
        apiKey: String?,
        options: GenerationEngine.Options
    ) async -> ScatterResult {
        let start = Date()
        do {
            let gen = try await GenerationEngine.submitAndWait(
                prompt: shot.prompt,
                negativePrompt: shot.negativePrompt,
                provider: target.provider,
                model: target.model,
                durationSeconds: shot.duration,
                aspectRatio: shot.aspectRatio,
                width: shot.width,
                height: shot.height,
                referenceImageURL: imageURL,
                extraParams: shot.extraParams.reduce(into: [:]) { $0[$1.key] = $1.value as Any },
                apiKey: apiKey,
                options: options
            )
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return ScatterResult(
                generationId: gen.id,
                provider: target.provider,
                model: target.model,
                status: gen.status.rawValue,
                videoURL: gen.remoteVideoURL,
                costUSD: gen.actualCostUSD,
                durationMs: elapsed,
                errorMessage: nil
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let msg = (error as? OpenFlixError)?.errorDescription ?? error.localizedDescription
            return ScatterResult(
                generationId: "",
                provider: target.provider,
                model: target.model,
                status: "failed",
                videoURL: nil,
                costUSD: nil,
                durationMs: elapsed,
                errorMessage: msg
            )
        }
    }

    /// Pick the best result from scatter results (first succeeded).
    static func selectBest(_ results: [ScatterResult]) -> ScatterResult? {
        results.first { $0.status == "succeeded" }
    }

    /// Quality-aware selection: evaluate all succeeded results, pick highest score.
    static func selectBest(_ results: [ScatterResult], qualityConfig: QualityConfig) async -> ScatterResult? {
        let succeeded = results.filter { $0.status == "succeeded" }
        guard !succeeded.isEmpty else { return nil }

        var evaluated: [ScatterResult] = []
        for var result in succeeded {
            guard let genId = result.generationId.isEmpty ? nil : result.generationId,
                  let gen = GenerationStore.shared.get(genId),
                  let videoPath = gen.localPath else {
                evaluated.append(result)
                continue
            }

            do {
                let evalResult = try await QualityGate.evaluate(
                    generation: gen, videoPath: videoPath, shot: nil, config: qualityConfig
                )
                result.qualityScore = evalResult.score
                result.evaluationResult = evalResult
            } catch {
                // Evaluation failed — keep result without score
            }
            evaluated.append(result)
        }

        // Pick highest quality score; fall back to first succeeded
        let scored = evaluated.filter { $0.qualityScore != nil }
        if let best = scored.max(by: { ($0.qualityScore ?? 0) < ($1.qualityScore ?? 0) }) {
            return best
        }
        return evaluated.first
    }
}
