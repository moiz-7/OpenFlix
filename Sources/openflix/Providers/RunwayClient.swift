import Foundation

final class RunwayClient: VideoProvider {
    let providerId = "runway"
    let displayName = "Runway"
    private let apiVersion = "2024-11-06"

    let models: [CLIProviderModel] = [
        CLIProviderModel(providerId: "runway", providerName: "Runway",
            modelId: "gen4_turbo", displayName: "Gen-4 Turbo",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.05, supportsImageToVideo: true),
        CLIProviderModel(providerId: "runway", providerName: "Runway",
            modelId: "gen4.5", displayName: "Gen-4.5",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.10, supportsImageToVideo: true),
    ]

    private let session = makeSession()
    private static let base: URL = {
        guard let url = URL(string: "https://api.runwayml.com/v1") else {
            fatalError("Invalid static Runway API URL")
        }
        return url
    }()
    private var base: URL { Self.base }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var body: [String: Any] = [
            "model": request.model,
            "promptText": request.prompt,
        ]
        if let d = request.durationSeconds { body["duration"] = Int(d) }
        let w = request.width ?? 1280, h = request.height ?? 720
        body["ratio"] = "\(w):\(h)"
        if let ref = request.referenceImageURL {
            body["promptImage"] = ref.absoluteString
        }

        var urlReq = URLRequest(url: base.appendingPathComponent("text_to_video"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue(apiVersion, forHTTPHeaderField: "X-Runway-Version")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw OpenFlixError.invalidResponse("Missing id in Runway response")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: nil,
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 5, modelId: request.model)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        var urlReq = URLRequest(url: base.appendingPathComponent("tasks/\(taskId)"))
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue(apiVersion, forHTTPHeaderField: "X-Runway-Version")

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = json?["status"] as? String ?? ""

        switch status {
        case "PENDING", "THROTTLED": return .queued
        case "RUNNING":
            let progress = (json?["progress"] as? Double) ?? (json?["progress"] as? NSNumber).map { Double(truncating: $0) }
            return .processing(progress: progress)
        case "SUCCEEDED":
            let outputs = json?["output"] as? [String]
            guard let first = outputs?.first, let url = URL(string: first) else {
                return .failed(message: "No output in Runway response")
            }
            return .succeeded(videoURL: url)
        case "FAILED":
            return .failed(message: json?["failure"] as? String ?? "Runway generation failed")
        default:
            fputs("{\"warning\":\"Unknown Runway status: \(status)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        }
    }

    func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        let cps = models.first { $0.modelId == modelId }?.costPerSecondUSD ?? 0.05
        return cps * durationSeconds
    }
}
