import ArgumentParser
import Foundation

struct Providers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List available providers",
        subcommands: [ProvidersListCommand.self, ModelsCommand.self],
        defaultSubcommand: ProvidersListCommand.self
    )
}

struct ProvidersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all available providers"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        let providers = ProviderRegistry.shared.all
        let result = providers.map { p -> [String: Any] in
            [
                "id": p.providerId,
                "name": p.displayName,
                "model_count": p.models.count,
                "models": p.models.map { $0.modelId },
            ]
        }
        Output.emitArray(result)
    }
}

// Top-level `openflix models` shortcut
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List models for a provider (alias: openflix providers models)",
        discussion: """
        Lists all available models with capabilities and pricing.

        EXAMPLES
          openflix models --provider fal
          openflix models --provider replicate --pretty
        """
    )

    @Option(name: .long, help: "Provider ID (replicate, fal, runway, luma, kling, minimax)")
    var provider: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        try await runModels(provider: provider, pretty: pretty)
    }
}

// Subcommand within `providers`
struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List models for a provider"
    )

    @Option(name: .long, help: "Provider ID (replicate, fal, runway, luma, kling, minimax)")
    var provider: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        try await runModels(provider: provider, pretty: pretty)
    }
}

// Shared implementation
private func runModels(provider: String?, pretty: Bool) async throws {
    if let provider {
        guard let prov = try? ProviderRegistry.shared.provider(for: provider) else {
            Output.fail(.providerNotFound(provider))
        }
        let result = prov.models.map { modelJSON($0) }
        Output.emitArray(result)
    } else {
        // No provider: list all providers
        let providers = ProviderRegistry.shared.all
        let result = providers.map { p -> [String: Any] in
            [
                "id": p.providerId,
                "name": p.displayName,
                "model_count": p.models.count,
                "models": p.models.map { $0.modelId },
            ]
        }
        Output.emitArray(result)
    }
}

private func modelJSON(_ m: CLIProviderModel) -> [String: Any] {
    return m.jsonRepresentation
}
