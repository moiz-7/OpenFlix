import ArgumentParser
import Foundation

struct Evaluate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "evaluate",
        abstract: "Evaluate the quality of a generated video",
        discussion: """
        Runs quality evaluation on a succeeded generation's output video.
        Uses heuristic (file + ffprobe) or LLM vision (Claude API) evaluator.

        EXAMPLES
          vortex evaluate <generation-id>
          vortex evaluate <generation-id> --evaluator llm-vision --claude-api-key KEY
          vortex evaluate <generation-id> --threshold 80
        """
    )

    @Argument(help: "Generation ID to evaluate")
    var generationId: String

    @Option(name: .long, help: "Evaluator type: heuristic or llm-vision (default: heuristic)")
    var evaluator: String?

    @Option(name: .long, help: "Quality threshold 0-100 (default: 60)")
    var threshold: Double?

    @Option(name: .long, help: "Claude API key for llm-vision evaluator")
    var claudeApiKey: String?

    @Option(name: .long, help: "Claude model for llm-vision evaluator")
    var claudeModel: String?

    @Option(name: .long, help: "Max frames to extract for llm-vision (default: 4)")
    var maxFrames: Int?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let gen = GenerationStore.shared.get(generationId) else {
            Output.failMessage("Generation '\(generationId)' not found", code: "not_found")
        }

        guard gen.status == .succeeded else {
            Output.failMessage("Generation '\(generationId)' has status '\(gen.status.rawValue)' — must be succeeded", code: "invalid_status")
        }

        guard let localPath = gen.localPath else {
            Output.failMessage("Generation '\(generationId)' has no local path — download it first", code: "no_local_path")
        }

        guard FileManager.default.fileExists(atPath: localPath) else {
            Output.failMessage("Video file not found at \(localPath)", code: "file_not_found")
        }

        var config = QualityConfig()
        config.enabled = true
        if let e = evaluator, let t = QualityConfig.EvaluatorType(rawValue: e) {
            config.evaluator = t
        } else if let e = evaluator {
            Output.failMessage("Unknown evaluator '\(e)'. Use: heuristic or llm-vision", code: "invalid_input")
        }
        if let v = threshold    { config.threshold = v }
        if let v = claudeApiKey { config.claudeApiKey = v }
        if let v = claudeModel  { config.claudeModel = v }
        if let v = maxFrames    { config.maxFrames = v }

        do {
            let result = try await QualityGate.evaluate(
                generation: gen, videoPath: localPath, shot: nil, config: config
            )
            Output.emitDict(result.jsonRepresentation)
        } catch let error as VortexError {
            Output.fail(error)
        } catch {
            Output.failMessage(error.localizedDescription, code: "evaluation_failed")
        }
    }
}
