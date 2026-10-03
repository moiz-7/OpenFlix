import Foundation

public final class ReplicateClient: VideoProvider {
    public let providerId = "replicate"
    public let displayName = "Replicate"

    /// From `VideoModelCatalog`: every slug checked live on 2026-09-27.
    /// `wavespeed-ai/wan-2.1` and `kwaai/kling-v1.6-pro` no longer existed,
    /// and `minimax/video-01-live` REQUIRES an image — it was listed as
    /// text-to-video, so every call to it failed.
    public let models: [CLIProviderModel] = CLIProviderModel.catalog(provider: "replicate", providerName: "Replicate")

    private let session = makeSession()

    public init() {}

    public func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        // Field names differ per model (duration vs seconds; image vs
        // start_image vs input_reference) — `ReplicateWire` takes them from
        // each model's schema. The old body sent width/height/num_frames,
        // which none of the current models accept.
        let input = WireInput(prompt: request.prompt, negativePrompt: request.negativePrompt,
                              image: request.referenceImageURL, durationSeconds: request.durationSeconds,
                              aspectRatio: request.aspectRatio, width: request.width, height: request.height,
                              extra: request.extraParams)
        let plan: WirePlan
        do { plan = try ReplicateWire.plan(model: request.model, input: input) }
        catch let e as WireError { throw ProviderError.invalidResponse(e.errorDescription ?? "\(e)") }

        var urlReq = URLRequest(url: plan.url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: plan.body)

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String,
              let urls = json?["urls"] as? [String: Any],
              let getURL = urls["get"] as? String else {
            throw ProviderError.invalidResponse("Missing id/urls in Replicate response")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: URL(string: getURL),
            estimatedCostUSD: {
                let hints = ModelPricing.pricingHints(from: request.extraParams)
                return ModelPricing.estimate(durationSeconds: request.durationSeconds ?? 5, modelId: request.model,
                                             providerId: providerId, resolution: hints.resolution, audio: hints.audio)
            }()
        )
    }

    public func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let url: URL
        if let statusURL = statusURL {
            url = statusURL
        } else {
            guard let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw ProviderError.invalidResponse("Invalid task ID: \(taskId)")
            }
            guard let fallback = URL(string: "https://api.replicate.com/v1/predictions/\(encoded)") else {
                return .failed(message: "Replicate: invalid task ID for URL construction")
            }
            url = fallback
        }
        var urlReq = URLRequest(url: url)
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Self.parsePollStatus(json)
    }

    /// Choose the correct Replicate submit endpoint and body for a model id.
    ///
    /// Replicate has two distinct submit routes and the wrong one 422s:
    ///   - a pinned VERSION (a 64-char hex hash) goes to `/v1/predictions`
    ///     with `{"version": "<hash>", "input": {...}}`
    ///   - an official MODEL SLUG ("owner/name") goes to
    ///     `/v1/models/{owner}/{name}/predictions` with just `{"input": {...}}`
    ///
    /// Every model in this client's catalog is a slug ("minimax/video-01-live",
    /// "tencent/hunyuan-video", …), and they were all being sent as
    /// `{"version": "<slug>"}` to `/v1/predictions` — which cannot succeed. It
    /// is the signature of an integration written from docs and never run
    /// against the live API.
    ///
    /// Pure and separated from the network call so it is unit-testable.
    public static func submitRoute(model: String, input: [String: Any]) throws -> (url: URL, body: [String: Any]) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError.invalidResponse("Replicate model id is empty")
        }

        // A version hash: 64 hex characters, no slash.
        let isVersionHash = trimmed.count == 64
            && !trimmed.contains("/")
            && trimmed.allSatisfy { $0.isHexDigit }

        if isVersionHash {
            guard let url = URL(string: "https://api.replicate.com/v1/predictions") else {
                throw ProviderError.invalidResponse("Invalid Replicate API URL")
            }
            return (url, ["version": trimmed, "input": input])
        }

        // Otherwise treat it as owner/name. Reject anything that isn't, rather
        // than sending a malformed request and reporting the provider's opaque
        // error back to the user.
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ProviderError.invalidResponse(
                "Replicate model must be 'owner/name' or a 64-char version hash (got: \(trimmed))")
        }
        guard let owner = parts[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let name = parts[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.replicate.com/v1/models/\(owner)/\(name)/predictions") else {
            throw ProviderError.invalidResponse("Invalid Replicate model id: \(trimmed)")
        }
        return (url, ["input": input])
    }

    /// Pure parsing of a Replicate prediction response — separated from the
    /// network fetch so it is unit-testable with canned JSON.
    public static func parsePollStatus(_ json: [String: Any]?) -> PollStatus {
        let status = json?["status"] as? String ?? ""

        switch status {
        case "starting", "processing":
            return .processing(progress: nil)
        case "succeeded":
            // Replicate returns `output` as either an array of URLs or a single
            // URL string depending on the model. Accept both, else a successful
            // (billed) generation is falsely reported as failed.
            let outputURL: String?
            if let arr = json?["output"] as? [String] {
                outputURL = arr.first
            } else {
                outputURL = json?["output"] as? String
            }
            guard let first = outputURL, let url = URL(string: first) else {
                return .failed(message: "No output URL in Replicate response")
            }
            return .succeeded(videoURL: url)
        case "failed", "canceled":
            return .failed(message: json?["error"] as? String ?? "Unknown Replicate error")
        default:
            fputs("{\"warning\":\"Unknown Replicate status: \(status)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        }
    }


    public func cancel(taskId: String, statusURL: URL?, apiKey: String) async throws {
        guard let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.replicate.com/v1/predictions/\(encoded)/cancel") else {
            throw ProviderError.invalidResponse("Invalid task ID: \(taskId)")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await session.jsonData(for: urlReq)
    }
}
