import Foundation

final class FalClient: VideoProvider {
    let providerId = "fal"
    let displayName = "fal.ai"

    let models: [CLIProviderModel] = [
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/bytedance/seedance/v2/text-to-video", displayName: "Seedance 2.0",
            defaultWidth: 1920, defaultHeight: 1080, maxDurationSeconds: 15, costPerSecondUSD: 0.05, supportsImageToVideo: false),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/bytedance/seedance/v2/image-to-video", displayName: "Seedance 2.0 I2V",
            defaultWidth: 1920, defaultHeight: 1080, maxDurationSeconds: 15, costPerSecondUSD: 0.06, supportsImageToVideo: true),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/kling-video/v2/master/text-to-video", displayName: "Kling v2 Master",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.06, supportsImageToVideo: true),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/minimax/hailuo-02", displayName: "Hailuo 02",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 6, costPerSecondUSD: 0.05, supportsImageToVideo: false),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/luma-dream-machine", displayName: "Luma Dream Machine",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.08, supportsImageToVideo: false),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/hunyuan-video", displayName: "Hunyuan Video",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.04, supportsImageToVideo: false),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/wan/v2.1/1080p", displayName: "Wan 2.1 1080p",
            defaultWidth: 1920, defaultHeight: 1080, maxDurationSeconds: 5, costPerSecondUSD: 0.03, supportsImageToVideo: false),
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
            modelId: "fal-ai/veo3", displayName: "Veo 3",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 8, costPerSecondUSD: 0.15, supportsImageToVideo: false),
    ]

    private let session = makeSession()

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var body: [String: Any] = ["prompt": request.prompt]
        if let v = request.negativePrompt, !v.isEmpty { body["negative_prompt"] = v }
        if let d = request.durationSeconds { body["duration"] = "\(Int(d))" }
        if let ar = request.aspectRatio { body["aspect_ratio"] = ar }
        if let ref = request.referenceImageURL { body["image_url"] = ref.absoluteString }
        // Forward extra params (audio, seed, camera_fixed, etc.)
        for (k, v) in request.extraParams { body[k] = v }

        guard let url = URL(string: "https://queue.fal.run/\(request.model)") else {
            throw OpenFlixError.invalidResponse("Invalid fal.ai URL for model: \(request.model)")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["request_id"] as? String,
              let statusURLStr = json?["status_url"] as? String else {
            throw OpenFlixError.invalidResponse("Missing request_id/status_url in fal.ai response")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: URL(string: statusURLStr),
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 4, modelId: request.model)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        guard let url = statusURL else {
            return .failed(message: "No status URL for fal.ai generation")
        }
        var urlReq = URLRequest(url: url)
        urlReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = json?["status"] as? String ?? ""

        switch status {
        case "IN_QUEUE": return .queued
        case "IN_PROGRESS": return .processing(progress: nil)
        case "COMPLETED":
            guard let responseURLStr = json?["response_url"] as? String,
                  let responseURL = URL(string: responseURLStr) else {
                return .failed(message: "No response_url in fal.ai COMPLETED response")
            }
            // Fetch the actual result
            var resultReq = URLRequest(url: responseURL)
            resultReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            let (resultData, _) = try await session.jsonData(for: resultReq)
            let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any]
            // Look for video URL in various response shapes
            let videoURLStr = (result?["video"] as? [String: Any])?["url"] as? String
                ?? (result?["video_url"] as? String)
                ?? ((result?["videos"] as? [[String: Any]])?.first?["url"] as? String)
            guard let str = videoURLStr, let url = URL(string: str) else {
                return .failed(message: "No video URL in fal.ai result")
            }
            return .succeeded(videoURL: url)
        default:
            fputs("{\"warning\":\"Unknown fal.ai status: \(status)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        }
    }

    func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        let cps = models.first { $0.modelId == modelId }?.costPerSecondUSD ?? 0.05
        return cps * durationSeconds
    }
}
