import ArgumentParser
import Foundation

struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download the video for a completed generation",
        discussion: """
        Downloads the video for a generation that has already succeeded.
        If the generation is not yet complete, use --wait to block until it is.

        EXAMPLES
          openflix download abc123
          openflix download abc123 --output ~/Videos/result.mp4
          openflix download abc123 --wait
        """
    )

    @Argument(help: "Generation ID")
    var id: String

    @Option(name: [.short, .long], help: "Output file path (default: ~/.openflix/downloads/<id>.mp4)")
    var output: String?

    @Flag(name: .long, help: "Block until generation completes before downloading")
    var wait: Bool = false

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

        guard var gen = GenerationStore.shared.get(id) else {
            Output.failMessage("Generation '\(id)' not found.", code: "not_found")
        }

        let outputURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        // If wait requested, poll until done first
        if wait && gen.status != CLIGeneration.GenerationStatus.succeeded {
            let opts = GenerationEngine.Options(
                pollInterval: pollInterval,
                timeout: timeout,
                outputURL: outputURL,
                stream: false
            )
            do {
                gen = try await GenerationEngine.waitForCompletion(gen: &gen, apiKey: apiKey, options: opts)
            } catch let error as OpenFlixError {
                Output.fail(error)
            } catch {
                Output.failMessage(error.localizedDescription)
            }
        }

        guard gen.status == CLIGeneration.GenerationStatus.succeeded else {
            Output.failMessage(
                "Generation '\(id)' is not succeeded (status: \(gen.status.rawValue)). Use --wait to block.",
                code: "not_ready"
            )
        }

        // If already downloaded and file exists, return cached path
        if let localPath = gen.localPath, outputURL == nil {
            if FileManager.default.fileExists(atPath: localPath) {
                Output.emitDict([
                    "id": gen.id,
                    "local_path": localPath,
                    "cached": true,
                ])
                return
            } else {
                // Stale cached path — file was deleted, clear and re-download
                GenerationStore.shared.update(id: gen.id) { $0.localPath = nil }
                gen.localPath = nil
            }
        }

        guard let remoteStr = gen.remoteVideoURL, let remoteURL = URL(string: remoteStr) else {
            Output.failMessage("No remote video URL for generation '\(id)'.", code: "no_url")
        }

        do {
            let localURL = try await VideoDownloader.download(from: remoteURL, to: outputURL, generationId: gen.id)
            GenerationStore.shared.update(id: gen.id) { $0.localPath = localURL.path }
            Output.emitDict(["id": gen.id, "local_path": localURL.path, "cached": false])
        } catch let error as OpenFlixError {
            Output.fail(error)
        } catch {
            Output.failMessage("Download failed: \(error.localizedDescription)", code: "download_failed")
        }
    }
}
