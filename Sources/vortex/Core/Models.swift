import Foundation

// MARK: - Generation

struct CLIGeneration: Codable {
    var id: String
    var status: GenerationStatus
    var provider: String
    var model: String
    var prompt: String
    var negativePrompt: String?
    var aspectRatio: String?
    var widthPx: Int?
    var heightPx: Int?
    var durationSeconds: Double?
    var remoteTaskId: String?
    var statusURL: String?
    var remoteVideoURL: String?
    var localPath: String?
    var estimatedCostUSD: Double?
    var actualCostUSD: Double?
    var errorMessage: String?
    var retryCount: Int
    var projectId: String?
    var shotId: String?
    var createdAt: Date
    var submittedAt: Date?
    var completedAt: Date?

    enum GenerationStatus: String, Codable, CaseIterable {
        case queued, submitted, processing, succeeded, failed, cancelled
    }

    // MARK: - JSON output shape (agent-friendly snake_case)
    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "status": status.rawValue,
            "provider": provider,
            "model": model,
            "prompt": prompt,
            "retry_count": retryCount,
            "created_at": iso8601(createdAt),
        ]
        if let v = negativePrompt    { d["negative_prompt"]      = v }
        if let v = aspectRatio       { d["aspect_ratio"]          = v }
        if let v = widthPx           { d["width_px"]              = v }
        if let v = heightPx          { d["height_px"]             = v }
        if let v = durationSeconds   { d["duration_seconds"]      = v }
        if let v = remoteTaskId      { d["remote_task_id"]        = v }
        if let v = statusURL         { d["status_url"]             = v }
        if let v = remoteVideoURL    { d["remote_video_url"]      = v }
        if let v = localPath         { d["local_path"]            = v }
        if let v = estimatedCostUSD  { d["estimated_cost_usd"]    = round4(v) }
        if let v = actualCostUSD     { d["actual_cost_usd"]        = round4(v) }
        if let v = errorMessage      { d["error_message"]         = v }
        if let v = submittedAt       { d["submitted_at"]          = iso8601(v) }
        if let v = completedAt       { d["completed_at"]          = iso8601(v) }
        if let v = projectId         { d["project_id"]            = v }
        if let v = shotId            { d["shot_id"]               = v }
        return d
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
    private func round4(_ v: Double) -> Double {
        (v * 10000).rounded() / 10000
    }
}

// MARK: - Provider model

struct CLIProviderModel: Codable {
    let providerId: String
    let providerName: String
    let modelId: String
    let displayName: String
    let defaultWidth: Int?
    let defaultHeight: Int?
    let maxDurationSeconds: Double?
    let costPerSecondUSD: Double?
    let supportsImageToVideo: Bool

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "provider_id":   providerId,
            "provider_name": providerName,
            "model_id":      modelId,
            "display_name":  displayName,
            "supports_i2v":  supportsImageToVideo,
        ]
        if let v = defaultWidth         { d["default_width"]           = v }
        if let v = defaultHeight        { d["default_height"]          = v }
        if let v = maxDurationSeconds   { d["max_duration_seconds"]    = v }
        if let v = costPerSecondUSD     { d["cost_per_second_usd"]     = v }
        return d
    }
}

// MARK: - Provider error

enum VortexError: Error, LocalizedError {
    case noApiKey(String)
    case httpError(Int, String)
    case invalidResponse(String)
    case rateLimited(String, retryAfter: Int?)
    case providerNotFound(String)
    case timeout(String)
    case downloadFailed(URL, String)
    case generationNotFound(String)
    case generationFailed(String)
    case notComplete(String)
    case budgetExceeded(String)
    case promptBlocked([String])

    var errorDescription: String? {
        switch self {
        case .noApiKey(let p):            return "No API key for '\(p)'. Use: vortex keys set \(p) <key>"
        case .httpError(let c, let m):    return "HTTP \(c): \(m)"
        case .invalidResponse(let m):     return "Invalid response: \(m)"
        case .rateLimited(let p, let retryAfter):
            if let s = retryAfter { return "\(p) rate limit exceeded — retry in \(s)s" }
            return "\(p) rate limit exceeded — retry later"
        case .providerNotFound(let p):    return "Provider '\(p)' not found"
        case .timeout(let id):            return "Timed out waiting for generation \(id)"
        case .downloadFailed(let u, let m): return "Download failed from \(u): \(m)"
        case .generationNotFound(let id): return "Generation '\(id)' not found in store"
        case .generationFailed(let m):    return "Generation failed: \(m)"
        case .notComplete(let id):        return "Generation '\(id)' is not yet complete — use: vortex status \(id) --wait"
        case .budgetExceeded(let reason): return "Budget exceeded: \(reason)"
        case .promptBlocked(let flags):   return "Prompt blocked: \(flags.joined(separator: ", "))"
        }
    }

    var code: String {
        switch self {
        case .noApiKey:          return "no_api_key"
        case .httpError:         return "http_error"
        case .invalidResponse:   return "invalid_response"
        case .rateLimited(_, _): return "rate_limited"
        case .providerNotFound:  return "provider_not_found"
        case .timeout:           return "timeout"
        case .downloadFailed:    return "download_failed"
        case .generationNotFound: return "not_found"
        case .generationFailed:  return "generation_failed"
        case .notComplete:       return "not_complete"
        case .budgetExceeded:    return "budget_exceeded"
        case .promptBlocked:     return "prompt_blocked"
        }
    }

    /// Convert to structured error for MCP/agent consumption.
    var structured: StructuredError {
        StructuredError.from(self)
    }
}

// MARK: - Structured error taxonomy (agentic platform)

enum ErrorCode: String, Codable {
    // Auth
    case authMissing = "AUTH_MISSING"
    case authInvalid = "AUTH_INVALID"
    case authExpired = "AUTH_EXPIRED"
    // Provider
    case providerUnavailable = "PROVIDER_UNAVAILABLE"
    case providerRateLimited = "PROVIDER_RATE_LIMITED"
    case providerTimeout = "PROVIDER_TIMEOUT"
    case providerServerError = "PROVIDER_SERVER_ERROR"
    // Input
    case inputInvalid = "INPUT_INVALID"
    case inputTooLarge = "INPUT_TOO_LARGE"
    case promptUnsafe = "PROMPT_UNSAFE"
    // Resource
    case budgetExceeded = "BUDGET_EXCEEDED"
    case quotaExceeded = "QUOTA_EXCEEDED"
    case diskFull = "DISK_FULL"
    // Generation
    case generationFailed = "GENERATION_FAILED"
    case generationNotFound = "GENERATION_NOT_FOUND"
    case qualityBelowThreshold = "QUALITY_BELOW_THRESHOLD"
    case downloadFailed = "DOWNLOAD_FAILED"
    // System
    case internalError = "INTERNAL_ERROR"
    case configInvalid = "CONFIG_INVALID"
    case notComplete = "NOT_COMPLETE"

    var retryable: Bool {
        switch self {
        case .providerRateLimited, .providerTimeout, .providerServerError, .downloadFailed:
            return true
        default:
            return false
        }
    }

    var httpEquivalent: Int {
        switch self {
        case .authMissing, .authInvalid, .authExpired: return 401
        case .providerRateLimited: return 429
        case .providerTimeout: return 504
        case .providerServerError: return 502
        case .providerUnavailable: return 503
        case .inputInvalid, .inputTooLarge, .promptUnsafe, .configInvalid: return 400
        case .budgetExceeded, .quotaExceeded: return 402
        case .generationNotFound, .notComplete: return 404
        case .generationFailed, .downloadFailed, .diskFull, .qualityBelowThreshold: return 500
        case .internalError: return 500
        }
    }
}

struct StructuredError: Codable {
    let code: ErrorCode
    let message: String
    let details: [String: AnyCodableValue]?
    let retryable: Bool
    let retryAfterSeconds: Int?

    static func from(_ error: VortexError) -> StructuredError {
        switch error {
        case .noApiKey(let p):
            return StructuredError(code: .authMissing, message: error.errorDescription ?? "",
                                   details: ["provider": .string(p)], retryable: false, retryAfterSeconds: nil)
        case .httpError(let code, let msg):
            let ec: ErrorCode = (code == 429) ? .providerRateLimited :
                                (code >= 500) ? .providerServerError : .inputInvalid
            return StructuredError(code: ec, message: msg,
                                   details: ["http_status": .int(code)], retryable: ec.retryable, retryAfterSeconds: nil)
        case .invalidResponse(let m):
            return StructuredError(code: .inputInvalid, message: m,
                                   details: nil, retryable: false, retryAfterSeconds: nil)
        case .rateLimited(let p, let retryAfter):
            return StructuredError(code: .providerRateLimited, message: error.errorDescription ?? "",
                                   details: ["provider": .string(p)], retryable: true, retryAfterSeconds: retryAfter)
        case .providerNotFound(let p):
            return StructuredError(code: .providerUnavailable, message: error.errorDescription ?? "",
                                   details: ["provider": .string(p)], retryable: false, retryAfterSeconds: nil)
        case .timeout(let id):
            return StructuredError(code: .providerTimeout, message: error.errorDescription ?? "",
                                   details: ["generation_id": .string(id)], retryable: true, retryAfterSeconds: nil)
        case .downloadFailed(let url, let msg):
            return StructuredError(code: .downloadFailed, message: msg,
                                   details: ["url": .string(url.absoluteString)], retryable: true, retryAfterSeconds: nil)
        case .generationNotFound(let id):
            return StructuredError(code: .generationNotFound, message: error.errorDescription ?? "",
                                   details: ["generation_id": .string(id)], retryable: false, retryAfterSeconds: nil)
        case .generationFailed(let m):
            return StructuredError(code: .generationFailed, message: m,
                                   details: nil, retryable: false, retryAfterSeconds: nil)
        case .notComplete(let id):
            return StructuredError(code: .notComplete, message: error.errorDescription ?? "",
                                   details: ["generation_id": .string(id)], retryable: true, retryAfterSeconds: nil)
        case .budgetExceeded(let reason):
            return StructuredError(code: .budgetExceeded, message: reason,
                                   details: nil, retryable: false, retryAfterSeconds: nil)
        case .promptBlocked(let flags):
            return StructuredError(code: .promptUnsafe, message: "Prompt blocked by safety check",
                                   details: ["flags": .array(flags.map { .string($0) })], retryable: false, retryAfterSeconds: nil)
        }
    }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "code": code.rawValue,
            "message": message,
            "retryable": retryable,
        ]
        if let s = retryAfterSeconds { d["retry_after_seconds"] = s }
        if let details = details {
            var detailsDict: [String: Any] = [:]
            for (key, val) in details {
                detailsDict[key] = val.toAny()
            }
            d["details"] = detailsDict
        }
        return d
    }
}

// MARK: - Provider protocol types

struct GenerationRequest {
    let prompt: String
    let negativePrompt: String?
    let referenceImageURL: URL?
    let model: String
    let width: Int?
    let height: Int?
    let durationSeconds: Double?
    let aspectRatio: String?
    let extraParams: [String: Any]
}

struct GenerationSubmission {
    let remoteTaskId: String
    let statusURL: URL?
    let estimatedCostUSD: Double?
}

enum PollStatus {
    case queued
    case processing(progress: Double?)
    case succeeded(videoURL: URL)
    case failed(message: String)
}
