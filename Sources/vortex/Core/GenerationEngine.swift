import Foundation

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
        let provider = try ProviderRegistry.shared.provider(for: providerID)
        let key = try CLIKeychain.resolveKey(provider: providerID, flagValue: apiKey)

        // Prompt safety pre-flight
        let safety = PromptSafetyChecker.check(prompt)
        if safety.level == .blocked {
            throw VortexError.promptBlocked(safety.flags)
        }

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

        // Budget pre-flight check (estimate from provider model costs)
        let allModels = ProviderRegistry.shared.allModels
        let estCost: Double
        if let modelInfo = allModels.first(where: { $0.providerId == providerID && $0.modelId == model }),
           let cps = modelInfo.costPerSecondUSD, let dur = durationSeconds {
            estCost = cps * dur
        } else {
            estCost = 0
        }
        if estCost > 0 {
            let budgetCheck = await BudgetManager.shared.preFlightCheck(estimatedCost: estCost)
            if case .denied(let reason) = budgetCheck {
                throw VortexError.budgetExceeded(reason)
            }
        }

        let submission = try await provider.submit(request: request, apiKey: key)

        var gen = CLIGeneration(
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
            } catch let error as VortexError where error.code == "generation_failed" || error.code == "rate_limited" {
                attempt += 1
                guard attempt <= options.maxRetries else { throw error }
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
            throw VortexError.invalidResponse("Generation has no remote task ID")
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
                pollResult = try await provider.poll(taskId: taskId, statusURL: statusURL, apiKey: key)
            } catch {
                let isTransient = (error as? URLError) != nil
                    || (error as? VortexError).map { e in e.code == "rate_limited" || e.code == "http_error" } ?? false
                if isTransient {
                    var retried: PollStatus?
                    for attempt in 1...3 {
                        try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 2.0 * 1_000_000_000))
                        retried = try? await provider.poll(taskId: taskId, statusURL: statusURL, apiKey: key)
                        if retried != nil { break }
                    }
                    guard let r = retried else { throw error }
                    pollResult = r
                } else { throw error }
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
                        let msg = (error as? VortexError)?.errorDescription ?? error.localizedDescription
                        let hint = "Use: vortex download \(gen.id)"
                        gen.errorMessage = "Download failed: \(msg). \(hint)"
                        GenerationStore.shared.update(id: gen.id) { $0.errorMessage = gen.errorMessage }
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
                throw VortexError.generationFailed(message)
            }
        }

        let msg = "Timed out after \(Int(options.timeout))s (last status: \(lastKnownStatus))"
        GenerationStore.shared.update(id: gen.id) { $0.status = .failed; $0.errorMessage = msg }
        throw VortexError.timeout(gen.id)
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
