import Foundation
import OpenFlixKit

final class LumaClient: VideoProvider {
    let providerId = "luma"
    let displayName = "Luma"

    let models: [CLIProviderModel] = CLIProviderModel.catalog(provider: "luma", providerName: "Luma")

    private let session = makeSession()
    private var base: URL { LumaWire.defaultBase }

    private func auth(_ apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"]
    }

    /// Luma takes images by public URL only — `GenerationEngine.submit`
    /// refuses a local file for Luma before this is reached (see
    /// `ReferenceTransport.forProvider`). Shapes live in `LumaWire`.
    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let plan = try buildPlan { try LumaWire.plan(model: request.model, input: request.wireInput) }
        let data = try await session.send(plan, auth: auth(apiKey))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let taskId = json?["id"] as? String else {
            throw OpenFlixError.invalidResponse("Missing id in Luma response")
        }
        return GenerationSubmission(
            remoteTaskId: taskId,
            statusURL: nil,
            estimatedCostUSD: request.estimatedCost(providerId: providerId)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let data = try await session.get(base.appendingPathComponent("generations/\(taskId)"), auth: auth(apiKey))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let state = json?["state"] as? String ?? ""

        switch state {
        case "queued", "pending": return .queued
        case "dreaming":          return .processing(progress: nil)
        case "completed":
            let assets = json?["assets"] as? [String: Any]
            guard let str = assets?["video"] as? String, let url = URL(string: str) else {
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
}
