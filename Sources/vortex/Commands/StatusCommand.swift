import ArgumentParser
import Foundation

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the status of a generation",
        discussion: """
        Polls the remote provider for the current status of a submitted generation.
        Reads the generation from local store, then queries the provider API.

        EXAMPLES
          vortex status abc123
          vortex status abc123 --wait --stream
          vortex status abc123 --wait --output ~/Downloads/result.mp4
        """
    )

    @Argument(help: "Generation ID (from 'vortex generate' or 'vortex list')")
    var id: String

    @Flag(name: .long, help: "Block until generation completes")
    var wait: Bool = false

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events")
    var stream: Bool = false

    @Option(name: .long, help: "Max seconds to wait (default: 300)")
    var timeout: Double = 300

    @Option(name: .long, help: "Poll interval in seconds (default: 3)")
    var pollInterval: Double = 3

    @Option(name: [.short, .long], help: "Output file path for the downloaded video")
    var output: String?

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Skip downloading the video after generation completes")
    var skipDownload: Bool = false

    @Flag(name: .long, help: "Return cached status without polling the provider")
    var cached: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard var gen = GenerationStore.shared.get(id) else {
            Output.failMessage("Generation '\(id)' not found in local store.", code: "not_found")
        }

        if cached {
            Output.emitDict(gen.jsonRepresentation)
            return
        }

        // Skip remote poll if generation is already terminal
        let terminal: Set<CLIGeneration.GenerationStatus> = [.succeeded, .failed, .cancelled]
        if terminal.contains(gen.status) {
            Output.emitDict(gen.jsonRepresentation)
            return
        }

        if !wait && !stream {
            // Just poll once and return current status
            let provider = try ProviderRegistry.shared.provider(for: gen.provider)
            let key = try CLIKeychain.resolveKey(provider: gen.provider, flagValue: apiKey)
            let statusURL = gen.statusURL.flatMap { URL(string: $0) }
            guard let taskId = gen.remoteTaskId else {
                Output.emitDict(gen.jsonRepresentation)
                return
            }
            let pollResult = try await provider.poll(taskId: taskId, statusURL: statusURL, apiKey: key)
            switch pollResult {
            case .queued:              gen.status = .submitted
            case .processing:          gen.status = .processing
            case .succeeded(let videoURL):
                gen.status = .succeeded
                gen.remoteVideoURL = videoURL.absoluteString
                gen.completedAt = Date()
                gen.actualCostUSD = gen.estimatedCostUSD
            case .failed(let message): gen.status = .failed; gen.errorMessage = message
            }
            GenerationStore.shared.update(id: gen.id) { g in
                g.status = gen.status
                g.remoteVideoURL = gen.remoteVideoURL
                g.completedAt = gen.completedAt
                g.actualCostUSD = gen.actualCostUSD
                if let m = gen.errorMessage { g.errorMessage = m }
            }
            Output.emitDict(gen.jsonRepresentation)
            return
        }

        let opts = GenerationEngine.Options(
            pollInterval: pollInterval,
            timeout: timeout,
            outputURL: output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            stream: stream,
            skipDownload: skipDownload
        )
        do {
            let completed = try await GenerationEngine.waitForCompletion(gen: &gen, apiKey: apiKey, options: opts)
            Output.emitDict(completed.jsonRepresentation)
        } catch let error as VortexError {
            Output.fail(error)
        } catch {
            Output.failMessage(error.localizedDescription)
        }
    }
}
