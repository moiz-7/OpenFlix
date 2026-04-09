import ArgumentParser
import Foundation

struct Cancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cancel a running generation",
        discussion: """
        Attempts to cancel a generation that is queued, submitted, or processing.
        Sends a best-effort cancel request to the remote provider.

        EXAMPLES
          vortex cancel <generation-id>
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

        // Best-effort remote cancel
        if let taskId = gen.remoteTaskId,
           let key = try? CLIKeychain.resolveKey(provider: gen.provider, flagValue: apiKey),
           let provider = try? ProviderRegistry.shared.provider(for: gen.provider) {
            try? await provider.cancel(taskId: taskId, apiKey: key)
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
