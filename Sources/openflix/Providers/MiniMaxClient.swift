import Foundation

/// MiniMax has a 3-step flow:
/// 1. POST /v1/video_generation  → task_id
/// 2. GET  /v1/query/video_generation?task_id=  → status, file_id when done
/// 3. GET  /v1/files/retrieve?file_id=  → download_url
///
/// We encode the file_id in the poll response so step 3 happens in poll().
final class MiniMaxClient: VideoProvider {
    let providerId = "minimax"
    let displayName = "MiniMax"

    let models: [CLIProviderModel] = [
        CLIProviderModel(providerId: "minimax", providerName: "MiniMax",
            modelId: "MiniMax-Hailuo-2.3", displayName: "Hailuo 2.3",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, costPerSecondUSD: 0.05, supportsImageToVideo: false),
        CLIProviderModel(providerId: "minimax", providerName: "MiniMax",
            modelId: "T2V-01-Director", displayName: "T2V-01 Director",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 6, costPerSecondUSD: 0.04, supportsImageToVideo: false),
        CLIProviderModel(providerId: "minimax", providerName: "MiniMax",
            modelId: "S2V-01", displayName: "S2V-01 (I2V)",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 6, costPerSecondUSD: 0.05, supportsImageToVideo: true),
    ]

    private let session = makeSession()
    private static let base: URL = {
        guard let url = URL(string: "https://api.minimax.io/v1") else {
            fatalError("Invalid static MiniMax API URL")
        }
        return url
    }()
    private var base: URL { Self.base }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
        ]
        if let d = request.durationSeconds { body["duration"] = Int(d) }
        if let ref = request.referenceImageURL { body["first_frame_image"] = ref.absoluteString }

        var urlReq = URLRequest(url: base.appendingPathComponent("video_generation"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let baseResp = json?["base_resp"] as? [String: Any]
        guard let statusCode = baseResp?["status_code"] as? Int, statusCode == 0,
              let taskId = json?["task_id"] as? String else {
            let msg = baseResp?["status_msg"] as? String ?? "Unknown MiniMax error"
            throw OpenFlixError.invalidResponse("MiniMax: \(msg)")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: nil,
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 6, modelId: request.model)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        // Step 2: Query status
        guard var components = URLComponents(url: base.appendingPathComponent("query/video_generation"), resolvingAgainstBaseURL: false) else {
            return .failed(message: "MiniMax: failed to build query URL")
        }
        components.queryItems = [URLQueryItem(name: "task_id", value: taskId)]
        guard let queryURL = components.url else {
            return .failed(message: "MiniMax: failed to build query URL from components")
        }
        var urlReq = URLRequest(url: queryURL)
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = json?["status"] as? String ?? ""

        switch status {
        case "Queueing", "Preparing": return .queued
        case "Processing":            return .processing(progress: nil)
        case "Success":
            guard let fileId = json?["file_id"] as? String else {
                return .failed(message: "No file_id in MiniMax Success response")
            }
            // Step 3: Retrieve download URL
            guard var retrieveComponents = URLComponents(url: base.appendingPathComponent("files/retrieve"), resolvingAgainstBaseURL: false) else {
                return .failed(message: "MiniMax: failed to build retrieve URL")
            }
            retrieveComponents.queryItems = [URLQueryItem(name: "file_id", value: fileId)]
            guard let retrieveURL = retrieveComponents.url else {
                return .failed(message: "MiniMax: failed to build retrieve URL from components")
            }
            var retrieveReq = URLRequest(url: retrieveURL)
            retrieveReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (retrieveData, _) = try await session.jsonData(for: retrieveReq)
            let retrieveJson = try JSONSerialization.jsonObject(with: retrieveData) as? [String: Any]
            let fileObj = retrieveJson?["file"] as? [String: Any]
            guard let dlURL = fileObj?["download_url"] as? String, let url = URL(string: dlURL) else {
                return .failed(message: "No download_url in MiniMax file retrieve")
            }
            return .succeeded(videoURL: url)
        case "Fail":
            return .failed(message: "MiniMax generation failed")
        default:
            fputs("{\"warning\":\"Unknown MiniMax status: \(status)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        }
    }

    func estimateCost(durationSeconds: Double, modelId: String) -> Double? {
        let cps = models.first { $0.modelId == modelId }?.costPerSecondUSD ?? 0.05
        return cps * durationSeconds
    }
}
