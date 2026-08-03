import Foundation
import OpenFlixKit

final class RunwayClient: VideoProvider {
    let providerId = "runway"
    let displayName = "Runway"
    private let apiVersion = "2024-11-06"

    let models: [CLIProviderModel] = [
        .priced(providerId: "runway", providerName: "Runway",
            modelId: "gen4_turbo", displayName: "Gen-4 Turbo",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, supportsImageToVideo: true),
        .priced(providerId: "runway", providerName: "Runway",
            modelId: "gen4.5", displayName: "Gen-4.5",
            defaultWidth: 1280, defaultHeight: 720, maxDurationSeconds: 10, supportsImageToVideo: true),
    ]

    private let session = makeSession()

    /// Runway's public developer API is `api.dev.runwayml.com`;
    /// `api.runwayml.com` is the app backend and rejects these calls. The old
    /// hardcoded value was almost certainly never exercised against the live
    /// service (the X-Runway-Version header is correct, which is the tell of a
    /// doc-derived integration). Overridable so a base-URL change doesn't need
    /// a release.
    static let defaultBase = "https://api.dev.runwayml.com/v1"
    private static let base: URL = {
        let raw = ProcessInfo.processInfo.environment["OPENFLIX_RUNWAY_BASE_URL"] ?? defaultBase
        guard let url = URL(string: raw) else {
            guard let fallback = URL(string: defaultBase) else {
                fatalError("Invalid static Runway API URL")
            }
            fputs("{\"warning\":\"Invalid OPENFLIX_RUNWAY_BASE_URL, using default\",\"code\":\"invalid_base_url\"}\n", stderr)
            return fallback
        }
        return url
    }()
    private var base: URL { Self.base }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        var body: [String: Any] = [
            "model": request.model,
            "promptText": request.prompt,
        ]
        if let d = request.durationInt() { body["duration"] = d }
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
        return Self.parsePollStatus(json)
    }

    /// Pure parsing of a Runway task response — separated from the
    /// network fetch so it is unit-testable with canned JSON.
    static func parsePollStatus(_ json: [String: Any]?) -> PollStatus {
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


    func cancel(taskId: String, statusURL: URL?, apiKey: String) async throws {
        var urlReq = URLRequest(url: base.appendingPathComponent("tasks/\(taskId)"))
        urlReq.httpMethod = "DELETE"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue(apiVersion, forHTTPHeaderField: "X-Runway-Version")
        _ = try await session.jsonData(for: urlReq)
    }
}
