import ArgumentParser
import Foundation

struct Retry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Retry a failed or cancelled generation",
        discussion: """
        Resubmits a generation with the same parameters. The original generation
        is kept; a new generation is created with a reference to the original.

        EXAMPLES
          vortex retry abc123
          vortex retry abc123 --wait
          vortex retry abc123 --stream --skip-download
        """
    )

    @Argument(help: "Generation ID to retry")
    var id: String

    @Flag(name: .long, help: "Block until generation completes")
    var wait: Bool = false

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events")
    var stream: Bool = false

    @Flag(name: .long, help: "Skip downloading the video after generation completes")
    var skipDownload: Bool = false

    @Option(name: .long, help: "Max seconds to wait (default: 300)")
    var timeout: Double = 300

    @Option(name: .long, help: "Poll interval in seconds (default: 3)")
    var pollInterval: Double = 3

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let original = GenerationStore.shared.get(id) else {
            Output.failMessage("Generation '\(id)' not found.", code: "not_found")
        }

        let retryable: Set<CLIGeneration.GenerationStatus> = [.failed, .cancelled]
        guard retryable.contains(original.status) else {
            Output.failMessage(
                "Generation '\(id)' has status '\(original.status.rawValue)' — only failed or cancelled generations can be retried.",
                code: "invalid_status"
            )
        }

        let opts = GenerationEngine.Options(
            pollInterval: pollInterval,
            timeout: timeout,
            outputURL: nil,
            stream: stream,
            skipDownload: skipDownload,
            maxRetries: 0
        )

        do {
            let gen: CLIGeneration
            if wait || stream {
                gen = try await GenerationEngine.submitAndWait(
                    prompt: original.prompt,
                    negativePrompt: original.negativePrompt,
                    provider: original.provider,
                    model: original.model,
                    durationSeconds: original.durationSeconds,
                    aspectRatio: original.aspectRatio,
                    width: original.widthPx,
                    height: original.heightPx,
                    apiKey: apiKey,
                    options: opts
                )
            } else {
                gen = try await GenerationEngine.submit(
                    prompt: original.prompt,
                    negativePrompt: original.negativePrompt,
                    provider: original.provider,
                    model: original.model,
                    durationSeconds: original.durationSeconds,
                    aspectRatio: original.aspectRatio,
                    width: original.widthPx,
                    height: original.heightPx,
                    apiKey: apiKey
                )
            }
            var result = gen.jsonRepresentation
            result["retried_from"] = original.id
            Output.emitDict(result)
        } catch let error as VortexError {
            Output.fail(error)
        } catch {
            Output.failMessage(error.localizedDescription)
        }
    }
}
