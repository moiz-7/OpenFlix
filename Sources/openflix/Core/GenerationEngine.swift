import Foundation
import OpenFlixKit

/// Core engine: submit a generation to a provider, poll until done, download the result.
final class GenerationEngine {

    struct Options {
        var pollInterval: TimeInterval = 3
        var timeout: TimeInterval = 300
        var outputURL: URL?
        var stream: Bool = false
        var skipDownload: Bool = false
        var maxRetries: Int = 0
    }

    // MARK: - Submit only (no wait)

    static func submit(
        prompt: String,
        negativePrompt: String? = nil,
        provider providerID: String,
        model: String,
        durationSeconds: Double? = nil,
        aspectRatio: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        referenceImageURL: URL? = nil,
        extraParams: [String: Any] = [:],
        apiKey: String? = nil
    ) async throws -> CLIGeneration {
        // Context reused by every log line on this path. The prompt is present
        // only as a digest — see CLIRedact.
        var logContext: [String: Any] = [
            "provider": providerID,
            "model": model,
            "duration_seconds": durationSeconds.map { $0.isFinite ? $0 : Double.nan } as Any,
            "has_reference_image": referenceImageURL != nil,
        ]
        logContext.merge(CLIRedact.promptFields(prompt)) { a, _ in a }

        let provider = try ProviderRegistry.shared.provider(for: providerID)
        let key = try CLIKeychain.resolveKey(provider: providerID, flagValue: apiKey)

        // Reference-image pre-flight: reject a local file reference before we
        // run hooks or bill a generation the provider can't use (see helper).
        do { try validateReferenceImage(referenceImageURL, providerID: providerID) }
        catch { throw logRefusal("reference_image", logContext, error) }

        // Duration pre-flight. `generate` validates at the flag boundary; the
        // batch / recipe / project / workflow / scatter / MCP paths do not, so
        // the invariant lives here — the one place every spending path passes
        // through. Without it an impossible duration was silently normalised by
        // the provider clamp instead of refused, and the user was billed for
        // something they did not ask for.
        let allModels = ProviderRegistry.shared.allModels
        let modelInfo = allModels.first { $0.providerId == providerID && $0.modelId == model }
        do { try validateDuration(durationSeconds, providerID: providerID, model: model, modelInfo: modelInfo) }
        catch { throw logRefusal("duration", logContext, error) }

        // Prompt safety pre-flight
        let safety = PromptSafetyChecker.check(prompt)
        if safety.level == .blocked {
            throw logRefusal("prompt_safety", logContext,
                             OpenFlixError.promptBlocked(safety.flags))
        }

        // Pre-generate hook (single choke point for ALL generation paths:
        // generate, batch, project shots, scatter-gather, workflow nodes).
        // Hook file: ~/.openflix/hooks/pre-generate — see HookRunner.swift.
        var hookSpec: [String: Any] = [
            "prompt": prompt,
            "provider": providerID,
            "model": model,
        ]
        if let v = negativePrompt   { hookSpec["negative_prompt"] = v }
        if let v = durationSeconds  { hookSpec["duration_seconds"] = v }
        if let v = aspectRatio      { hookSpec["aspect_ratio"] = v }
        if let v = width            { hookSpec["width"] = v }
        if let v = height           { hookSpec["height"] = v }
        if let v = referenceImageURL { hookSpec["reference_image_url"] = v.absoluteString }
        do { try HookRunner.runPreGenerate(spec: hookSpec) }
        catch { throw logRefusal("hook_veto", logContext, error) }

        let request = GenerationRequest(
            prompt: prompt,
            negativePrompt: negativePrompt,
            referenceImageURL: referenceImageURL,
            model: model,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            aspectRatio: aspectRatio,
            extraParams: extraParams
        )

        // Budget pre-flight check (estimate from provider model costs).
        let estCost = preflightEstimate(durationSeconds: durationSeconds,
                                        costPerSecondUSD: modelInfo?.costPerSecondUSD)
        logContext["preflight_estimate_usd"] = estCost
        if estCost > 0 {
            let budgetCheck = await BudgetManager.shared.preFlightCheck(estimatedCost: estCost)
            if case .denied(let reason) = budgetCheck {
                throw logRefusal("budget", logContext, OpenFlixError.budgetExceeded(reason))
            }
        }

        let submission: GenerationSubmission
        do { submission = try await provider.submit(request: request, apiKey: key) }
        catch let e as ProviderError {
            let mapped = OpenFlixError(e)
            throw logProviderFailure("generation.submit_failed", logContext, mapped)
        } catch {
            throw logProviderFailure("generation.submit_failed", logContext, error)
        }

        let gen = CLIGeneration(
            id: UUID().uuidString,
            status: .submitted,
            provider: providerID,
            model: model,
            prompt: prompt,
            negativePrompt: negativePrompt,
            aspectRatio: aspectRatio,
            widthPx: width,
            heightPx: height,
            durationSeconds: durationSeconds,
            referenceImageURL: referenceImageURL?.absoluteString,
            extraParams: extraParams.isEmpty ? nil : extraParams.mapValues { AnyCodableValue.from($0) },
            remoteTaskId: submission.remoteTaskId,
            statusURL: submission.statusURL?.absoluteString,
            remoteVideoURL: nil,
            localPath: nil,
            estimatedCostUSD: submission.estimatedCostUSD,
            actualCostUSD: nil,
            errorMessage: nil,
            retryCount: 0,
            createdAt: Date(),
            submittedAt: Date(),
            completedAt: nil
        )
        GenerationStore.shared.save(gen)

        // The one line that answers "what did this process actually buy?".
        var submitted = logContext
        submitted["generation_id"] = gen.id
        submitted["remote_task_id"] = submission.remoteTaskId as Any
        submitted["estimated_cost_usd"] = submission.estimatedCostUSD as Any
        CLILog.info("generation.submitted", submitted)

        return gen
    }

    // MARK: - Submit + wait (blocking poll loop)

    static func submitAndWait(
        prompt: String,
        negativePrompt: String? = nil,
        provider providerID: String,
        model: String,
        durationSeconds: Double? = nil,
        aspectRatio: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        referenceImageURL: URL? = nil,
        extraParams: [String: Any] = [:],
        apiKey: String? = nil,
        options: Options
    ) async throws -> CLIGeneration {
        var attempt = 0
        var lastGenId: String?
        while true {
            do {
                // Clean up failed generation from previous attempt before retrying
                if let prevId = lastGenId {
                    GenerationStore.shared.delete(prevId)
                }
                var gen = try await submit(
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    provider: providerID,
                    model: model,
                    durationSeconds: durationSeconds,
                    aspectRatio: aspectRatio,
                    width: width,
                    height: height,
                    referenceImageURL: referenceImageURL,
                    extraParams: extraParams,
                    apiKey: apiKey
                )
                lastGenId = gen.id
                if attempt > 0 {
                    GenerationStore.shared.update(id: gen.id) { $0.retryCount = attempt }
                }
                if options.stream {
                    Output.emitEvent([
                        "event": "submitted",
                        "id": gen.id,
                        "attempt": attempt + 1,
                        "provider": gen.provider,
                        "model": gen.model,
                        "estimated_cost_usd": gen.estimatedCostUSD as Any,
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                    ])
                }
                return try await waitForCompletion(gen: &gen, apiKey: apiKey, options: options)
            } catch let error as OpenFlixError where error.code == "generation_failed" || error.code == "rate_limited" {
                attempt += 1
                guard attempt <= options.maxRetries else { throw error }
                CLILog.warn("generation.retry", [
                    "provider": providerID, "model": model,
                    "attempt": attempt, "max_retries": options.maxRetries,
                    "code": error.code,
                    "error": error.errorDescription ?? "",
                ])
                if options.stream {
                    Output.emitEvent(["event": "retry", "attempt": attempt,
                        "max_retries": options.maxRetries,
                        "error": error.errorDescription ?? "",
                        "timestamp": ISO8601DateFormatter().string(from: Date())])
                }
                let backoff: Double
                if error.code == "rate_limited", case .rateLimited(_, let retryAfter) = error, let s = retryAfter {
                    backoff = Double(s)
                } else {
                    backoff = min(pow(2.0, Double(attempt)), 30.0)
                }
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            // Other errors propagate immediately
        }
    }

    // MARK: - Wait for existing generation

    static func waitForCompletion(gen: inout CLIGeneration, apiKey: String?, options: Options) async throws -> CLIGeneration {
        guard let taskId = gen.remoteTaskId else {
            throw OpenFlixError.invalidResponse("Generation has no remote task ID")
        }
        let provider = try ProviderRegistry.shared.provider(for: gen.provider)
        let key = try CLIKeychain.resolveKey(provider: gen.provider, flagValue: apiKey)
        let statusURL = gen.statusURL.flatMap { URL(string: $0) }

        let deadline = Date().addingTimeInterval(options.timeout)
        var lastKnownStatus = gen.status.rawValue

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(options.pollInterval * 1_000_000_000))

            // Poll with transient error retry
            let pollResult: PollStatus
            do {
                do { pollResult = try await provider.poll(taskId: taskId, statusURL: statusURL, apiKey: key) }
                catch let e as ProviderError { throw OpenFlixError(e) }
            } catch {
                let isTransient = (error as? URLError) != nil
                    || (error as? OpenFlixError).map { e in e.code == "rate_limited" || e.code == "http_error" } ?? false
                if isTransient {
                    var retried: PollStatus?
                    for attempt in 1...3 {
                        try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 2.0 * 1_000_000_000))
                        retried = try? await provider.poll(taskId: taskId, statusURL: statusURL, apiKey: key)
                        if retried != nil { break }
                    }
                    guard let r = retried else {
                        throw logProviderFailure("generation.poll_failed", [
                            "generation_id": gen.id, "provider": gen.provider, "model": gen.model,
                        ], error)
                    }
                    pollResult = r
                } else {
                    throw logProviderFailure("generation.poll_failed", [
                        "generation_id": gen.id, "provider": gen.provider, "model": gen.model,
                    ], error)
                }
            }

            switch pollResult {
            case .queued:
                lastKnownStatus = "queued"
                if options.stream {
                    Output.emitEvent(["event": "queued", "id": gen.id, "timestamp": now()])
                }

            case .processing(let progress):
                lastKnownStatus = "processing"
                GenerationStore.shared.update(id: gen.id) { $0.status = .processing }
                gen.status = .processing
                if options.stream {
                    var evt: [String: Any] = ["event": "processing", "id": gen.id, "timestamp": now()]
                    if let p = progress { evt["progress"] = p }
                    Output.emitEvent(evt)
                }

            case .succeeded(let videoURL):
                // Persist remote completion BEFORE attempting download
                gen.status = .succeeded
                gen.remoteVideoURL = videoURL.absoluteString
                gen.completedAt = Date()
                gen.actualCostUSD = gen.estimatedCostUSD
                // Record spend for budget tracking
                if let cost = gen.actualCostUSD ?? gen.estimatedCostUSD {
                    await BudgetManager.shared.recordSpend(amount: cost)
                }
                CLILog.info("generation.succeeded", [
                    "generation_id": gen.id, "provider": gen.provider, "model": gen.model,
                    "actual_cost_usd": gen.actualCostUSD as Any,
                    "remote_video_url": CLIRedact.url(videoURL) as Any,
                    "elapsed_seconds": Int(Date().timeIntervalSince(gen.createdAt)),
                ])
                GenerationStore.shared.update(id: gen.id) { g in
                    g.status = .succeeded
                    g.remoteVideoURL = videoURL.absoluteString
                    g.completedAt = gen.completedAt
                    g.actualCostUSD = gen.actualCostUSD
                }
                // Download (unless skipDownload)
                if !options.skipDownload {
                    do {
                        let localURL = try await VideoDownloader.download(
                            from: videoURL, to: options.outputURL, generationId: gen.id)
                        gen.localPath = localURL.path
                        GenerationStore.shared.update(id: gen.id) { $0.localPath = localURL.path }
                        if options.stream {
                            Output.emitEvent(["event": "succeeded", "id": gen.id,
                                "local_path": localURL.path,
                                "actual_cost_usd": gen.actualCostUSD as Any, "timestamp": now()])
                        }
                    } catch {
                        let msg = (error as? OpenFlixError)?.errorDescription ?? error.localizedDescription
                        let hint = "Use: openflix download \(gen.id)"
                        gen.errorMessage = "Download failed: \(msg). \(hint)"
                        GenerationStore.shared.update(id: gen.id) { $0.errorMessage = gen.errorMessage }
                        CLILog.warn("generation.download_failed", [
                            "generation_id": gen.id, "provider": gen.provider,
                            "remote_video_url": CLIRedact.url(videoURL) as Any,
                            "error": msg,
                        ])
                        if options.stream {
                            Output.emitEvent(["event": "download_failed", "id": gen.id,
                                "remote_video_url": videoURL.absoluteString, "error": msg, "timestamp": now()])
                        }
                        // Do NOT re-throw; generation succeeded, download is retriable
                    }
                } else {
                    if options.stream {
                        Output.emitEvent(["event": "succeeded", "id": gen.id,
                            "remote_video_url": videoURL.absoluteString, "skipped_download": true,
                            "actual_cost_usd": gen.actualCostUSD as Any, "timestamp": now()])
                    }
                }
                // Post-generate hook (best-effort; never fails the run).
                HookRunner.runPostGenerate(result: gen.jsonRepresentation)
                return gen

            case .failed(let message):
                gen.status = .failed
                gen.errorMessage = message
                gen.completedAt = Date()
                GenerationStore.shared.update(id: gen.id) { g in
                    g.status = .failed
                    g.errorMessage = message
                    g.completedAt = gen.completedAt
                }
                if options.stream {
                    Output.emitEvent(["event": "failed", "id": gen.id, "error": message, "timestamp": now()])
                }
                CLILog.warn("generation.failed", [
                    "generation_id": gen.id, "provider": gen.provider, "model": gen.model,
                    "error": message,
                    "elapsed_seconds": Int(Date().timeIntervalSince(gen.createdAt)),
                ])
                // Post-generate hook fires on terminal outcomes too.
                HookRunner.runPostGenerate(result: gen.jsonRepresentation)
                throw OpenFlixError.generationFailed(message)
            }
        }

        // `Int(Double)` traps on NaN/±inf/overflow and aborts the process.
        // `--timeout` is not validated at the flag boundary the way `--duration`
        // is, so a non-finite value reaches here — and it reaches here on the
        // *timeout path*, which runs after the generation has already been
        // submitted and billed. Aborting there loses the record of a
        // generation the user has paid for. Formatting must never be the thing
        // that crashes an error path.
        let msg = "Timed out after \(GenerationEngine.formatSeconds(options.timeout))s (last status: \(lastKnownStatus))"
        GenerationStore.shared.update(id: gen.id) { $0.status = .failed; $0.errorMessage = msg }
        CLILog.error("generation.timeout", [
            "generation_id": gen.id, "provider": gen.provider, "model": gen.model,
            "timeout_seconds": options.timeout, "last_status": lastKnownStatus,
        ])
        throw OpenFlixError.timeout(gen.id)
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: - Pre-flight helpers (pure, unit-tested)

    /// Nominal duration used to estimate cost when the caller gives none.
    /// Providers bill their own default duration in that case, so the gate
    /// must estimate *something* rather than $0.
    static let defaultBillableDurationSeconds: Double = 4

    /// Up-front cost estimate for the budget pre-flight gate.
    ///
    /// The gate runs BEFORE submission, so it can't use the provider's
    /// post-submit estimate. Two sharp edges this closes:
    ///   • No `--duration` → the provider still bills its default duration, so
    ///     estimating $0 (the old behaviour) let a strict daily/monthly/
    ///     per-generation budget be bypassed by simply omitting duration. We
    ///     fall back to a nominal default so the gate always runs.
    ///   • A non-finite duration makes `cps * dur` NaN, and `NaN > limit` is
    ///     always false — silently defeating the gate. We sanitise first.
    static func preflightEstimate(durationSeconds: Double?, costPerSecondUSD: Double?) -> Double {
        guard let cps = costPerSecondUSD, cps > 0 else { return 0 }
        let raw = durationSeconds ?? defaultBillableDurationSeconds
        let dur = (raw.isFinite && raw > 0) ? raw : defaultBillableDurationSeconds
        return cps * dur
    }

    /// Reference images are sent to the provider *by URL* — the provider
    /// fetches them itself. A local file path (turned into a `file://` URL by
    /// the `generate` command, or a bare scheme-less path by the workflow/
    /// batch/project paths that use `URL(string:)`) is not reachable by a
    /// remote provider, so the generation would be billed and then fail to use
    /// the image, or fail outright with an opaque provider error. Reject it up
    /// front with an actionable message. The "local" provider (ComfyUI) runs on
    /// the same machine, so it is exempt.
    static func validateReferenceImage(_ url: URL?, providerID: String) throws {
        guard let url, providerID != "local" else { return }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw OpenFlixError.invalidResponse(
                "Reference image must be a public http(s) URL — local files aren't uploaded to \(providerID) (got: \(url.absoluteString)). Upload the image and pass its URL.")
        }
    }

    // MARK: - Reference-image parsing (C1-2)

    /// Turn a reference-image *string* — from a batch item, a project shot, a
    /// workflow node or a stored generation being retried — into a URL, without
    /// ever silently dropping it.
    ///
    /// The bug this replaces: every one of those call sites used
    /// `raw.flatMap { URL(string: $0) }`. `URL(string:)` returns nil for some
    /// perfectly ordinary strings — a path or URL containing a space on macOS
    /// 14 (the package's minimum), a space in the host on every version, an
    /// empty string — and `flatMap` turns that nil into "there was no reference
    /// image". The generation was then submitted as text-to-video, billed, and
    /// the user was never told. The honest refusal in
    /// `validateReferenceImage` could not fire because the value was gone
    /// before the engine saw it.
    ///
    /// Contract: returns nil **only** for nil/blank input. A local or otherwise
    /// unusable path is returned as a `file://` URL so the choke point refuses
    /// it out loud (and so provider `local`/ComfyUI, which is exempt, still
    /// receives it). A string that cannot be a URL at all throws rather than
    /// vanishing.
    static func parseReferenceImage(_ raw: String?) throws -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A parse that yields an explicit scheme is authoritative: http(s)
        // passes validation, file/ftp/anything else is refused honestly with
        // the string the user actually wrote.
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        // No scheme. Either a remote URL this Foundation version refuses to
        // parse, or a filesystem path.
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let normalized = normalizeRemoteURL(trimmed) else {
                throw OpenFlixError.invalidInput(
                    "Invalid reference image URL: \(trimmed)")
            }
            return normalized
        }

        // Filesystem path (absolute, relative, or ~-prefixed). Made into a
        // real file:// URL so the choke point's message is accurate.
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    /// Percent-encode the path/query of an http(s) URL that `URL(string:)`
    /// rejected, leaving any existing escapes alone. A space in the *host* is
    /// not fixable — a host cannot contain one — so that returns nil and the
    /// caller refuses instead of inventing a different URL.
    static func normalizeRemoteURL(_ raw: String) -> URL? {
        guard let schemeEnd = raw.range(of: "://") else { return nil }
        let scheme = String(raw[raw.startIndex..<schemeEnd.lowerBound])
        let rest = String(raw[schemeEnd.upperBound...])
        guard !rest.isEmpty else { return nil }

        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = String(rest[rest.startIndex..<authorityEnd])
        let remainder = String(rest[authorityEnd...])
        guard !authority.isEmpty,
              authority.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        // `%` stays in the allowed set so an already-escaped path is not
        // double-encoded into a different URL.
        let allowed = CharacterSet(charactersIn: "!#$%&'()*+,-./:;=?@_~[]").union(.alphanumerics)
        guard let encoded = remainder.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(scheme)://\(authority)\(encoded)"),
              let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        return url
    }

    // MARK: - Duration invariant (C1-1)

    /// Hard ceiling on any requested duration, matching the `--duration` flag
    /// check in `generate`. No provider offers anything close; a value above it
    /// is a bug or a typo, never an order.
    static let maxRequestDurationSeconds: Double = 600

    /// Refuse an impossible duration instead of quietly normalising it.
    ///
    /// `generate` performs these checks at the flag boundary. Every other
    /// spending path — `batch`, `recipe run`, `project run`, `workflow run`,
    /// scatter/fanout, the MCP tools — reached the provider with whatever it
    /// was handed, where `GenerationRequest.durationInt()` clamped it to keep
    /// the process from trapping. Clamping is the right *crash* fix and the
    /// wrong *product* answer: the user asked for 9 999 s, was billed for 5,
    /// and was never told. Called from `submit`, so it covers all of them.
    ///
    /// Note `Int(someDouble)` is never used here — it aborts the process on
    /// NaN/±inf, which is exactly the input this is meant to catch.
    static func validateDuration(_ duration: Double?,
                                 providerID: String,
                                 model: String,
                                 modelInfo: CLIProviderModel?) throws {
        guard let d = duration else { return }
        guard d.isFinite else {
            throw OpenFlixError.invalidInput(
                "duration must be a finite number of seconds (got \(d)) for \(providerID)/\(model).")
        }
        guard d > 0 else {
            throw OpenFlixError.invalidInput(
                "duration must be positive (got \(formatSeconds(d))s) for \(providerID)/\(model).")
        }
        guard d <= maxRequestDurationSeconds else {
            throw OpenFlixError.invalidInput(
                "duration \(formatSeconds(d))s exceeds maximum allowed (\(formatSeconds(maxRequestDurationSeconds))s) for \(providerID)/\(model).")
        }
        if let max = modelInfo?.maxDurationSeconds, max > 0, d > max {
            throw OpenFlixError.invalidInput(
                "duration \(formatSeconds(d))s exceeds model max \(formatSeconds(max))s for \(providerID)/\(model).")
        }
    }

    /// Trim the trailing ".0" so messages read "600s", not "600.0s".
    ///
    /// The `Int()` conversion is guarded on purpose: this function is called
    /// *from the error path*, with exactly the hostile values that make a bare
    /// `Int(Double)` abort the process. A crash while explaining a refusal
    /// would be a spectacular own goal.
    static func formatSeconds(_ v: Double) -> String {
        guard v.isFinite else { return String(describing: v) }
        guard v.magnitude < 1e15, v == v.rounded() else { return String(v) }
        return String(Int(v.rounded()))
    }

    // MARK: - Logging helpers

    /// Record a pre-flight refusal, then hand the error back to be thrown.
    /// Refusals are the 3 a.m. questions: *why did nothing happen?*
    @discardableResult
    private static func logRefusal(_ reason: String, _ context: [String: Any], _ error: Error) -> Error {
        var fields = context
        fields["reason"] = reason
        if let e = error as? OpenFlixError {
            fields["code"] = e.code
            fields["error"] = e.errorDescription ?? e.code
        } else {
            fields["error"] = error.localizedDescription
        }
        CLILog.warn("generation.refused", fields)
        return error
    }

    /// Record a provider-side failure with its HTTP status where we have one.
    @discardableResult
    private static func logProviderFailure(_ event: String, _ context: [String: Any], _ error: Error) -> Error {
        var fields = context
        if let e = error as? OpenFlixError {
            fields["code"] = e.code
            fields["error"] = e.errorDescription ?? e.code
            if case .httpError(let status, _) = e { fields["http_status"] = status }
            if case .rateLimited(_, let retryAfter) = e, let s = retryAfter { fields["retry_after_seconds"] = s }
        } else if let urlError = error as? URLError {
            fields["code"] = "url_error"
            fields["url_error_code"] = urlError.errorCode
            fields["error"] = urlError.localizedDescription
        } else {
            fields["error"] = error.localizedDescription
        }
        CLILog.error(event, fields)
        return error
    }
}
