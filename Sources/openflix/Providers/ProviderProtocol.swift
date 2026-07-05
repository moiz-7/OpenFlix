import Foundation
import OpenFlixKit

// MARK: - Provider glue (CLI side)
//
// The `VideoProvider` protocol and its request/response types live in
// OpenFlixKit (ProviderProtocol.swift there). This file keeps the CLI-side
// glue: the provider registry (which providers ship in this binary is a CLI
// decision) and the HTTP helpers used by the provider clients that still
// live in the CLI — these throw the CLI's `OpenFlixError` so every command's
// machine-readable error codes are unchanged.

// MARK: - Registry

final class ProviderRegistry {
    static let shared = ProviderRegistry()

    private var _providers: [String: VideoProvider]

    private init() {
        let all: [VideoProvider] = [
            ReplicateClient(),
            FalClient(),
            RunwayClient(),
            LumaClient(),
            KlingClient(),
            MiniMaxClient(),
        ]
        _providers = Dictionary(uniqueKeysWithValues: all.map { ($0.providerId, $0) })
    }

    func provider(for id: String) throws -> VideoProvider {
        guard let p = _providers[id] else { throw OpenFlixError.providerNotFound(id) }
        return p
    }

    var all: [VideoProvider] {
        _providers.values.sorted { $0.displayName < $1.displayName }
    }

    var allModels: [CLIProviderModel] {
        all.flatMap { $0.models }
    }
}

// MARK: - HTTP helpers (shared by CLI provider clients)

extension URLSession {
    func jsonData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenFlixError.invalidResponse("No HTTP response")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw OpenFlixError.rateLimited("Provider", retryAfter: retryAfter)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenFlixError.httpError(http.statusCode, body.prefix(500).description)
        }
        return (data, http)
    }
}

func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 120
    return URLSession(configuration: config)
}
