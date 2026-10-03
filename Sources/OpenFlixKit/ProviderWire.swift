import Foundation

// MARK: - Provider wire formats
//
// Pure request builders and response parsers for every provider, shared by the
// CLI's `VideoProvider` clients and the Mac app's `VideoGenerationProvider`s.
// No networking and no credentials live in the builders, so every body that
// can reach a provider is unit-testable — and there is exactly one of each.
//
// Why shared: the two apps each had their own copy of every provider, and the
// copies had drifted from the providers *and from each other*. Runway always
// posted to text_to_video even with an image attached; Kling called paths that
// exist in neither of its API standards; Replicate sent width/height/num_frames
// that none of its current models accept. Each fix previously had to be made
// twice and usually wasn't.
//
// Field spellings come from `VideoModelSpec`, which was copied from each
// provider's machine-readable schema on 2026-09-27.

/// What the caller asked for, in provider-neutral terms.
public struct WireInput {
    public var prompt: String
    public var negativePrompt: String?
    /// http(s) URL, or a `data:` URI produced by `ReferenceImageResolver`.
    public var image: URL?
    public var durationSeconds: Double?
    public var aspectRatio: String?
    public var width: Int?
    public var height: Int?
    /// Caller extras (seed, resolution, audio…). Forwarded where the provider
    /// takes free-form input (fal, Replicate); interpreted where it does not.
    public var extra: [String: Any]

    public init(prompt: String, negativePrompt: String? = nil, image: URL? = nil,
                durationSeconds: Double? = nil, aspectRatio: String? = nil,
                width: Int? = nil, height: Int? = nil, extra: [String: Any] = [:]) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.image = image
        self.durationSeconds = durationSeconds
        self.aspectRatio = aspectRatio
        self.width = width
        self.height = height
        self.extra = extra
    }

    /// The user's audio choice, if they made one. nil: provider default.
    public var audio: Bool? { ModelPricing.pricingHints(from: extra).audio }
    public var resolution: String? { extra["resolution"] as? String }
}

/// Where a submission goes and what it carries. Auth headers are added by the
/// caller (`authHeaders`), so a plan can be built — and tested — keyless.
public struct WirePlan {
    public let url: URL
    public let body: [String: Any]
    /// Non-auth headers the provider requires (e.g. X-Runway-Version).
    public let headers: [String: String]

    public init(url: URL, body: [String: Any], headers: [String: String] = [:]) {
        self.url = url
        self.body = body
        self.headers = headers
    }
}

public enum WireError: Error, LocalizedError, Equatable {
    case needsImage(model: String)
    case noImageToVideo(model: String)
    case unknownModel(provider: String, model: String)
    case retired(String)

    public var errorDescription: String? {
        switch self {
        case .needsImage(let m):
            return "\(m) needs a reference image — it has no text-to-video mode. Attach an image or pick another model."
        case .noImageToVideo(let m):
            return "\(m) doesn't support image-to-video: the reference image would be ignored, so nothing was submitted."
        case .unknownModel(let p, let m):
            return "\(m) isn't a \(p) model this version of OpenFlix knows how to call."
        case .retired(let msg):
            return msg
        }
    }
}

public enum ProviderWire {

    /// The spec for a request, with retired/unknown ids refused by name.
    public static func spec(provider: String, model: String) throws -> VideoModelSpec {
        if let s = VideoModelCatalog.spec(provider: provider, model: model) { return s }
        if let msg = VideoModelCatalog.retiredRefusal(model: model) { throw WireError.retired(msg) }
        // fal and Replicate host thousands of models; an id outside our
        // catalog is a legitimate power-user choice there, not an error.
        if ["fal", "seedance", "replicate"].contains(provider) {
            return VideoModelSpec.generic(provider: provider, model: model)
        }
        throw WireError.unknownModel(provider: provider, model: model)
    }

    /// Chooses the text or image endpoint, refusing the impossible combination.
    public static func endpoint(_ spec: VideoModelSpec, hasImage: Bool) throws -> String {
        if hasImage {
            guard let e = spec.imageEndpoint else { throw WireError.noImageToVideo(model: spec.displayName) }
            return e
        }
        guard let e = spec.textEndpoint else { throw WireError.needsImage(model: spec.displayName) }
        return e
    }

    /// Prompt with the negative prompt folded in, for providers whose current
    /// API has no negative field ("prompts can include both positive and
    /// negative descriptions" — Kling).
    static func foldedPrompt(_ input: WireInput) -> String {
        guard let neg = input.negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !neg.isEmpty else {
            return input.prompt
        }
        return "\(input.prompt)\nAvoid: \(neg)"
    }

    static func url(_ base: URL, _ path: String) -> URL {
        base.appendingPathComponent(path)
    }
}

// MARK: - Kling (new standard API)

public enum KlingWire {
    public static let defaultBase = URL(string: "https://api-singapore.klingai.com")!

    public static func authHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"]
    }

    /// Kling takes Base64 *without* a `data:` prefix. The resolver hands every
    /// inline image over as a data URI, so strip it here.
    public static func imageValue(_ url: URL) -> String {
        let s = url.absoluteString
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            return String(s[s.index(after: comma)...])
        }
        return s
    }

    public static func plan(model: String, input: WireInput, base: URL = defaultBase) throws -> WirePlan {
        let spec = try ProviderWire.spec(provider: "kling", model: model)
        let hasImage = input.image != nil
        let pathModel = try ProviderWire.endpoint(spec, hasImage: hasImage)

        var settings: [String: Any] = [
            "duration": spec.billedSeconds(requested: input.durationSeconds),
        ]
        var resolution = input.resolution ?? spec.defaultResolution ?? "720p"
        if spec.audioDefault != nil, let audio = input.audio {
            settings["audio"] = audio ? "native" : "off"
            // Kling 2.6 makes native audio only at 1080p.
            if audio && pathModel == "kling-2.6" { resolution = "1080p" }
        }
        settings["resolution"] = resolution

        if let image = input.image {
            let contents: [[String: Any]] = [
                ["type": "prompt", "text": ProviderWire.foldedPrompt(input)],
                ["type": "first_frame", "url": imageValue(image)],
            ]
            return WirePlan(url: ProviderWire.url(base, "image-to-video/\(pathModel)"),
                            body: ["contents": contents, "settings": settings])
        }
        if let ar = spec.wireAspect(requested: input.aspectRatio, width: input.width, height: input.height, forImage: false) {
            settings["aspect_ratio"] = ar
        }
        return WirePlan(url: ProviderWire.url(base, "text-to-video/\(pathModel)"),
                        body: ["prompt": ProviderWire.foldedPrompt(input), "settings": settings])
    }

    public static func parseSubmit(_ data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let code = json?["code"] as? Int, code == 0,
              let task = json?["data"] as? [String: Any],
              let id = (task["id"] as? String) ?? (task["id"] as? NSNumber)?.stringValue else {
            let msg = (json?["message"] as? String) ?? "unknown error"
            throw ProviderError.invalidResponse("Kling: \(msg)")
        }
        return id
    }

    public static func pollURL(taskId: String, base: URL = defaultBase) -> URL {
        var c = URLComponents(url: ProviderWire.url(base, "tasks"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "task_ids", value: taskId)]
        return c.url!
    }

    public static func parsePoll(_ data: Data) throws -> PollStatus {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let code = json?["code"] as? Int, code != 0 {
            return .failed(message: "Kling: \((json?["message"] as? String) ?? "error \(code)")")
        }
        let task: [String: Any]? = (json?["data"] as? [[String: Any]])?.first ?? (json?["data"] as? [String: Any])
        switch task?["status"] as? String ?? "" {
        case "submitted": return .queued
        case "processing": return .processing(progress: nil)
        case "succeeded":
            let outputs = task?["outputs"] as? [[String: Any]] ?? []
            let video = outputs.first { ($0["type"] as? String) == "video" } ?? outputs.first
            guard let s = video?["url"] as? String, let url = URL(string: s) else {
                return .failed(message: "Kling finished but returned no video URL")
            }
            return .succeeded(videoURL: url)
        case "failed":
            return .failed(message: (task?["message"] as? String).map { "Kling: \($0)" } ?? "Kling generation failed")
        default:
            return .queued
        }
    }
}

// MARK: - Runway

public enum RunwayWire {
    public static let defaultBase = URL(string: "https://api.dev.runwayml.com/v1")!
    public static let apiVersion = "2024-11-06"

    public static func authHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json",
         "X-Runway-Version": apiVersion]
    }

    public static func plan(model: String, input: WireInput, base: URL = defaultBase) throws -> WirePlan {
        let spec = try ProviderWire.spec(provider: "runway", model: model)
        let hasImage = input.image != nil
        let runwayModel = try ProviderWire.endpoint(spec, hasImage: hasImage)

        var body: [String: Any] = [
            "model": runwayModel,
            "duration": spec.billedSeconds(requested: input.durationSeconds),
        ]
        if !input.prompt.isEmpty { body["promptText"] = input.prompt }
        if let ratio = spec.wireAspect(requested: input.aspectRatio, width: input.width,
                                       height: input.height, forImage: hasImage) {
            body["ratio"] = ratio
        }
        if spec.audioDefault != nil, let audio = input.audio { body["audio"] = audio }
        if spec.audioDefault != nil, let neg = input.negativePrompt, !neg.isEmpty { body["negativePrompt"] = neg }
        if let seed = input.extra["seed"] as? Int { body["seed"] = seed }

        let path: String
        if let image = input.image {
            body["promptImage"] = image.absoluteString
            path = "image_to_video"
        } else {
            path = "text_to_video"
        }
        return WirePlan(url: ProviderWire.url(base, path), body: body,
                        headers: ["X-Runway-Version": apiVersion])
    }

    public static func parseSubmit(_ data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else {
            throw ProviderError.invalidResponse("Missing id in Runway response")
        }
        return id
    }

    public static func pollURL(taskId: String, base: URL = defaultBase) -> URL {
        ProviderWire.url(base, "tasks/\(taskId)")
    }

    public static func parsePoll(_ json: [String: Any]?) -> PollStatus {
        switch json?["status"] as? String ?? "" {
        case "PENDING", "THROTTLED": return .queued
        case "RUNNING":
            let progress = (json?["progress"] as? Double) ?? (json?["progress"] as? NSNumber).map { Double(truncating: $0) }
            return .processing(progress: progress)
        case "SUCCEEDED":
            guard let first = (json?["output"] as? [String])?.first, let url = URL(string: first) else {
                return .failed(message: "No output in Runway response")
            }
            return .succeeded(videoURL: url)
        case "FAILED":
            return .failed(message: json?["failure"] as? String ?? "Runway generation failed")
        default:
            return .queued
        }
    }
}

// MARK: - MiniMax (V2 for H3, V1 for legacy Hailuo)

public enum MiniMaxWire {
    public static let defaultBase = URL(string: "https://api.minimax.io")!

    public static func authHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"]
    }

    public static func usesV2(_ model: String) -> Bool { model.hasPrefix("MiniMax-H3") }

    public static func plan(model: String, input: WireInput, base: URL = defaultBase) throws -> WirePlan {
        let spec = try ProviderWire.spec(provider: "minimax", model: model)
        let hasImage = input.image != nil
        let mmModel = try ProviderWire.endpoint(spec, hasImage: hasImage)
        let seconds = spec.billedSeconds(requested: input.durationSeconds)
        let resolution = input.resolution ?? spec.defaultResolution ?? "768P"

        if usesV2(mmModel) {
            var content: [[String: Any]] = [["type": "text", "text": input.prompt]]
            var body: [String: Any] = ["model": mmModel, "resolution": resolution, "duration": seconds]
            if let image = input.image {
                content.append(["type": "image_url", "image_url": ["url": image.absoluteString], "role": "first_frame"])
                body["ratio"] = "adaptive"    // i2v: the image decides
            } else {
                // Text-to-video REQUIRES a concrete ratio (not "adaptive").
                body["ratio"] = spec.wireAspect(requested: input.aspectRatio, width: input.width,
                                                height: input.height, forImage: false) ?? "16:9"
            }
            body["content"] = content
            return WirePlan(url: ProviderWire.url(base, "v2/video_generation"), body: body)
        }

        var body: [String: Any] = [
            "model": mmModel, "prompt": input.prompt, "duration": seconds, "resolution": resolution,
        ]
        if let image = input.image { body["first_frame_image"] = image.absoluteString }
        return WirePlan(url: ProviderWire.url(base, "v1/video_generation"), body: body)
    }

    /// Task id from either version's create response.
    public static func parseSubmit(_ data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let base = json?["base_resp"] as? [String: Any],
           let code = base["status_code"] as? Int, code != 0 {
            throw ProviderError.invalidResponse("MiniMax: \((base["status_msg"] as? String) ?? "error \(code)")")
        }
        if let err = json?["error"] as? [String: Any] {
            throw ProviderError.invalidResponse("MiniMax: \((err["message"] as? String) ?? "error")")
        }
        guard let id = (json?["task_id"] as? String) ?? (json?["task_id"] as? NSNumber)?.stringValue else {
            throw ProviderError.invalidResponse("MiniMax: no task_id in response")
        }
        return id
    }

    /// V2 tasks carry this as their status URL so a poll knows which API
    /// the task belongs to. V1 tasks keep a nil status URL, as before.
    public static func v2PollURL(taskId: String, base: URL = defaultBase) -> URL {
        ProviderWire.url(base, "v2/query/video_generation/\(taskId)")
    }

    public static func isV2PollURL(_ url: URL?) -> Bool {
        url?.path.contains("/v2/query/video_generation/") == true
    }

    public static func parseV2Poll(_ data: Data) throws -> PollStatus {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error"] as? [String: Any] {
            return .failed(message: "MiniMax: \((err["message"] as? String) ?? "error")")
        }
        let task = json?["task"] as? [String: Any]
        switch task?["status"] as? String ?? "" {
        case "queued": return .queued
        case "running": return .processing(progress: nil)
        case "succeeded":
            guard let s = (task?["content"] as? [String: Any])?["url"] as? String, let url = URL(string: s) else {
                return .failed(message: "MiniMax finished but returned no video URL")
            }
            return .succeeded(videoURL: url)
        case "failed":
            let msg = (task?["error"] as? [String: Any])?["message"] as? String
            return .failed(message: msg.map { "MiniMax: \($0)" } ?? "MiniMax generation failed")
        default:
            return .queued
        }
    }
}

// MARK: - fal (queue API)

public enum FalWire {
    public static let queueBase = URL(string: "https://queue.fal.run")!

    public static func authHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Key \(apiKey)", "Content-Type": "application/json"]
    }

    /// Keys we set from the spec; a caller's extras never overwrite them with
    /// a spelling this endpoint doesn't take.
    static let normalizedKeys: Set<String> = ["audio", "native_audio", "generate_audio", "duration", "aspect_ratio"]

    public static func plan(provider: String = "fal", model: String, input: WireInput,
                            base: URL = queueBase) throws -> WirePlan {
        let spec = try ProviderWire.spec(provider: provider, model: model)
        let hasImage = input.image != nil
        let endpoint = try ProviderWire.endpoint(spec, hasImage: hasImage)

        var body: [String: Any] = [:]
        for (k, v) in input.extra where !normalizedKeys.contains(k) { body[k] = v }
        body["prompt"] = input.prompt
        if let neg = input.negativePrompt, !neg.isEmpty { body["negative_prompt"] = neg }
        if let d = spec.wireDuration(spec.billedSeconds(requested: input.durationSeconds)) {
            body[spec.durationKey] = d
        }
        // Image-to-video endpoints derive the frame from the image ("auto");
        // only text mode gets an explicit aspect.
        if !hasImage, let ar = spec.wireAspect(requested: input.aspectRatio, width: input.width,
                                                height: input.height, forImage: false) {
            body["aspect_ratio"] = ar
        }
        if spec.audioDefault != nil, let audio = input.audio { body["generate_audio"] = audio }
        if let image = input.image { body[spec.imageKey] = image.absoluteString }

        return WirePlan(url: ProviderWire.url(base, endpoint), body: body)
    }

    /// `(request_id, status_url)` from the queue submit response.
    public static func parseSubmit(_ data: Data) throws -> (id: String, statusURL: URL?) {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["request_id"] as? String else {
            throw ProviderError.invalidResponse("Missing request_id in fal.ai response")
        }
        return (id, (json?["status_url"] as? String).flatMap(URL.init(string:)))
    }

    public enum Status { case queued, running, completed(responseURL: URL?), failed(String), unknown(String) }

    public static func parseStatus(_ json: [String: Any]?) -> Status {
        switch json?["status"] as? String ?? "" {
        case "IN_QUEUE": return .queued
        case "IN_PROGRESS": return .running
        case "COMPLETED":
            if let err = json?["error"] as? String, !err.isEmpty { return .failed(err) }
            return .completed(responseURL: (json?["response_url"] as? String).flatMap(URL.init(string:)))
        case "FAILED", "ERROR": return .failed((json?["error"] as? String) ?? "fal generation failed")
        case let s: return .unknown(s)
        }
    }

    /// The video URL from a completed request's result, across fal's shapes.
    public static func videoURL(fromResult result: [String: Any]?) -> URL? {
        let s = (result?["video"] as? [String: Any])?["url"] as? String
            ?? (result?["video_url"] as? String)
            ?? ((result?["videos"] as? [[String: Any]])?.first?["url"] as? String)
        return s.flatMap(URL.init(string:))
    }
}

// MARK: - Replicate

public enum ReplicateWire {

    public static func plan(model: String, input: WireInput) throws -> WirePlan {
        let spec = try ProviderWire.spec(provider: "replicate", model: model)
        let hasImage = input.image != nil
        let slug = try ProviderWire.endpoint(spec, hasImage: hasImage)

        var fields: [String: Any] = [:]
        for (k, v) in input.extra where !FalWire.normalizedKeys.contains(k) { fields[k] = v }
        fields["prompt"] = input.prompt
        if let neg = input.negativePrompt, !neg.isEmpty { fields["negative_prompt"] = neg }
        if let d = spec.wireDuration(spec.billedSeconds(requested: input.durationSeconds)) {
            fields[spec.durationKey] = d
        }
        if let ar = spec.wireAspect(requested: input.aspectRatio, width: input.width,
                                    height: input.height, forImage: hasImage) {
            fields[spec.aspectStyle == .wanSize ? "size" : "aspect_ratio"] = ar
        }
        if spec.audioDefault != nil, let audio = input.audio { fields["generate_audio"] = audio }
        if let image = input.image { fields[spec.imageKey] = image.absoluteString }

        let route = try ReplicateClient.submitRoute(model: slug, input: fields)
        return WirePlan(url: route.url, body: route.body)
    }
}

// MARK: - Luma (Dream Machine)

public enum LumaWire {
    public static let defaultBase = URL(string: "https://api.lumalabs.ai/dream-machine/v1")!

    public static func plan(model: String, input: WireInput, base: URL = defaultBase) throws -> WirePlan {
        let spec = try ProviderWire.spec(provider: "luma", model: model)
        _ = try ProviderWire.endpoint(spec, hasImage: input.image != nil)
        var body: [String: Any] = ["prompt": input.prompt, "model": model]
        if let d = spec.wireDuration(spec.billedSeconds(requested: input.durationSeconds)) { body["duration"] = d }
        if let ar = spec.wireAspect(requested: input.aspectRatio, width: input.width, height: input.height, forImage: false) {
            body["aspect_ratio"] = ar
        }
        if let res = input.resolution ?? spec.defaultResolution { body["resolution"] = res }
        if let image = input.image {
            body["keyframes"] = ["frame0": ["type": "image", "url": image.absoluteString]]
        }
        return WirePlan(url: ProviderWire.url(base, "generations/video"), body: body)
    }
}
