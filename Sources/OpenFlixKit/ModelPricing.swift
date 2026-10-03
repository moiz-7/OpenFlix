import Foundation

/// Single source of truth for per-model pricing (USD per second of output).
///
/// Provider clients read this table for both their model catalogs and their
/// cost estimates — do NOT add cost constants to provider files. The generic
/// `estimateCost` lives on the `VideoProvider` protocol extension
/// (ProviderProtocol.swift) and resolves through this table.
public enum ModelPricing {

    /// $/second by model id, at each model's default settings. Derived from
    /// `VideoModelCatalog` — edit prices there, not here. Model ids are unique
    /// across providers except where the app's "seedance" provider shares
    /// fal's Seedance endpoints, which carry the same price.
    public static let costPerSecondUSD: [String: Double] = {
        var table: [String: Double] = ["comfyui": 0.0]   // local — zero marginal cost
        for spec in VideoModelCatalog.all where table[spec.modelId] == nil {
            table[spec.modelId] = spec.defaultCostPerSecond
        }
        return table
    }()

    /// Fallback $/second when a model is missing from the table.
    public static let providerFallbackUSD: [String: Double] = [
        // An uncatalogued model on a known provider: priced near the top of
        // that provider's catalog, because under-estimating defeats the gate.
        "fal": 0.40, "replicate": 0.40, "runway": 0.40,
        "luma": 0.33, "kling": 0.17, "minimax": 0.13, "seedance": 0.70,
        "local": 0.0,
    ]

    public static let globalFallbackUSD = 0.40

    /// $/second for a model, falling back per provider, then globally.
    public static func costPerSecond(_ modelId: String, providerId: String) -> Double {
        costPerSecondUSD[modelId]
            ?? providerFallbackUSD[providerId]
            ?? globalFallbackUSD
    }

    /// Up-front estimate for one clip.
    ///
    /// For a catalogued model this is `VideoModelSpec.estimateUSD`: the
    /// duration is rounded UP to what the provider will actually make, and an
    /// unknown resolution/audio setting takes the highest matching rate — a
    /// budget gate must over-estimate, never under.
    ///
    /// Guards non-finite/negative durations — a `NaN` estimate silently defeats
    /// budget gates (every `NaN > limit` comparison is false), and a negative
    /// duration yields a negative "credit".
    public static func estimate(durationSeconds: Double, modelId: String, providerId: String,
                                resolution: String? = nil, audio: Bool? = nil) -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        if let spec = VideoModelCatalog.spec(provider: providerId, model: modelId) {
            return spec.estimateUSD(requestedSeconds: durationSeconds, resolution: resolution, audio: audio)
        }
        // A provider nobody has heard of cannot bill: ProviderRegistry refuses
        // it and GenerationEngine.submit throws before any network call, so
        // quoting the global fallback for it invents a cost that shows up in
        // plans and reservations. A *known* provider with an unlisted model is
        // the opposite case — that really can bill, so it keeps its provider
        // fallback rather than estimating $0 and skipping the budget gate.
        guard costPerSecondUSD[modelId] != nil || providerFallbackUSD[providerId] != nil else { return 0 }
        return costPerSecond(modelId, providerId: providerId) * durationSeconds
    }

    /// Resolution/audio a request asked for through its extra parameters, in
    /// the spellings the apps and providers use.
    public static func pricingHints(from params: [String: Any]) -> (resolution: String?, audio: Bool?) {
        let res = params["resolution"] as? String
        var audio: Bool? = nil
        for key in ["generate_audio", "audio", "native_audio"] {
            if let b = params[key] as? Bool { audio = b; break }
            if let s = params[key] as? String { audio = (s == "native" || s == "on" || s == "true"); break }
        }
        return (res, audio)
    }
}

extension CLIProviderModel {
    /// Model catalog entry with pricing sourced from ModelPricing — the only
    /// way provider clients should construct catalog entries.
    public static func priced(providerId: String, providerName: String,
                       modelId: String, displayName: String,
                       defaultWidth: Int?, defaultHeight: Int?,
                       maxDurationSeconds: Double?,
                       supportsImageToVideo: Bool) -> CLIProviderModel {
        CLIProviderModel(
            providerId: providerId, providerName: providerName,
            modelId: modelId, displayName: displayName,
            defaultWidth: defaultWidth, defaultHeight: defaultHeight,
            maxDurationSeconds: maxDurationSeconds,
            costPerSecondUSD: ModelPricing.costPerSecond(modelId, providerId: providerId),
            supportsImageToVideo: supportsImageToVideo
        )
    }
}
