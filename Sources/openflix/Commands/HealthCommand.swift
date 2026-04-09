import ArgumentParser
import Foundation

struct Health: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check system health for agent diagnostics",
        discussion: """
        Reports on store accessibility, download directory, and provider
        API key configuration. Useful for agents to verify the environment
        before submitting generation requests.

        Checks for both OPENFLIX_*_KEY and legacy VORTEX_*_KEY environment
        variables.

        EXAMPLES
          openflix health
          openflix health --pretty
        """
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let storeDir = home.appendingPathComponent(".openflix", isDirectory: true)
        let storeFile = storeDir.appendingPathComponent("store.json")
        let downloadsDir = home.appendingPathComponent(".openflix/downloads", isDirectory: true)

        // Check store writable
        let storeWritable: Bool
        if fm.fileExists(atPath: storeFile.path) {
            storeWritable = fm.isWritableFile(atPath: storeFile.path)
        } else {
            storeWritable = fm.isWritableFile(atPath: storeDir.path)
        }

        // Check downloads dir writable
        let downloadsWritable = fm.isWritableFile(atPath: downloadsDir.path)

        // Count generations
        let genCount = GenerationStore.shared.all().count

        // Check providers
        let registry = ProviderRegistry.shared
        var providerResults: [[String: Any]] = []
        var allConfigured = true
        for prov in registry.all {
            let hasKeychain = CLIKeychain.hasKey(provider: prov.providerId)
            let providerSuffix = prov.providerId.uppercased().replacingOccurrences(of: "-", with: "_")
            let hasEnv = ProcessInfo.processInfo.environment["OPENFLIX_\(providerSuffix)_KEY"] != nil
                || ProcessInfo.processInfo.environment["VORTEX_\(providerSuffix)_KEY"] != nil
            let hasGenericEnv = ProcessInfo.processInfo.environment["OPENFLIX_API_KEY"] != nil
                || ProcessInfo.processInfo.environment["VORTEX_API_KEY"] != nil
            let configured = hasKeychain || hasEnv || hasGenericEnv
            if !configured { allConfigured = false }
            providerResults.append([
                "provider": prov.providerId,
                "display_name": prov.displayName,
                "configured": configured,
                "keychain": hasKeychain,
                "env_var": hasEnv,
            ])
        }

        let healthy = storeWritable && downloadsWritable

        Output.emitDict([
            "healthy": healthy,
            "store_writable": storeWritable,
            "downloads_writable": downloadsWritable,
            "generation_count": genCount,
            "providers": providerResults,
            "all_providers_configured": allConfigured,
        ])
    }
}
