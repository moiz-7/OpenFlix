import Foundation
import OpenFlixKit

/// MiniMax. H3 / H3-Max (current) use the V2 API — a `content` array, polled
/// at `/v2/query/video_generation/{id}`. Hailuo 2.3 is "legacy" on V1 but still
/// served, and keeps V1's query → file-retrieve flow. Request shapes live in
/// `MiniMaxWire` (verified against platform.minimax.io/docs, 2026-09-27).
///
/// A V2 task's status URL is its V2 query URL, which is how `poll` tells the
/// two apart; V1 tasks keep a nil status URL exactly as before.
final class MiniMaxClient: VideoProvider {
    let providerId = "minimax"
    let displayName = "MiniMax"

    let models: [CLIProviderModel] = CLIProviderModel.catalog(provider: "minimax", providerName: "MiniMax")

    private let session = makeSession()
    private var base: URL { MiniMaxWire.defaultBase }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let plan = try buildPlan { try MiniMaxWire.plan(model: request.model, input: request.wireInput) }
        let data = try await session.send(plan, auth: MiniMaxWire.authHeaders(apiKey: apiKey))
        let taskId = try MiniMaxWire.parseSubmit(data)
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: MiniMaxWire.usesV2(request.model) ? MiniMaxWire.v2PollURL(taskId: taskId) : nil,
            estimatedCostUSD: request.estimatedCost(providerId: providerId)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let auth = MiniMaxWire.authHeaders(apiKey: apiKey)
        if MiniMaxWire.isV2PollURL(statusURL), let url = statusURL {
            return try MiniMaxWire.parseV2Poll(try await session.get(url, auth: auth))
        }

        // V1: query status, then resolve the file id to a download URL.
        var query = URLComponents(url: base.appendingPathComponent("v1/query/video_generation"), resolvingAgainstBaseURL: false)
        query?.queryItems = [URLQueryItem(name: "task_id", value: taskId)]
        guard let queryURL = query?.url else { return .failed(message: "MiniMax: failed to build query URL") }
        let json = try JSONSerialization.jsonObject(with: try await session.get(queryURL, auth: auth)) as? [String: Any]

        switch json?["status"] as? String ?? "" {
        case "Queueing", "Preparing": return .queued
        case "Processing":            return .processing(progress: nil)
        case "Success":
            guard let fileId = json?["file_id"] as? String else {
                return .failed(message: "No file_id in MiniMax Success response")
            }
            var retrieve = URLComponents(url: base.appendingPathComponent("v1/files/retrieve"), resolvingAgainstBaseURL: false)
            retrieve?.queryItems = [URLQueryItem(name: "file_id", value: fileId)]
            guard let retrieveURL = retrieve?.url else { return .failed(message: "MiniMax: failed to build retrieve URL") }
            let file = try JSONSerialization.jsonObject(with: try await session.get(retrieveURL, auth: auth)) as? [String: Any]
            guard let dl = (file?["file"] as? [String: Any])?["download_url"] as? String, let url = URL(string: dl) else {
                return .failed(message: "No download_url in MiniMax file retrieve")
            }
            return .succeeded(videoURL: url)
        case "Fail":
            return .failed(message: "MiniMax generation failed")
        default:
            return .queued
        }
    }
}
