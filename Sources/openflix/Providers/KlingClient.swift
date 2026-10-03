import Foundation
import OpenFlixKit

/// Kling's "new standard" API (kling.ai/document-api, verified 2026-09-27).
///
/// The previous client posted to `/v1/videos/text_to_video` with a `model`
/// field — a path that exists in neither of Kling's API standards, so every
/// call failed. The long-standing note that Kling "needs a signed JWT" was also
/// out of date: the new standard authenticates with a plain API key as a bearer
/// token, and puts the model in the path (`POST /text-to-video/kling-2.6`).
/// AK/SK JWTs apply only to the legacy `model_name` endpoints, which new
/// endpoints reject with 401/1002. Request shapes live in `KlingWire`.
final class KlingClient: VideoProvider {
    let providerId = "kling"
    let displayName = "Kling"

    let models: [CLIProviderModel] = CLIProviderModel.catalog(provider: "kling", providerName: "Kling")

    private let session = makeSession()

    static var base: URL {
        ProcessInfo.processInfo.environment["OPENFLIX_KLING_BASE_URL"].flatMap(URL.init(string:))
            ?? KlingWire.defaultBase
    }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let plan = try buildPlan { try KlingWire.plan(model: request.model, input: request.wireInput, base: Self.base) }
        let data = try await session.send(plan, auth: KlingWire.authHeaders(apiKey: apiKey))
        let taskId = try KlingWire.parseSubmit(data)
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: KlingWire.pollURL(taskId: taskId, base: Self.base),
            estimatedCostUSD: request.estimatedCost(providerId: providerId)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let url = statusURL ?? KlingWire.pollURL(taskId: taskId, base: Self.base)
        let data = try await session.get(url, auth: KlingWire.authHeaders(apiKey: apiKey))
        return try KlingWire.parsePoll(data)
    }
}
