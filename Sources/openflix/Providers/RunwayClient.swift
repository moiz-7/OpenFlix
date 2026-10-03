import Foundation
import OpenFlixKit

/// Runway's developer API (`api.dev.runwayml.com`, X-Runway-Version
/// 2024-11-06). Request shapes live in `RunwayWire`, from Runway's OpenAPI
/// document (verified 2026-09-27).
///
/// Two defects fixed by moving onto the shared wire: every request went to
/// `text_to_video` even with an image attached (image-to-video is its own
/// endpoint), and the ratio was sent as raw `width:height`, which Runway
/// accepts only from a short per-model list — so any size but 1280×720 was a
/// 400. The catalog now also includes Veo 3.1, which Runway serves.
final class RunwayClient: VideoProvider {
    let providerId = "runway"
    let displayName = "Runway"

    let models: [CLIProviderModel] = CLIProviderModel.catalog(provider: "runway", providerName: "Runway")

    private let session = makeSession()

    static var base: URL {
        ProcessInfo.processInfo.environment["OPENFLIX_RUNWAY_BASE_URL"].flatMap(URL.init(string:))
            ?? RunwayWire.defaultBase
    }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let plan = try buildPlan { try RunwayWire.plan(model: request.model, input: request.wireInput, base: Self.base) }
        let data = try await session.send(plan, auth: RunwayWire.authHeaders(apiKey: apiKey))
        return GenerationSubmission(
            remoteTaskId: try RunwayWire.parseSubmit(data),
            statusURL: nil,
            estimatedCostUSD: request.estimatedCost(providerId: providerId)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let data = try await session.get(RunwayWire.pollURL(taskId: taskId, base: Self.base),
                                         auth: RunwayWire.authHeaders(apiKey: apiKey))
        return Self.parsePollStatus(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Pure parsing of a Runway task response (kept for its tests).
    static func parsePollStatus(_ json: [String: Any]?) -> PollStatus {
        RunwayWire.parsePoll(json)
    }

    func cancel(taskId: String, statusURL: URL?, apiKey: String) async throws {
        var urlReq = URLRequest(url: RunwayWire.pollURL(taskId: taskId, base: Self.base))
        urlReq.httpMethod = "DELETE"
        for (k, v) in RunwayWire.authHeaders(apiKey: apiKey) { urlReq.setValue(v, forHTTPHeaderField: k) }
        _ = try await session.jsonData(for: urlReq)
    }
}
