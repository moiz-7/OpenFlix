import Foundation

final class LumaClient: VideoProvider {
    let providerId = "luma"
    let displayName = "Luma"

    let models: [CLIProviderModel] = [
        CLIProviderModel(providerId: "luma", providerName: "Luma",
            modelId: "ray-2", displayName: "Ray 2",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.10, supportsImageToVideo: true),
        CLIProviderModel(providerId: "luma", providerName: "Luma",
            modelId: "ray-flash-2", displayName: "Ray Flash 2",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.05, supportsImageToVideo: true),
        CLIProviderModel(providerId: "luma", providerName: "Luma",
            modelId: "ray-3", displayName: "Ray 3",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.20, supportsImageToVideo: true),
    ]

    private let session = makeSession()
    private static let base: URL = {
        guard let url = URL(string: "https://api.lumalabs.ai/dream-machine/v1") else {
            fatalError("Invalid static Luma API URL")
        }
        return url
    }()
    private var base: URL { Self.base }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var body: [String: Any] = [
            "prompt": request.prompt,
            "model": request.model,
        ]
        if let d = request.durationSeconds { body["duration"] = Int(d) }
        if let ar = request.aspectRatio { body["aspect_ratio"] = ar }
        if let ref = request.referenceImageURL {
            body["keyframes"] = [
                "frame0": ["type": "image", "url": ref.absoluteString]
            ]
        }

        var urlReq = URLRequest(url: base.appendingPathComponent("generations"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw VortexError.invalidResponse("Missing id in Luma response")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: nil,
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 5, modelId: request.model)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        var urlReq = URLRequest(url: base.appendingPathComponent("generations/\(taskId)"))
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let state = json?["state"] as? String ?? ""

        switch state {
        case "pending":         return .queued
        case "dreaming":        return .processing(progress: nil)
        case "completed":
            let assets = json?["assets"] as? [String: Any]
            let videoStr = assets?["video"] as? String
            guard let str = videoStr, let url = URL(string: str) else {
                return .failed(message: "No video in Luma assets")
            }
            return .succeeded(videoURL: url)
        case "failed":
            return .failed(message: json?["failure_reason"] as? String ?? "Luma generation failed")
        default:
            fputs("{\"warning\":\"Unknown Luma status: \(state)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        }
    }

    func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        let cps = models.first { $0.modelId == modelId }?.costPerSecondUSD ?? 0.10
        return cps * durationSeconds
    }
}
