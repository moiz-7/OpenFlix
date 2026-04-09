import Foundation

/// Orchestrates quality evaluation: calls evaluator, records metrics, returns decision.
struct QualityGate {

    /// Returns the appropriate evaluator for a config.
    static func evaluator(for config: QualityConfig) -> VideoEvaluator {
        switch config.evaluator {
        case .heuristic: return HeuristicEvaluator()
        case .llmVision: return LLMVisionEvaluator()
        }
    }

    /// Evaluate a generation's output video.
    static func evaluate(
        generation: CLIGeneration,
        videoPath: String,
        shot: Shot?,
        config: QualityConfig
    ) async throws -> EvaluationResult {
        let eval = evaluator(for: config)
        let result = try await eval.evaluate(
            generation: generation,
            videoPath: videoPath,
            shot: shot,
            config: config
        )

        // Record quality metrics
        ProviderMetricsStore.shared.recordQuality(
            provider: generation.provider,
            model: generation.model,
            score: result.score
        )

        return result
    }

    /// High-level check: evaluate → decide pass/retry/accept.
    /// Evaluation failure = pass through (don't block generation).
    static func check(
        generation: CLIGeneration,
        videoPath: String,
        shot: Shot?,
        config: QualityConfig
    ) async -> (passed: Bool, result: EvaluationResult?, shouldRetry: Bool) {
        do {
            let result = try await evaluate(
                generation: generation,
                videoPath: videoPath,
                shot: shot,
                config: config
            )

            if result.passed {
                return (passed: true, result: result, shouldRetry: false)
            }

            // Check if retries are available
            let currentRetries = shot?.qualityRetryCount ?? 0
            let shouldRetry = currentRetries < config.maxRetries

            return (passed: false, result: result, shouldRetry: shouldRetry)
        } catch {
            // Evaluation failure = pass through
            fputs("{\"warning\":\"Quality evaluation failed: \(error.localizedDescription)\",\"code\":\"eval_error\"}\n", stderr)
            return (passed: true, result: nil, shouldRetry: false)
        }
    }
}
