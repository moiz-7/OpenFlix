import Foundation
import Security

/// Keychain access. Uses the same service prefix as the Mac app so keys
/// set in OpenFlix GUI are automatically available to the CLI (and vice versa).
enum CLIKeychain {
    private static let servicePrefix = "com.openflix.cli"
    // Old prefixes for migration chain
    private static let oldServicePrefix = "com.meridian.vortex"
    private static let midServicePrefix = "com.openflix.vortex"
    // Migration flags
    private static let migrationFlagV1 = "com.openflix.cli.keychain.migrated"
    private static let migrationFlagV2 = "com.openflix.cli.keychain.v2.migrated"
    private static let knownProviders = ["fal", "replicate", "runway", "luma", "kling", "minimax"]

    /// One-time migration chain:
    /// 1. com.meridian.vortex.* -> com.openflix.cli.*  (v1 legacy)
    /// 2. com.openflix.vortex.* -> com.openflix.cli.*   (v2 rename)
    static func migrateKeychainIfNeeded() {
        // V1: migrate from com.meridian.vortex -> com.openflix.cli
        if !UserDefaults.standard.bool(forKey: migrationFlagV1) {
            defer { UserDefaults.standard.set(true, forKey: migrationFlagV1) }
            migrateKeys(from: oldServicePrefix, to: servicePrefix)
        }

        // V2: migrate from com.openflix.vortex -> com.openflix.cli
        if !UserDefaults.standard.bool(forKey: migrationFlagV2) {
            defer { UserDefaults.standard.set(true, forKey: migrationFlagV2) }
            migrateKeys(from: midServicePrefix, to: servicePrefix)
        }
    }

    /// Migrate keychain entries from one service prefix to another.
    private static func migrateKeys(from oldPrefix: String, to newPrefix: String) {
        for provider in knownProviders {
            let oldService = "\(oldPrefix).\(provider)"
            let newService = "\(newPrefix).\(provider)"

            // Read from old entry
            var result: AnyObject?
            let readStatus = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: oldService,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &result)
            guard readStatus == errSecSuccess, let data = result as? Data else { continue }

            // Write to new entry (only if it doesn't already exist)
            let addStatus = SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: newService,
                kSecValueData: data,
            ] as CFDictionary, nil)
            if addStatus == errSecSuccess || addStatus == errSecDuplicateItem {
                // Delete old entry
                SecItemDelete([
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: oldService,
                ] as CFDictionary)
            }
        }
    }

    // MARK: - Provider API Keys

    static func setKey(_ key: String, provider: String) {
        let service = "\(servicePrefix).\(provider)"
        let data = Data(key.utf8)

        // Delete existing entry first
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)

        guard !key.isEmpty else { return }

        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecValueData: data,
        ] as CFDictionary, nil)
    }

    static func getKey(provider: String) -> String? {
        let service = "\(servicePrefix).\(provider)"
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteKey(provider: String) {
        let service = "\(servicePrefix).\(provider)"
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)
    }

    static func hasKey(provider: String) -> Bool {
        getKey(provider: provider) != nil
    }

    // MARK: - Key resolution (flag > env var > keychain)

    /// Resolve an API key for a provider, checking in priority order:
    /// 1. Explicit flag value
    /// 2. OPENFLIX_{PROVIDER}_KEY env var
    /// 3. VORTEX_{PROVIDER}_KEY env var (legacy fallback)
    /// 4. OPENFLIX_API_KEY env var (generic)
    /// 5. VORTEX_API_KEY env var (legacy generic fallback)
    /// 6. macOS Keychain (shared with OpenFlix GUI)
    static func resolveKey(provider: String, flagValue: String?) throws -> String {
        migrateKeychainIfNeeded()
        if let v = flagValue, !v.isEmpty { return v }

        let providerSuffix = provider.uppercased().replacingOccurrences(of: "-", with: "_")

        // Provider-specific env vars (new name first, then legacy)
        let openflixEnv = "OPENFLIX_\(providerSuffix)_KEY"
        if let v = ProcessInfo.processInfo.environment[openflixEnv], !v.isEmpty { return v }

        let vortexEnv = "VORTEX_\(providerSuffix)_KEY"
        if let v = ProcessInfo.processInfo.environment[vortexEnv], !v.isEmpty { return v }

        // Generic fallback env vars (new name first, then legacy)
        if let v = ProcessInfo.processInfo.environment["OPENFLIX_API_KEY"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["VORTEX_API_KEY"], !v.isEmpty { return v }

        if let v = getKey(provider: provider) { return v }

        throw OpenFlixError.noApiKey(provider)
    }
}
