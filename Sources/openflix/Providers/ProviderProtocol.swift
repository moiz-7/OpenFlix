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
        // Local ComfyUI: base URL from env (kit never reads env), graph
        // template from ~/.openflix/comfyui-graph.json when present.
        let comfyBase = ProcessInfo.processInfo.environment["OPENFLIX_COMFYUI_URL"]
            ?? "http://127.0.0.1:8188"
        let comfyTemplatePath = ("~/.openflix/comfyui-graph.json" as NSString).expandingTildeInPath
        let comfyTemplate = try? String(contentsOfFile: comfyTemplatePath, encoding: .utf8)

        let all: [VideoProvider] = [
            ReplicateClient(),
            FalClient(),
            RunwayClient(),
            LumaClient(),
            KlingClient(),
            MiniMaxClient(),
            ComfyUIClient(baseURL: comfyBase, graphTemplate: comfyTemplate),
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

// MARK: - Wire glue (CLI clients ↔ OpenFlixKit.ProviderWire)

extension GenerationRequest {
    /// The provider-neutral form every `ProviderWire` builder takes.
    /// `referenceImageURL` is already resolved by `GenerationEngine.submit`
    /// (an http(s) URL or a `data:` URI) by the time a client sees it.
    var wireInput: WireInput {
        WireInput(prompt: prompt, negativePrompt: negativePrompt, image: referenceImageURL,
                  durationSeconds: durationSeconds, aspectRatio: aspectRatio,
                  width: width, height: height, extra: extraParams)
    }

    /// Up-front estimate honouring any resolution/audio the caller asked for.
    func estimatedCost(providerId: String) -> Double {
        let hints = ModelPricing.pricingHints(from: extraParams)
        return ModelPricing.estimate(durationSeconds: durationSeconds ?? 5, modelId: model,
                                     providerId: providerId, resolution: hints.resolution, audio: hints.audio)
    }
}

/// Builds a plan, mapping wire refusals onto the CLI's error surface so an
/// agent sees `invalid_input` with the model named, not an opaque failure.
func buildPlan(_ make: () throws -> WirePlan) throws -> WirePlan {
    do { return try make() }
    catch let e as WireError { throw OpenFlixError.invalidInput(e.errorDescription ?? "\(e)") }
}

extension URLSession {
    /// POSTs a wire plan with the given auth headers and returns the body.
    func send(_ plan: WirePlan, auth: [String: String]) async throws -> Data {
        var req = URLRequest(url: plan.url)
        req.httpMethod = "POST"
        for (k, v) in auth { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in plan.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: plan.body)
        return try await jsonData(for: req).0
    }

    func get(_ url: URL, auth: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in auth where k != "Content-Type" { req.setValue(v, forHTTPHeaderField: k) }
        return try await jsonData(for: req).0
    }
}
