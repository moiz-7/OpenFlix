import ArgumentParser
import Foundation

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a video using an AI provider",
        discussion: """
        Submits a video generation request. Use --wait to block until complete.

        EXAMPLES
          # Quick generate and wait:
          vortex generate "a cat on the moon" --provider fal --model fal-ai/minimax/hailuo-02 --wait

          # Stream progress events (newline-delimited JSON):
          vortex generate "..." --provider fal --model fal-ai/veo3 --stream

          # Use environment variable for API key:
          VORTEX_FAL_KEY=your-key vortex generate "..." --provider fal --model fal-ai/veo3 --wait

          # Specify output file:
          vortex generate "..." --provider replicate --model minimax/video-01-live \\
              --wait --output ~/videos/result.mp4
        """
    )

    // MARK: - Required

    @Argument(help: "Text prompt describing the video to generate")
    var prompt: String

    @Option(name: .long, help: "Provider ID (replicate, fal, runway, luma, kling, minimax)")
    var provider: String

    @Option(name: .long, help: "Model ID (use 'vortex models --provider <id>' to list)")
    var model: String

    // MARK: - Generation params

    @Option(name: .long, help: "Duration in seconds")
    var duration: Double?

    @Option(name: .long, help: "Aspect ratio (e.g. 16:9, 9:16, 1:1)")
    var aspectRatio: String?

    @Option(name: .long, help: "Output width in pixels")
    var width: Int?

    @Option(name: .long, help: "Output height in pixels")
    var height: Int?

    @Option(name: .long, help: "Negative prompt (what to avoid)")
    var negativePrompt: String?

    @Option(name: .long, help: "Reference image URL or local path (for image-to-video models)")
    var image: String?

    // MARK: - Extra params (Seedance, etc.)

    @Option(name: .long, help: "Extra JSON parameters as key=value pairs (e.g. audio=true seed=42)")
    var param: [String] = []

    // MARK: - Wait / stream

    @Flag(name: .long, help: "Block until generation completes, then output final JSON")
    var wait: Bool = false

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events to stdout")
    var stream: Bool = false

    @Option(name: .long, help: "Max seconds to wait (default: 300)")
    var timeout: Double = 300

    @Option(name: .long, help: "Poll interval in seconds (default: 3)")
    var pollInterval: Double = 3

    // MARK: - Output

    @Option(name: [.short, .long], help: "Output file path for the downloaded video")
    var output: String?

    // MARK: - Auth

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    // MARK: - Global

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long, help: "Skip downloading the video after generation completes")
    var skipDownload: Bool = false

    @Option(name: .long, help: "Max retries on provider failure (default: 0)")
    var retry: Int = 0

    @Flag(name: .long, help: "Validate request without submitting")
    var dryRun: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // Validate provider/model
        let registry = ProviderRegistry.shared
        guard let prov = try? registry.provider(for: provider) else {
            Output.fail(.providerNotFound(provider))
        }
        let modelInfo = prov.models.first { $0.modelId == model }
        if modelInfo == nil {
            Output.failMessage("Model '\(model)' not found for provider '\(provider)'. Run: vortex models --provider \(provider)", code: "model_not_found")
        }

        // Input validation
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Output.failMessage("Prompt cannot be empty.", code: "invalid_input")
        }
        if retry < 0 {
            Output.failMessage("--retry must be >= 0 (got \(retry)).", code: "invalid_input")
        }
        if let d = duration {
            guard d > 0 else { Output.failMessage("--duration must be positive.", code: "invalid_input") }
            if d > 600 {
                Output.failMessage("--duration \(d)s exceeds maximum allowed (600s).", code: "invalid_input")
            }
            if let max = modelInfo?.maxDurationSeconds, d > max {
                Output.failMessage("--duration \(d)s exceeds model max \(max)s.", code: "invalid_input")
            }
        }
        if let img = image, !img.hasPrefix("http") {
            guard FileManager.default.fileExists(atPath: (img as NSString).expandingTildeInPath) else {
                Output.failMessage("Image file not found: \(img)", code: "invalid_input")
            }
        }

        // Build reference image URL
        var refURL: URL?
        if let img = image {
            if img.hasPrefix("http") {
                refURL = URL(string: img)
            } else {
                refURL = URL(fileURLWithPath: img)
            }
        }

        // Parse extra params
        var extras: [String: Any] = [:]
        for kv in param {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0], val = parts[1]
            if val == "true" || val == "false" {
                extras[key] = (val == "true")
            } else if let n = Int(val) {
                extras[key] = n
            } else if let n = Double(val) {
                extras[key] = n
            } else {
                extras[key] = val
            }
        }

        // Dry run
        if dryRun {
            do { _ = try CLIKeychain.resolveKey(provider: provider, flagValue: apiKey) }
            catch let e as VortexError { Output.fail(e) }
            catch { Output.failMessage(error.localizedDescription) }
            let est = prov.estimateCost(durationSeconds: duration ?? 4, modelId: model)
            Output.emitDict([
                "dry_run": true,
                "provider": provider,
                "model": model,
                "prompt": prompt,
                "duration_seconds": duration as Any,
                "aspect_ratio": aspectRatio as Any,
                "estimated_cost_usd": est as Any,
                "api_key_resolved": true,
            ])
            return
        }

        let opts = GenerationEngine.Options(
            pollInterval: pollInterval,
            timeout: timeout,
            outputURL: output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            stream: stream,
            skipDownload: skipDownload,
            maxRetries: retry
        )

        do {
            if wait || stream {
                let gen = try await GenerationEngine.submitAndWait(
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    provider: provider,
                    model: model,
                    durationSeconds: duration,
                    aspectRatio: aspectRatio,
                    width: width,
                    height: height,
                    referenceImageURL: refURL,
                    extraParams: extras,
                    apiKey: apiKey,
                    options: opts
                )
                Output.emitDict(gen.jsonRepresentation)
            } else {
                let gen = try await GenerationEngine.submit(
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    provider: provider,
                    model: model,
                    durationSeconds: duration,
                    aspectRatio: aspectRatio,
                    width: width,
                    height: height,
                    referenceImageURL: refURL,
                    extraParams: extras,
                    apiKey: apiKey
                )
                Output.emitDict(gen.jsonRepresentation)
            }
        } catch let error as VortexError {
            Output.fail(error)
        } catch {
            Output.failMessage(error.localizedDescription)
        }
    }
}
