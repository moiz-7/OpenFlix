import ArgumentParser
import Foundation
import Security

struct Keys: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Manage API keys in the system Keychain",
        discussion: """
        Stores API keys in the macOS Keychain under the same service as OpenFlix,
        so keys configured here are also available to the GUI app and vice versa.

        EXAMPLES
          openflix keys set fal your-api-key
          openflix keys get fal
          openflix keys list
          openflix keys delete fal
        """,
        subcommands: [KeysSet.self, KeysGet.self, KeysDelete.self, KeysList.self]
    )
}

struct KeysSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Store an API key in the Keychain"
    )

    @Argument(help: "Provider ID (replicate, fal, runway, luma, kling, minimax)")
    var provider: String

    @Argument(help: "API key value")
    var key: String

    mutating func run() async throws {
        let service = "com.openflix.cli.\(provider)"
        let data = key.data(using: .utf8)!

        // Delete existing first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            Output.failMessage("Failed to store key in Keychain: \(keychainError(status))", code: "keychain_error")
        }
        Output.emitDict(["provider": provider, "stored": true])
    }
}

struct KeysGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Retrieve an API key from the Keychain"
    )

    @Argument(help: "Provider ID")
    var provider: String

    @Flag(name: .long, help: "Print the key value (masked by default)")
    var reveal: Bool = false

    mutating func run() async throws {
        let service = "com.openflix.cli.\(provider)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let keyStr = String(data: data, encoding: .utf8) else {
            Output.failMessage("No key found for provider '\(provider)'", code: "not_found")
        }
        let display = reveal ? keyStr : String(repeating: "•", count: min(keyStr.count, 8)) + "..."
        Output.emitDict(["provider": provider, "key": display, "revealed": reveal])
    }
}

struct KeysDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove an API key from the Keychain"
    )

    @Argument(help: "Provider ID")
    var provider: String

    mutating func run() async throws {
        let service = "com.openflix.cli.\(provider)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Output.failMessage("Failed to delete key: \(keychainError(status))", code: "keychain_error")
        }
        Output.emitDict(["provider": provider, "deleted": status == errSecSuccess])
    }
}

struct KeysList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all providers with stored API keys"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        let providers = ProviderRegistry.shared.all.map { $0.providerId }
        var result: [[String: Any]] = []
        for provId in providers {
            let service = "com.openflix.cli.\(provId)"
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: false,
            ]
            var ref: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &ref)
            result.append(["provider": provId, "has_key": status == errSecSuccess])
        }
        Output.emitArray(result)
    }
}

// MARK: - Keychain error helper

private func keychainError(_ status: OSStatus) -> String {
    switch status {
    case errSecItemNotFound:           return "item not found in Keychain"
    case errSecDuplicateItem:          return "duplicate item"
    case errSecAuthFailed:             return "authentication failed"
    case errSecInteractionNotAllowed:  return "Keychain interaction not allowed (unlock Keychain)"
    case errSecUserCanceled:           return "user cancelled"
    default:                           return "OSStatus \(status)"
    }
}
