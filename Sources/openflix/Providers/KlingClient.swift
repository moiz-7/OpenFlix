import Foundation

final class KlingClient: VideoProvider {
    let providerId = "kling"
    let displayName = "Kling"

    let models: [CLIProviderModel] = [
        CLIProviderModel(providerId: "kling", providerName: "Kling",
            modelId: "kling-v2.6-pro", displayName: "Kling v2.6 Pro",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.10, supportsImageToVideo: true),
        CLIProviderModel(providerId: "kling", providerName: "Kling",
            modelId: "kling-v2.6-std", displayName: "Kling v2.6 Standard",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.05, supportsImageToVideo: true),
        CLIProviderModel(providerId: "kling", providerName: "Kling",
            modelId: "kling-v2.5-turbo", displayName: "Kling v2.5 Turbo",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 5, costPerSecondUSD: 0.03, supportsImageToVideo: true),
    ]

    private let session = makeSession()
    private static let base: URL = {
        guard let url = URL(string: "https://api.klingapi.com/v1") else {
            fatalError("Invalid static Kling API URL")
        }
        return url
    }()
    private var base: URL { Self.base }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let endpoint = request.referenceImageURL != nil ? "image_to_video" : "text_to_video"
        var body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
        ]
        if let d = request.durationSeconds { body["duration"] = Int(d) }
        if let ar = request.aspectRatio { body["aspect_ratio"] = ar }
        if let ref = request.referenceImageURL { body["image"] = ref.absoluteString }
        if let v = request.negativePrompt, !v.isEmpty { body["negative_prompt"] = v }

        var urlReq = URLRequest(url: base.appendingPathComponent("videos/\(endpoint)"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let code = json?["code"] as? Int, code == 0,
              let taskData = json?["data"] as? [String: Any],
              let taskId = taskData["task_id"] as? String else {
            let msg = (json?["message"] as? String) ?? "Unknown Kling error"
            throw VortexError.invalidResponse("Kling: \(msg)")
        }
        let pollPath = "videos/\(endpoint)/\(taskId)"
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: base.appendingPathComponent(pollPath),
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 5, modelId: request.model)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let pollURL = statusURL ?? base.appendingPathComponent("videos/text_to_video/\(taskId)")
        var urlReq = URLRequest(url: pollURL)
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let taskData = json?["data"] as? [String: Any]
        let status = taskData?["task_status"] as? String ?? ""

        switch status {
        case "submitted":   return .queued
        case "processing":  return .processing(progress: nil)
        case "succeed":
            let result = taskData?["task_result"] as? [String: Any]
            let videos = result?["videos"] as? [[String: Any]]
            guard let urlStr = videos?.first?["url"] as? String,
                  let url = URL(string: urlStr) else {
                return .failed(message: "No video in Kling result")
            }
            return .succeeded(videoURL: url)
        case "failed":
            return .failed(message: taskData?["task_status_msg"] as? String ?? "Kling generation failed")
        default:
            fputs("{\"warning\":\"Unknown Kling status: \(status)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        }
    }

    func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        let cps = models.first { $0.modelId == modelId }?.costPerSecondUSD ?? 0.05
        return cps * durationSeconds
    }
}
