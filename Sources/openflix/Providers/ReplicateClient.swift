import Foundation

final class ReplicateClient: VideoProvider {
    let providerId = "replicate"
    let displayName = "Replicate"

    let models: [CLIProviderModel] = [
        CLIProviderModel(providerId: "replicate", providerName: "Replicate",
            modelId: "minimax/video-01-live", displayName: "MiniMax Video-01 Live",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 6, costPerSecondUSD: 0.05, supportsImageToVideo: false),
        CLIProviderModel(providerId: "replicate", providerName: "Replicate",
            modelId: "tencent/hunyuan-video", displayName: "Hunyuan Video",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.04, supportsImageToVideo: false),
        CLIProviderModel(providerId: "replicate", providerName: "Replicate",
            modelId: "wavespeed-ai/wan-2.1", displayName: "Wan 2.1",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.03, supportsImageToVideo: false),
        CLIProviderModel(providerId: "replicate", providerName: "Replicate",
            modelId: "kwaai/kling-v1.6-pro", displayName: "Kling v1.6 Pro",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.10, supportsImageToVideo: true),
    ]

    private let session = makeSession()

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var input: [String: Any] = ["prompt": request.prompt]
        if let v = request.negativePrompt, !v.isEmpty { input["negative_prompt"] = v }
        if let w = request.width    { input["width"] = w }
        if let h = request.height   { input["height"] = h }
        if let d = request.durationSeconds { input["num_frames"] = Int(d * 8) }

        guard let url = URL(string: "https://api.replicate.com/v1/predictions") else {
            throw VortexError.invalidResponse("Invalid Replicate API URL")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "version": request.model,
            "input": input,
        ])

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String,
              let urls = json?["urls"] as? [String: Any],
              let getURL = urls["get"] as? String else {
            throw VortexError.invalidResponse("Missing id/urls in Replicate response")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: URL(string: getURL),
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 4, modelId: request.model)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let url: URL
        if let statusURL = statusURL {
            url = statusURL
        } else {
            guard let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw VortexError.invalidResponse("Invalid task ID: \(taskId)")
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
        let status = json?["status"] as? String ?? ""

        switch status {
        case "starting", "processing":
            return .processing(progress: nil)
        case "succeeded":
            let outputs = json?["output"] as? [String]
            guard let first = outputs?.first, let url = URL(string: first) else {
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

    func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        let cps = models.first { $0.modelId == modelId }?.costPerSecondUSD ?? 0.05
        return cps * durationSeconds
    }
}
