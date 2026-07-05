import Foundation

/// Single source of truth for per-model pricing (USD per second of output).
///
/// Provider clients read this table for both their model catalogs and their
/// cost estimates — do NOT add cost constants to provider files. The generic
/// `estimateCost` lives on the `VideoProvider` protocol extension
/// (ProviderProtocol.swift) and resolves through this table.
enum ModelPricing {

    /// $/second by model id. Model ids are unique across providers.
    static let costPerSecondUSD: [String: Double] = [
        // fal.ai
        "fal-ai/bytedance/seedance/v2/text-to-video":  0.05,
        "fal-ai/bytedance/seedance/v2/image-to-video": 0.06,
        "fal-ai/kling-video/v2/master/text-to-video":  0.06,
        "fal-ai/minimax/hailuo-02":                    0.05,
        "fal-ai/luma-dream-machine":                   0.08,
        "fal-ai/hunyuan-video":                        0.04,
        "fal-ai/wan/v2.1/1080p":                       0.03,
        "fal-ai/veo3":                                 0.15,
        // Replicate
        "minimax/video-01-live":                       0.05,
        "tencent/hunyuan-video":                       0.04,
        "wavespeed-ai/wan-2.1":                        0.03,
        "kwaai/kling-v1.6-pro":                        0.10,
        // Runway
        "gen4_turbo":                                  0.05,
        "gen4.5":                                      0.10,
        // Luma
        "ray-2":                                       0.10,
        "ray-flash-2":                                 0.05,
        "ray-3":                                       0.20,
        // Kling
        "kling-v2.6-pro":                              0.10,
        "kling-v2.6-std":                              0.05,
        "kling-v2.5-turbo":                            0.03,
        // MiniMax
        "MiniMax-Hailuo-2.3":                          0.05,
        "T2V-01-Director":                             0.04,
        "S2V-01":                                      0.05,
    ]

    /// Fallback $/second when a model is missing from the table.
    static let providerFallbackUSD: [String: Double] = [
        "fal": 0.05, "replicate": 0.05, "runway": 0.05,
        "luma": 0.10, "kling": 0.05, "minimax": 0.05,
    ]

    static let globalFallbackUSD = 0.05

    /// $/second for a model, falling back per provider, then globally.
    static func costPerSecond(_ modelId: String, providerId: String) -> Double {
        costPerSecondUSD[modelId]
            ?? providerFallbackUSD[providerId]
            ?? globalFallbackUSD
    }

    /// Up-front estimate: $/second × duration.
    static func estimate(durationSeconds: Double, modelId: String, providerId: String) -> Double {
        costPerSecond(modelId, providerId: providerId) * durationSeconds
    }
}

extension CLIProviderModel {
    /// Model catalog entry with pricing sourced from ModelPricing — the only
    /// way provider clients should construct catalog entries.
    static func priced(providerId: String, providerName: String,
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
