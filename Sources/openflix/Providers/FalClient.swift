import Foundation
import OpenFlixKit

/// fal.ai's queue API. Request shapes live in `FalWire`; every endpoint's
/// field spellings come from fal's per-endpoint OpenAPI schema (2026-09-27).
///
/// Three catalog endpoints no longer existed at fal (Seedance v2, Hailuo-02,
/// Wan 2.1 1080p) and are now refused with their replacement named. Prices were
/// badly low — Kling 2 Master at $0.06/s against a real $0.28/s, Veo 3 at
/// $0.15/s against $0.40/s with the audio fal turns on by default — so the
/// budget gate let users overspend. Both live in `VideoModelCatalog` now.
final class FalClient: VideoProvider {
    let providerId = "fal"
    let displayName = "fal.ai"

    let models: [CLIProviderModel] = CLIProviderModel.catalog(provider: "fal", providerName: "fal.ai")

    private let session = makeSession()

    /// fal takes a local reference image by uploading it to fal's CDN.
    static func uploader(session: URLSession = .shared) -> ReferenceUploader {
        { image, apiKey in try await FalUpload.upload(image, apiKey: apiKey, session: session) }
    }

    func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let plan = try buildPlan { try FalWire.plan(model: request.model, input: request.wireInput) }
        let data = try await session.send(plan, auth: FalWire.authHeaders(apiKey: apiKey))
        let parsed = try FalWire.parseSubmit(data)
        guard let statusURL = parsed.statusURL else {
            throw OpenFlixError.invalidResponse("Missing status_url in fal.ai response")
        }
        return GenerationSubmission(
            remoteTaskId: parsed.id,
            statusURL: statusURL,
            estimatedCostUSD: request.estimatedCost(providerId: providerId)
        )
    }

    func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        guard let url = statusURL else {
            return .failed(message: "No status URL for fal.ai generation")
        }
        let auth = FalWire.authHeaders(apiKey: apiKey)
        let json = try JSONSerialization.jsonObject(with: try await session.get(url, auth: auth)) as? [String: Any]

        switch FalWire.parseStatus(json) {
        case .queued: return .queued
        case .running: return .processing(progress: nil)
        case .failed(let msg): return .failed(message: "fal.ai: \(msg)")
        case .unknown(let s):
            fputs("{\"warning\":\"Unknown fal.ai status: \(s)\",\"code\":\"unknown_status\"}\n", stderr)
            return .queued
        case .completed(let responseURL):
            guard let responseURL else {
                return .failed(message: "No response_url in fal.ai COMPLETED response")
            }
            let result = try JSONSerialization.jsonObject(with: try await session.get(responseURL, auth: auth)) as? [String: Any]
            guard let video = FalWire.videoURL(fromResult: result) else {
                return .failed(message: "No video URL in fal.ai result")
            }
            return .succeeded(videoURL: video)
        }
    }

    func cancel(taskId: String, statusURL: URL?, apiKey: String) async throws {
        // Status URL is https://queue.fal.run/{model_id}/requests/{request_id}/status;
        // the cancel endpoint is the same path with /cancel instead of /status.
        guard let statusURL = statusURL, statusURL.lastPathComponent == "status" else {
            throw OpenFlixError.invalidResponse("No status URL for fal.ai generation — cannot cancel")
        }
        var urlReq = URLRequest(url: statusURL.deletingLastPathComponent().appendingPathComponent("cancel"))
        urlReq.httpMethod = "PUT"
        urlReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await session.jsonData(for: urlReq)
    }
}
