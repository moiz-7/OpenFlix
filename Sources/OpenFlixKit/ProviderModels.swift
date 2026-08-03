import Foundation

// MARK: - Provider model

public struct CLIProviderModel: Codable {
    public let providerId: String
    public let providerName: String
    public let modelId: String
    public let displayName: String
    public let defaultWidth: Int?
    public let defaultHeight: Int?
    public let maxDurationSeconds: Double?
    public let costPerSecondUSD: Double?
    public let supportsImageToVideo: Bool

    public init(providerId: String, providerName: String,
                modelId: String, displayName: String,
                defaultWidth: Int?, defaultHeight: Int?,
                maxDurationSeconds: Double?, costPerSecondUSD: Double?,
                supportsImageToVideo: Bool) {
        self.providerId = providerId
        self.providerName = providerName
        self.modelId = modelId
        self.displayName = displayName
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.maxDurationSeconds = maxDurationSeconds
        self.costPerSecondUSD = costPerSecondUSD
        self.supportsImageToVideo = supportsImageToVideo
    }

    public var jsonRepresentation: [String: Any] {
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

// MARK: - Provider protocol types

public struct GenerationRequest {
    public let prompt: String
    public let negativePrompt: String?
    public let referenceImageURL: URL?
    public let model: String
    public let width: Int?
    public let height: Int?
    public let durationSeconds: Double?
    public let aspectRatio: String?
    public let extraParams: [String: Any]

    public init(prompt: String, negativePrompt: String? = nil,
                referenceImageURL: URL? = nil, model: String,
                width: Int? = nil, height: Int? = nil,
                durationSeconds: Double? = nil, aspectRatio: String? = nil,
                extraParams: [String: Any] = [:]) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.referenceImageURL = referenceImageURL
        self.model = model
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.aspectRatio = aspectRatio
        self.extraParams = extraParams
    }

    /// Non-trapping integer duration for provider request bodies.
    ///
    /// `Int(Double)` traps (aborts the process) on NaN, ±infinity, and
    /// overflow. Only the `generate` command validates duration at the flag
    /// boundary — the workflow, MCP, batch, recipe, project and scatter-gather
    /// paths reach provider clients with whatever duration they were handed, so
    /// every provider that puts `Int(durationSeconds)` in its request body
    /// could crash the whole CLI on a hostile or buggy value. Returns nil (→
    /// the provider falls back to its own default) for a missing, non-finite,
    /// or non-positive duration, and clamps absurd values before the `Int`
    /// conversion.
    public func durationInt(max: Double = 3600) -> Int? {
        guard let d = durationSeconds, d.isFinite, d > 0 else { return nil }
        return Int(Swift.min(d, max).rounded())
    }
}

public struct GenerationSubmission {
    public let remoteTaskId: String
    public let statusURL: URL?
    public let estimatedCostUSD: Double?

    public init(remoteTaskId: String, statusURL: URL?, estimatedCostUSD: Double?) {
        self.remoteTaskId = remoteTaskId
        self.statusURL = statusURL
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public enum PollStatus {
    case queued
    case processing(progress: Double?)
    case succeeded(videoURL: URL)
    case failed(message: String)
}
