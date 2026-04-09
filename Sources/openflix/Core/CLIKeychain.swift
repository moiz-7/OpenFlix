import Foundation
import Security

/// Keychain access. Uses the same service prefix as the Mac app so keys
/// set in OpenFlix GUI are automatically available to the CLI (and vice versa).
enum CLIKeychain {
    // Must match VortexKeychain.servicePrefix in the Mac app
    private static let servicePrefix = "com.openflix.vortex"
    private static let oldServicePrefix = "com.meridian.vortex"
    private static let migrationFlag = "com.openflix.cli.keychain.migrated"
    private static let knownProviders = ["fal", "replicate", "runway", "luma", "kling", "minimax"]

    /// One-time migration of keychain entries from com.meridian.vortex.* to com.openflix.vortex.*
    static func migrateFromMeridianIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationFlag) }

        for provider in knownProviders {
            let oldService = "\(oldServicePrefix).\(provider)"
            let newService = "\(servicePrefix).\(provider)"

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
    /// 2. Environment variable (VORTEX_{PROVIDER}_KEY or VORTEX_API_KEY)
    /// 3. macOS Keychain (shared with OpenFlix GUI)
    static func resolveKey(provider: String, flagValue: String?) throws -> String {
        migrateFromMeridianIfNeeded()
        if let v = flagValue, !v.isEmpty { return v }

        let envName = "VORTEX_\(provider.uppercased().replacingOccurrences(of: "-", with: "_"))_KEY"
        if let v = ProcessInfo.processInfo.environment[envName], !v.isEmpty { return v }

        // Generic fallback
        if let v = ProcessInfo.processInfo.environment["VORTEX_API_KEY"], !v.isEmpty { return v }

        if let v = getKey(provider: provider) { return v }

        throw VortexError.noApiKey(provider)
    }
}
