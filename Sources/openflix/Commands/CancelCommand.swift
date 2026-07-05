import ArgumentParser
import Foundation
import OpenFlixKit

// MARK: - Shared provider-cancel path (used by CLI cancel and MCP cancel_generation)

enum CancelService {

    enum RemoteOutcome {
        case cancelled                       // provider accepted the cancel
        case notSupported(OpenFlixError)     // provider has no cancel API
        case bestEffortFailed                // network/other error — cancel locally anyway
        case noRemoteTask                    // nothing to cancel remotely
    }

    /// Attempt the real provider cancel for a generation.
    static func attemptRemoteCancel(gen: CLIGeneration, apiKey: String?) async -> RemoteOutcome {
        guard let taskId = gen.remoteTaskId,
              let key = try? CLIKeychain.resolveKey(provider: gen.provider, flagValue: apiKey),
              let provider = try? ProviderRegistry.shared.provider(for: gen.provider) else {
            return .noRemoteTask
        }
        do {
            do { try await provider.cancel(taskId: taskId, statusURL: gen.statusURL.flatMap { URL(string: $0) }, apiKey: key) }
            catch let e as ProviderError { throw OpenFlixError(e) }
            return .cancelled
        } catch let error as OpenFlixError {
            if case .cancelNotSupported = error { return .notSupported(error) }
            return .bestEffortFailed
        } catch {
            return .bestEffortFailed
        }
    }
}

struct Cancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cancel a running generation",
        discussion: """
        Attempts to cancel a generation that is queued, submitted, or processing.
        Sends a cancel request to the remote provider (Replicate, fal.ai, Runway).
        Providers without a cancel API (Luma, Kling, MiniMax) return a
        cancel_not_supported error and the generation is left untouched.

        EXAMPLES
          openflix cancel <generation-id>
        """
    )

    @Argument(help: "Generation ID to cancel")
    var id: String

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard var gen = GenerationStore.shared.get(id) else {
            Output.failMessage("Generation '\(id)' not found.", code: "not_found")
        }

        // Already cancelled — return idempotently
        if gen.status == .cancelled {
            Output.emitDict(gen.jsonRepresentation)
            return
        }

        let cancellable: Set<CLIGeneration.GenerationStatus> = [.queued, .submitted, .processing]
        guard cancellable.contains(gen.status) else {
            Output.failMessage(
                "Generation '\(id)' cannot be cancelled (status: \(gen.status.rawValue))",
                code: "not_cancellable"
            )
        }

        // Remote cancel — providers without cancel support surface a real error.
        // (Other provider errors are best-effort — still cancel locally.)
        if case .notSupported(let error) = await CancelService.attemptRemoteCancel(gen: gen, apiKey: apiKey) {
            Output.fail(error)
        }

        GenerationStore.shared.update(id: gen.id) { g in
            g.status = .cancelled
            g.completedAt = Date()
        }
        gen.status = .cancelled
        gen.completedAt = Date()
        Output.emitDict(gen.jsonRepresentation)
    }
}
