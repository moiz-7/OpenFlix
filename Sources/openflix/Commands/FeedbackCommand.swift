import ArgumentParser
import Foundation

struct Feedback: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "feedback",
        abstract: "Record quality feedback for a generation",
        discussion: """
        Records a user-provided quality score for a generation.
        This feeds the provider metrics system for smarter routing.

        EXAMPLES
          openflix feedback <generation-id> --score 85
          openflix feedback <generation-id> --score 30 --reason "Artifacts and wrong subject"
        """
    )

    @Argument(help: "Generation ID to provide feedback for")
    var generationId: String

    @Option(name: .long, help: "Quality score 0-100")
    var score: Double

    @Option(name: .long, help: "Optional reason for the score")
    var reason: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard score >= 0 && score <= 100 else {
            Output.failMessage("Score must be between 0 and 100 (got: \(score))", code: "invalid_input")
        }

        guard let gen = GenerationStore.shared.get(generationId) else {
            Output.failMessage("Generation '\(generationId)' not found", code: "not_found")
        }

        ProviderMetricsStore.shared.recordFeedback(
            provider: gen.provider,
            model: gen.model,
            score: score
        )

        var result: [String: Any] = [
            "generation_id": generationId,
            "provider": gen.provider,
            "model": gen.model,
            "score": score,
            "recorded": true,
        ]
        if let r = reason { result["reason"] = r }

        Output.emitDict(result)
    }
}
