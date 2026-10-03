import Foundation

// MARK: - Video model catalog
//
// One table, shared by the CLI and the Mac app, describing every model we can
// call: which endpoints it has, what durations and aspect ratios it accepts,
// how the provider wants each field spelled, and what it costs.
//
// Every row was checked on 2026-09-27 against the provider's own machine
// readable documentation, not remembered:
//
// * Kling    — kling.ai/document-api/llms.txt (the "new standard" API)
// * Runway   — docs.dev.runwayml.com/openapi.json + /guides/pricing
// * MiniMax  — platform.minimax.io/docs/llms.txt (V2 for H3, V1 for Hailuo 2.3)
// * fal      — fal.ai/api/openapi/queue/openapi.json?endpoint_id=… + model pages
// * Replicate— replicate.com/<model>/api/schema + model pages
// * Luma     — docs.lumalabs.ai (Dream Machine API; pricing NOT re-verified)
//
// Before this table the two apps each carried their own model lists and price
// constants, and they had drifted from the providers: three fal endpoints and
// two Replicate models no longer existed, `ray-3` was never in Luma's API, the
// Kling client called paths that exist in neither of Kling's API standards, and
// the budget gate priced fal's Kling 2 Master at $0.06/s against a real $0.28/s.
//
// Pricing rule: when a request's resolution or audio setting is unknown, the
// estimate uses the HIGHEST matching rate. A budget gate that under-estimates
// is a gate that lets the user overspend.

public struct VideoModelSpec {

    public enum Durations: Equatable {
        /// The provider accepts exactly these seconds.
        case choices([Int])
        /// Any whole number of seconds in this range.
        case range(Int, Int)
        /// The model has no duration field; clips are always this long.
        case fixed(Int)
    }

    /// How the duration field is spelled on the wire.
    public enum DurationFormat { case int, string, secondsSuffix, none }

    /// How an aspect ratio is expressed on the wire.
    public enum AspectStyle {
        case ratio           // "16:9"
        case runwayPixels    // "1280:720", from a per-model list
        case soraOrientation // "landscape" / "portrait"
        case wanSize         // "1280*720"
        case none
    }

    /// One price point. `resolution`/`audio` of nil match anything.
    public struct Rate: Equatable {
        public let resolution: String?
        public let audio: Bool?
        public let perSecond: Double?
        public let perVideo: Double?

        public static func second(_ usd: Double, _ resolution: String? = nil, audio: Bool? = nil) -> Rate {
            Rate(resolution: resolution, audio: audio, perSecond: usd, perVideo: nil)
        }
        public static func video(_ usd: Double, _ resolution: String? = nil, audio: Bool? = nil) -> Rate {
            Rate(resolution: resolution, audio: audio, perSecond: nil, perVideo: usd)
        }
    }

    public let providerId: String
    public let modelId: String
    public let displayName: String
    /// The provider's name for the text-to-video variant (model id, path
    /// segment, endpoint id or slug). nil: the model needs an image.
    public let textEndpoint: String?
    /// The image-to-video variant. nil: text only.
    public let imageEndpoint: String?
    public let durations: Durations
    public let defaultDuration: Int
    public let durationKey: String
    public let durationFormat: DurationFormat
    /// Field carrying the reference image (fal / Replicate differ per model).
    public let imageKey: String
    public let aspectStyle: AspectStyle
    /// Accepted aspect values for text-to-video, in the provider's spelling.
    public let aspectRatios: [String]
    /// Accepted aspect values for image-to-video (Runway differs by mode).
    public let imageAspectRatios: [String]
    /// Resolution we send (or the provider's default when we send none).
    public let defaultResolution: String?
    /// nil: the model makes no audio. Otherwise the provider's default.
    public let audioDefault: Bool?
    public let rates: [Rate]
    public let defaultWidth: Int
    public let defaultHeight: Int
    /// A model outside the catalog on a free-form provider (any fal endpoint,
    /// any Replicate slug or version hash). Fields pass through as given and
    /// pricing falls back to the provider's conservative rate.
    public private(set) var isGeneric = false

    public var supportsTextToVideo: Bool { textEndpoint != nil }
    public var supportsImageToVideo: Bool { imageEndpoint != nil }

    public init(provider: String, id: String, name: String,
                text: String?, image: String?,
                durations: Durations, defaultDuration: Int? = nil,
                durationKey: String = "duration", durationFormat: DurationFormat = .int,
                imageKey: String = "image_url",
                aspect: AspectStyle = .ratio, ratios: [String] = [], imageRatios: [String]? = nil,
                resolution: String? = nil, audio: Bool? = nil,
                rates: [Rate], width: Int = 1280, height: Int = 720) {
        self.providerId = provider
        self.modelId = id
        self.displayName = name
        self.textEndpoint = text
        self.imageEndpoint = image
        self.durations = durations
        switch durations {
        case .fixed(let s): self.defaultDuration = s
        case .choices(let c): self.defaultDuration = defaultDuration ?? c.first ?? 5
        case .range(let lo, _): self.defaultDuration = defaultDuration ?? max(lo, 5)
        }
        self.durationKey = durationKey
        self.durationFormat = durationFormat
        self.imageKey = imageKey
        self.aspectStyle = aspect
        self.aspectRatios = ratios
        self.imageAspectRatios = imageRatios ?? ratios
        self.defaultResolution = resolution
        self.audioDefault = audio
        self.rates = rates
        self.defaultWidth = width
        self.defaultHeight = height
    }

    /// A permissive spec for an uncatalogued fal endpoint or Replicate model:
    /// both modes allowed, duration passed through, aspect passed through.
    public static func generic(provider: String, model: String) -> VideoModelSpec {
        var s = VideoModelSpec(provider: provider, id: model, name: model,
                               text: model, image: model,
                               durations: .range(1, 60), defaultDuration: 5,
                               durationFormat: provider == "replicate" ? .int : .string,
                               aspect: .ratio,
                               rates: [.second(ModelPricing.providerFallbackUSD[provider] ?? ModelPricing.globalFallbackUSD)])
        s.isGeneric = true
        return s
    }

    // MARK: Duration

    /// The seconds actually requested from — and billed by — the provider.
    ///
    /// Rounds UP to the nearest accepted value, so a 5 s request on a model
    /// that takes 4/6/8 becomes 6, never 4: the user gets at least what they
    /// asked for and the estimate covers what they will pay. Missing or
    /// non-finite input takes the model default.
    public func billedSeconds(requested: Double?) -> Int {
        // Clamp BEFORE converting: `Int(Double)` traps on values past Int.max,
        // and agent/workflow paths reach here with unvalidated durations.
        let want: Int? = requested.flatMap { $0.isFinite && $0 > 0 ? Int(Swift.min($0, 86_400).rounded(.up)) : nil }
        switch durations {
        case .fixed(let s):
            return s
        case .choices(let c):
            let sorted = c.sorted()
            guard let want else { return defaultDuration }
            return sorted.first(where: { $0 >= want }) ?? sorted.last ?? defaultDuration
        case .range(let lo, let hi):
            guard let want else { return defaultDuration }
            return min(max(want, lo), hi)
        }
    }

    /// The longest clip this model can make.
    public var maxSeconds: Int {
        switch durations {
        case .fixed(let s): return s
        case .choices(let c): return c.max() ?? defaultDuration
        case .range(_, let hi): return hi
        }
    }

    public var allowedSeconds: [Int] {
        switch durations {
        case .fixed(let s): return [s]
        case .choices(let c): return c.sorted()
        case .range(let lo, let hi): return Array(lo...hi)
        }
    }

    /// The duration value as the provider wants it spelled.
    public func wireDuration(_ seconds: Int) -> Any? {
        switch durationFormat {
        case .int: return seconds
        case .string: return String(seconds)
        case .secondsSuffix: return "\(seconds)s"
        case .none: return nil
        }
    }

    // MARK: Aspect ratio

    /// Picks the accepted aspect value closest to what was asked for.
    ///
    /// `requested` may be "16:9", "1280:720", or nil (then width/height, then
    /// the model default). Always returns a value the provider accepts, so a
    /// 1920×1080 request on a model that only takes "1280:720" / "720:1280"
    /// becomes "1280:720" instead of a 400.
    public func wireAspect(requested: String?, width: Int?, height: Int?, forImage: Bool) -> String? {
        let options = forImage ? imageAspectRatios : aspectRatios
        if isGeneric { return requested }
        guard aspectStyle != .none, !options.isEmpty else { return nil }
        let target = Self.aspectValue(requested) ??
            ((width ?? 0) > 0 && (height ?? 0) > 0 ? Double(width!) / Double(height!) : nil) ??
            (Double(defaultWidth) / Double(defaultHeight))
        if let requested, options.contains(requested) { return requested }
        return options
            .compactMap { opt -> (String, Double)? in Self.aspectValue(opt).map { (opt, $0) } }
            .min(by: { abs(log($0.1 / target)) < abs(log($1.1 / target)) })?.0
            ?? options.first
    }

    static func aspectValue(_ s: String?) -> Double? {
        guard let s else { return nil }
        switch s {
        case "landscape": return 16.0 / 9.0
        case "portrait":  return 9.0 / 16.0
        default: break
        }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "*" || $0 == "x" }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    // MARK: Pricing

    /// Estimated USD for one clip. Unknown resolution/audio → the highest
    /// matching rate (see the pricing rule at the top of this file).
    public func estimateUSD(requestedSeconds: Double?, resolution: String? = nil, audio: Bool? = nil) -> Double {
        let seconds = Double(billedSeconds(requested: requestedSeconds))
        let res = resolution ?? defaultResolution
        let aud = audio ?? audioDefault
        func matches(_ r: Rate) -> Bool {
            (r.resolution == nil || res == nil || r.resolution?.lowercased() == res?.lowercased())
                && (r.audio == nil || aud == nil || r.audio == aud)
        }
        let candidates = rates.filter(matches)
        let pool = candidates.isEmpty ? rates : candidates
        let costs = pool.map { r -> Double in
            if let v = r.perVideo { return v }
            return (r.perSecond ?? 0) * seconds
        }
        return costs.max() ?? 0
    }

    /// $/second at this model's default settings — for catalogs and display.
    public var defaultCostPerSecond: Double {
        let d = Double(defaultDuration)
        return d > 0 ? estimateUSD(requestedSeconds: d) / d : 0
    }
}

// MARK: - The catalog

public enum VideoModelCatalog {

    public static let all: [VideoModelSpec] = kling + runway + minimax + fal + seedance + replicate + luma

    // Kling — https://api-singapore.klingai.com, `Authorization: Bearer <API key>`.
    // "New standard": model in the PATH, e.g. POST /text-to-video/kling-2.6.
    // The two 2.6 rows keep their historical ids; they differ only in the
    // resolution sent (Kling's old pro/std modes are 1080p/720p here).
    public static let kling: [VideoModelSpec] = [
        .init(provider: "kling", id: "kling-3.0-turbo", name: "Kling 3.0 Turbo",
              text: "kling-3.0-turbo", image: "kling-3.0-turbo",
              durations: .range(3, 15), defaultDuration: 5,
              ratios: ["16:9", "9:16", "1:1"], resolution: "720p",
              rates: [.second(0.112, "720p"), .second(0.14, "1080p")]),
        .init(provider: "kling", id: "kling-3.0", name: "Kling 3.0",
              text: "kling-3.0", image: "kling-3.0",
              durations: .range(3, 15), defaultDuration: 5,
              ratios: ["16:9", "9:16", "1:1"], resolution: "720p", audio: false,
              rates: [.second(0.084, "720p", audio: false), .second(0.112, "1080p", audio: false),
                      .second(0.126, "720p", audio: true), .second(0.168, "1080p", audio: true),
                      .second(0.42, "4k")]),
        .init(provider: "kling", id: "kling-v2.6-pro", name: "Kling 2.6 Pro (1080p)",
              text: "kling-2.6", image: "kling-2.6",
              durations: .choices([5, 10]),
              ratios: ["16:9", "9:16", "1:1"], resolution: "1080p", audio: false,
              rates: [.second(0.07, "1080p", audio: false), .second(0.14, "1080p", audio: true)],
              width: 1920, height: 1080),
        .init(provider: "kling", id: "kling-v2.6-std", name: "Kling 2.6 Standard (720p)",
              text: "kling-2.6", image: "kling-2.6",
              durations: .choices([5, 10]),
              ratios: ["16:9", "9:16", "1:1"], resolution: "720p", audio: false,
              rates: [.second(0.042, "720p", audio: false)]),
        .init(provider: "kling", id: "kling-v2.5-turbo", name: "Kling 2.5 Turbo",
              text: "kling-2.5-turbo", image: "kling-2.5-turbo",
              durations: .choices([5, 10]),
              ratios: ["16:9", "9:16", "1:1"], resolution: "720p",
              rates: [.second(0.042, "720p"), .second(0.07, "1080p")]),
    ]

    // Runway — https://api.dev.runwayml.com/v1, X-Runway-Version 2024-11-06.
    // Ratios are pixel strings and differ between text and image mode.
    // 1 credit = $0.01.
    public static let runway: [VideoModelSpec] = [
        .init(provider: "runway", id: "gen4.5", name: "Gen-4.5",
              text: "gen4.5", image: "gen4.5",
              durations: .range(2, 10), defaultDuration: 5,
              aspect: .runwayPixels, ratios: ["1280:720", "720:1280"],
              imageRatios: ["1280:720", "720:1280", "1104:832", "960:960", "832:1104", "1584:672"],
              rates: [.second(0.12)]),
        .init(provider: "runway", id: "gen4_turbo", name: "Gen-4 Turbo (image required)",
              text: nil, image: "gen4_turbo",
              durations: .range(2, 10), defaultDuration: 5,
              aspect: .runwayPixels,
              imageRatios: ["1280:720", "720:1280", "1104:832", "832:1104", "960:960", "1584:672"],
              rates: [.second(0.05)]),
        .init(provider: "runway", id: "veo3.1", name: "Veo 3.1 (via Runway)",
              text: "veo3.1", image: "veo3.1",
              durations: .choices([4, 6, 8]), defaultDuration: 8,
              aspect: .runwayPixels, ratios: ["1280:720", "720:1280", "1920:1080", "1080:1920"],
              audio: true,
              rates: [.second(0.40, audio: true), .second(0.20, audio: false)]),
        .init(provider: "runway", id: "veo3.1_fast", name: "Veo 3.1 Fast (via Runway)",
              text: "veo3.1_fast", image: "veo3.1_fast",
              durations: .choices([4, 6, 8]), defaultDuration: 8,
              aspect: .runwayPixels, ratios: ["1280:720", "720:1280", "1920:1080", "1080:1920"],
              audio: true,
              rates: [.second(0.15, audio: true), .second(0.10, audio: false)]),
    ]

    // MiniMax — https://api.minimax.io. H3 / H3-Max use the V2 endpoint
    // (content array); Hailuo 2.3 is "legacy" on V1 but still served.
    public static let minimax: [VideoModelSpec] = [
        .init(provider: "minimax", id: "MiniMax-H3", name: "MiniMax H3",
              text: "MiniMax-H3", image: "MiniMax-H3",
              durations: .range(4, 15), defaultDuration: 6,
              ratios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9"], resolution: "768P",
              rates: [.second(0.08, "768P"), .second(0.13, "2K")]),
        .init(provider: "minimax", id: "MiniMax-H3-Max", name: "MiniMax H3 Max (fast)",
              text: "MiniMax-H3-Max", image: "MiniMax-H3-Max",
              durations: .range(5, 15), defaultDuration: 6,
              ratios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9"], resolution: "768P",
              rates: [.second(0.05, "480P"), .second(0.08, "768P")]),
        .init(provider: "minimax", id: "MiniMax-Hailuo-2.3", name: "Hailuo 2.3 (legacy)",
              text: "MiniMax-Hailuo-2.3", image: "MiniMax-Hailuo-2.3",
              durations: .choices([6, 10]), aspect: .none, resolution: "768P",
              // $0.28/6s and $0.56/10s at 768P; $0.49/6s at 1080P.
              rates: [.second(0.056, "768P"), .second(0.0817, "1080P")]),
    ]

    // fal — https://queue.fal.run/<endpoint>, `Authorization: Key <key>`.
    // Field spellings differ per endpoint and are copied from each schema.
    public static let fal: [VideoModelSpec] = [
        .init(provider: "fal", id: "fal-ai/veo3.1", name: "Veo 3.1",
              text: "fal-ai/veo3.1", image: "fal-ai/veo3.1/image-to-video",
              durations: .choices([4, 6, 8]), defaultDuration: 8, durationFormat: .secondsSuffix,
              ratios: ["16:9", "9:16"], resolution: "720p", audio: true,
              rates: [.second(0.40, "720p", audio: true), .second(0.20, "720p", audio: false),
                      .second(0.40, "1080p", audio: true), .second(0.20, "1080p", audio: false),
                      .second(0.60, "4k", audio: true), .second(0.40, "4k", audio: false)]),
        .init(provider: "fal", id: "fal-ai/veo3.1/fast", name: "Veo 3.1 Fast",
              text: "fal-ai/veo3.1/fast", image: "fal-ai/veo3.1/fast/image-to-video",
              durations: .choices([4, 6, 8]), defaultDuration: 8, durationFormat: .secondsSuffix,
              ratios: ["16:9", "9:16"], resolution: "720p", audio: true,
              rates: [.second(0.15, audio: true), .second(0.10, audio: false),
                      .second(0.35, "4k")]),
        .init(provider: "fal", id: "fal-ai/sora-2/text-to-video", name: "Sora 2",
              text: "fal-ai/sora-2/text-to-video", image: "fal-ai/sora-2/image-to-video",
              durations: .choices([4, 8, 12, 16, 20]), defaultDuration: 4,
              ratios: ["16:9", "9:16"],
              rates: [.second(0.10)]),
        .init(provider: "fal", id: "fal-ai/kling-video/v3/pro/text-to-video", name: "Kling 3.0 Pro (fal)",
              text: "fal-ai/kling-video/v3/pro/text-to-video", image: "fal-ai/kling-video/v3/pro/image-to-video",
              durations: .range(3, 15), defaultDuration: 5, durationFormat: .string,
              imageKey: "start_image_url",
              ratios: ["16:9", "9:16", "1:1"], audio: true,
              rates: [.second(0.168, audio: true), .second(0.112, audio: false)]),
        .init(provider: "fal", id: "bytedance/seedance-2.0/text-to-video", name: "Seedance 2.0",
              text: "bytedance/seedance-2.0/text-to-video", image: "bytedance/seedance-2.0/image-to-video",
              durations: .range(4, 15), defaultDuration: 5, durationFormat: .string,
              ratios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9"], resolution: "720p", audio: true,
              rates: [.second(0.3034, "720p"), .second(0.682, "1080p")]),
        .init(provider: "fal", id: "fal-ai/minimax/hailuo-2.3/pro/text-to-video", name: "Hailuo 2.3 Pro (fal)",
              text: "fal-ai/minimax/hailuo-2.3/pro/text-to-video", image: "fal-ai/minimax/hailuo-2.3/pro/image-to-video",
              durations: .fixed(6), durationFormat: .none, aspect: .none,
              rates: [.video(0.49)], width: 1920, height: 1080),
        .init(provider: "fal", id: "fal-ai/wan-25-preview/text-to-video", name: "Wan 2.5",
              text: "fal-ai/wan-25-preview/text-to-video", image: "fal-ai/wan-25-preview/image-to-video",
              durations: .choices([5, 10]), durationFormat: .string,
              ratios: ["16:9", "9:16", "1:1"], resolution: "1080p",
              rates: [.second(0.05, "480p"), .second(0.10, "720p"), .second(0.15, "1080p")],
              width: 1920, height: 1080),
        .init(provider: "fal", id: "fal-ai/ltx-2/text-to-video", name: "LTX-2",
              text: "fal-ai/ltx-2/text-to-video", image: "fal-ai/ltx-2/image-to-video",
              durations: .choices([6, 8, 10]), aspect: .none, resolution: "1080p", audio: true,
              rates: [.second(0.06, "1080p"), .second(0.12, "1440p"), .second(0.24, "2160p")],
              width: 1920, height: 1080),
        .init(provider: "fal", id: "fal-ai/veo3", name: "Veo 3",
              text: "fal-ai/veo3", image: nil,
              durations: .choices([4, 6, 8]), defaultDuration: 8, durationFormat: .secondsSuffix,
              ratios: ["16:9", "9:16"], resolution: "720p", audio: true,
              rates: [.second(0.40, audio: true), .second(0.20, audio: false)]),
        .init(provider: "fal", id: "fal-ai/kling-video/v2/master/text-to-video", name: "Kling 2 Master (fal)",
              text: "fal-ai/kling-video/v2/master/text-to-video", image: nil,
              durations: .choices([5, 10]), durationFormat: .string,
              ratios: ["16:9", "9:16", "1:1"],
              rates: [.second(0.28)]),
        .init(provider: "fal", id: "fal-ai/luma-dream-machine", name: "Luma Dream Machine (fal)",
              text: "fal-ai/luma-dream-machine", image: nil,
              durations: .fixed(5), durationFormat: .none,
              ratios: ["16:9", "9:16", "4:3", "3:4", "21:9", "9:21"],
              rates: [.video(0.50)]),
        .init(provider: "fal", id: "fal-ai/hunyuan-video", name: "HunyuanVideo (fal)",
              text: "fal-ai/hunyuan-video", image: nil,
              durations: .fixed(5), durationFormat: .none,
              ratios: ["16:9", "9:16"], resolution: "720p",
              rates: [.video(0.40)]),
    ]

    /// The Mac app's "Seedance" provider is fal underneath (ByteDance's own
    /// API is region-restricted) and uses a fal key. Same endpoints, same
    /// prices, listed under its own provider id.
    public static let seedance: [VideoModelSpec] = fal
        .filter { $0.modelId.hasPrefix("bytedance/seedance") }
        .map {
            .init(provider: "seedance", id: $0.modelId, name: $0.displayName,
                  text: $0.textEndpoint, image: $0.imageEndpoint,
                  durations: $0.durations, defaultDuration: $0.defaultDuration,
                  durationFormat: $0.durationFormat, imageKey: $0.imageKey,
                  ratios: $0.aspectRatios, resolution: $0.defaultResolution, audio: $0.audioDefault,
                  rates: $0.rates)
        }

    // Replicate — POST /v1/models/{owner}/{name}/predictions with {"input": …}.
    public static let replicate: [VideoModelSpec] = [
        .init(provider: "replicate", id: "google/veo-3.1", name: "Veo 3.1 (Replicate)",
              text: "google/veo-3.1", image: "google/veo-3.1",
              durations: .choices([4, 6, 8]), defaultDuration: 8,
              imageKey: "image", ratios: ["16:9", "9:16"], resolution: "1080p", audio: true,
              rates: [.second(0.40, audio: true), .second(0.20, audio: false)],
              width: 1920, height: 1080),
        .init(provider: "replicate", id: "kwaivgi/kling-v2.6", name: "Kling 2.6 (Replicate)",
              text: "kwaivgi/kling-v2.6", image: "kwaivgi/kling-v2.6",
              durations: .choices([5, 10]),
              imageKey: "start_image", ratios: ["16:9", "9:16", "1:1"], audio: true,
              rates: [.second(0.14, audio: true), .second(0.07, audio: false)]),
        .init(provider: "replicate", id: "openai/sora-2", name: "Sora 2 (Replicate)",
              text: "openai/sora-2", image: "openai/sora-2",
              durations: .choices([4, 8, 12]), defaultDuration: 4, durationKey: "seconds",
              imageKey: "input_reference", aspect: .soraOrientation, ratios: ["landscape", "portrait"],
              rates: [.second(0.10)]),
        .init(provider: "replicate", id: "wan-video/wan-2.5-t2v", name: "Wan 2.5 (Replicate)",
              text: "wan-video/wan-2.5-t2v", image: "wan-video/wan-2.5-i2v",
              durations: .choices([5, 10]),
              imageKey: "image", aspect: .wanSize,
              ratios: ["1280*720", "720*1280", "1920*1080", "1080*1920", "832*480", "480*832"],
              imageRatios: [], resolution: "720p",
              rates: [.second(0.05, "480p"), .second(0.10, "720p"), .second(0.15, "1080p")]),
        .init(provider: "replicate", id: "minimax/video-01-live", name: "MiniMax Video-01 Live (image required)",
              text: nil, image: "minimax/video-01-live",
              durations: .fixed(6), durationFormat: .none,
              imageKey: "first_frame_image", aspect: .none,
              rates: [.video(0.50)]),
        .init(provider: "replicate", id: "tencent/hunyuan-video", name: "HunyuanVideo (Replicate)",
              text: "tencent/hunyuan-video", image: nil,
              durations: .fixed(5), durationFormat: .none, aspect: .none,
              // Billed by GPU time; Replicate quotes ~$2.55 per run.
              rates: [.video(2.60)]),
    ]

    // Luma — https://api.lumalabs.ai/dream-machine/v1. Images by public URL
    // only. Prices are NOT re-verified: Luma's pricing page now lists only
    // Ray 3.2. These are the older pixel-based rates rounded up.
    public static let luma: [VideoModelSpec] = [
        .init(provider: "luma", id: "ray-2", name: "Ray 2",
              text: "ray-2", image: "ray-2",
              durations: .choices([5, 9]), durationFormat: .secondsSuffix,
              ratios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9", "9:21"], resolution: "720p",
              rates: [.second(0.15, "720p"), .second(0.33, "1080p")]),
        .init(provider: "luma", id: "ray-flash-2", name: "Ray 2 Flash",
              text: "ray-flash-2", image: "ray-flash-2",
              durations: .choices([5, 9]), durationFormat: .secondsSuffix,
              ratios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9", "9:21"], resolution: "720p",
              rates: [.second(0.05, "720p"), .second(0.11, "1080p")]),
    ]

    /// Ids that used to be in our catalogs but no longer exist at the
    /// provider (or never did). Refused with the replacement named, rather
    /// than silently swapped for a different, differently priced model.
    public static let retired: [String: (replacement: String?, note: String)] = [
        "fal-ai/bytedance/seedance/v2/text-to-video":  ("bytedance/seedance-2.0/text-to-video", "fal moved Seedance 2.0 to a new endpoint."),
        "fal-ai/bytedance/seedance/v2/image-to-video": ("bytedance/seedance-2.0/text-to-video", "Seedance 2.0 is one model now; attach an image to use its image-to-video endpoint."),
        "fal-ai/minimax/hailuo-02":                    ("fal-ai/minimax/hailuo-2.3/pro/text-to-video", "fal no longer serves this endpoint."),
        "fal-ai/wan/v2.1/1080p":                       ("fal-ai/wan-25-preview/text-to-video", "fal no longer serves this endpoint."),
        "wavespeed-ai/wan-2.1":                        ("wan-video/wan-2.5-t2v", "This Replicate model no longer exists."),
        "kwaai/kling-v1.6-pro":                        ("kwaivgi/kling-v2.6", "This Replicate model never existed under this owner."),
        "ray-3":                                       ("ray-2", "ray-3 was never part of Luma's Dream Machine API."),
        "T2V-01-Director":                             ("MiniMax-H3", "MiniMax retired its 01-series text-to-video models."),
        "S2V-01":                                      ("MiniMax-H3", "MiniMax retired its 01-series subject-reference model."),
    ]

    public static func spec(provider: String, model: String) -> VideoModelSpec? {
        all.first { $0.providerId == provider && $0.modelId == model }
    }

    public static func models(for provider: String) -> [VideoModelSpec] {
        all.filter { $0.providerId == provider }
    }

    /// A refusal for a model id we know is gone, or nil.
    public static func retiredRefusal(model: String) -> String? {
        guard let r = retired[model] else { return nil }
        let replacement = r.replacement.map { " Use \($0) instead." } ?? ""
        return "\(model) is no longer available: \(r.note)\(replacement)"
    }
}

// MARK: - Bridges to the existing catalog types

extension CLIProviderModel {
    /// A catalog row for the CLI, derived from the shared spec.
    public init(spec: VideoModelSpec, providerName: String) {
        self.init(providerId: spec.providerId, providerName: providerName,
                  modelId: spec.modelId, displayName: spec.displayName,
                  defaultWidth: spec.defaultWidth, defaultHeight: spec.defaultHeight,
                  maxDurationSeconds: Double(spec.maxSeconds),
                  costPerSecondUSD: spec.defaultCostPerSecond,
                  supportsImageToVideo: spec.supportsImageToVideo,
                  supportsTextToVideo: spec.supportsTextToVideo,
                  allowedDurations: spec.allowedSeconds)
    }

    public static func catalog(provider: String, providerName: String) -> [CLIProviderModel] {
        VideoModelCatalog.models(for: provider).map { CLIProviderModel(spec: $0, providerName: providerName) }
    }
}
