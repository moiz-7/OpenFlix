import Foundation

// MARK: - Provider protocol
//
// API keys are always passed in by the caller — the kit never reads
// keychains, stores, or environment variables.

public protocol VideoProvider: AnyObject {
    var providerId: String { get }
    var displayName: String { get }
    var models: [CLIProviderModel] { get }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission
    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus
    func estimateCost(durationSeconds: Double, modelId: String) -> Double?
    func cancel(taskId: String, statusURL: URL?, apiKey: String) async throws
}

extension VideoProvider {
    /// Providers without a remote cancel API get an explicit error, never a silent no-op.
    public func cancel(taskId: String, statusURL: URL?, apiKey: String) async throws {
        throw ProviderError.cancelNotSupported(displayName)
    }

    /// Cost estimates resolve through the single pricing table
    /// (ModelPricing.swift) — providers do not carry their own copies.
    public func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        ModelPricing.estimate(durationSeconds: durationSeconds,
                              modelId: modelId, providerId: providerId)
    }
}

// MARK: - HTTP helpers (kit-internal)
//
// Used by kit provider clients. The CLI keeps its own equivalent helpers
// (throwing its own error type) for the provider clients that still live
// there; this internal copy keeps ProviderError contained to the kit.

extension URLSession {
    func jsonData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("No HTTP response")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw ProviderError.rateLimited("Provider", retryAfter: retryAfter)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.httpError(http.statusCode, body.prefix(500).description)
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
