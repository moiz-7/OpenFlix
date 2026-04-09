import Foundation

// MARK: - Video Evaluator Protocol

protocol VideoEvaluator {
    var evaluatorId: String { get }
    func evaluate(generation: CLIGeneration, videoPath: String, shot: Shot?, config: QualityConfig) async throws -> EvaluationResult
}

// MARK: - Evaluation Result

struct EvaluationResult: Codable {
    var score: Double           // 0-100
    var passed: Bool
    var reasoning: String
    var evaluator: String
    var dimensions: [String: Double]
    var evaluatedAt: Date

    var jsonRepresentation: [String: Any] {
        let d: [String: Any] = [
            "score": score,
            "passed": passed,
            "reasoning": reasoning,
            "evaluator": evaluator,
            "dimensions": dimensions,
            "evaluated_at": ISO8601DateFormatter().string(from: evaluatedAt),
        ]
        return d
    }
}

// MARK: - Quality Config

struct QualityConfig: Codable {
    var enabled: Bool = false
    var evaluator: EvaluatorType = .heuristic
    var threshold: Double = 60.0
    var maxRetries: Int = 1
    var claudeApiKey: String?
    var claudeModel: String = "claude-sonnet-4-20250514"
    var maxFrames: Int = 4

    enum EvaluatorType: String, Codable, CaseIterable {
        case heuristic
        case llmVision = "llm-vision"
    }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "enabled": enabled,
            "evaluator": evaluator.rawValue,
            "threshold": threshold,
            "max_retries": maxRetries,
            "claude_model": claudeModel,
            "max_frames": maxFrames,
        ]
        if claudeApiKey != nil { d["claude_api_key"] = "***" }
        return d
    }
}
