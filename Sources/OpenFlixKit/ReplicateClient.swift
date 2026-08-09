import Foundation

public final class ReplicateClient: VideoProvider {
    public let providerId = "replicate"
    public let displayName = "Replicate"

    public let models: [CLIProviderModel] = [
        .priced(providerId: "replicate", providerName: "Replicate",
            modelId: "minimax/video-01-live", displayName: "MiniMax Video-01 Live",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 6, supportsImageToVideo: false),
        .priced(providerId: "replicate", providerName: "Replicate",
            modelId: "tencent/hunyuan-video", displayName: "Hunyuan Video",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, supportsImageToVideo: false),
        .priced(providerId: "replicate", providerName: "Replicate",
            modelId: "wavespeed-ai/wan-2.1", displayName: "Wan 2.1",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, supportsImageToVideo: false),
        // `supportsImageToVideo` was `true`, and this client **never sends an
        // image** — every other provider that claims the capability populates a
        // field for it (`image`, `keyframes`, `first_frame_image`,
        // `promptImage`); this one has none. So a user who attached a reference
        // image had it silently discarded and was billed for a text-to-video
        // generation that ignored their input.
        //
        // Turned off rather than implemented: Replicate's `input` schema is
        // per-model, so the start-frame key differs by model and there is
        // nothing here or in the app to derive it from. Advertising a capability
        // we cannot deliver is the worse of the two errors. (The model id is
        // separately suspect — Replicate's publisher is `kwaivgi`, not `kwaai`.)
        .priced(providerId: "replicate", providerName: "Replicate",
            modelId: "kwaai/kling-v1.6-pro", displayName: "Kling v1.6 Pro",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, supportsImageToVideo: false),
    ]

    private let session = makeSession()

    public init() {}

    public func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var input: [String: Any] = ["prompt": request.prompt]
        if let v = request.negativePrompt, !v.isEmpty { input["negative_prompt"] = v }
        if let w = request.width    { input["width"] = w }
        if let h = request.height   { input["height"] = h }
        if let d = request.durationSeconds, d.isFinite, d > 0 {
            // Int(Double) traps on NaN/inf/overflow; workflow & MCP paths don't
            // pre-validate duration the way `generate` does. Clamp defensively.
            input["num_frames"] = Int((min(d, 60) * 8).rounded())
        }

        let route = try Self.submitRoute(model: request.model, input: input)
        var urlReq = URLRequest(url: route.url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: route.body)

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
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 4, modelId: request.model)
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
