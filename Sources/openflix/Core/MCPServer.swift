import Foundation
import OpenFlixKit

/// MCP server that communicates over stdio (stdin/stdout) using JSON-RPC 2.0.
///
/// **Dual-era (C0-2).** MCP `2026-07-28` deleted the session: no
/// `initialize`/`initialized`, no session id, and instead a `server/discover`
/// RPC plus per-request `_meta` carrying protocol version, client identity and
/// client capabilities. That revision's compatibility matrix says a modern
/// client against a legacy-only server *fails* — and "fails" there includes
/// staying silent. This server therefore answers **both** shapes on the same
/// stdio pipe: `initialize` for every client that exists today, and
/// `server/discover` + `_meta` for the ones arriving next. Era is decided per
/// request (`MCPRequestEnvelope.classify`), which is the only way it can be
/// decided when there is no session to hold the answer.
///
/// **On spending.** Every tool that creates video goes through
/// `GenerationEngine.submit`, and nothing here reaches a provider by any other
/// route. That is deliberate: the budget pre-flight, the prompt-safety check,
/// the reference-image rule and the pre/post-generate hooks all live at that one
/// choke point because `openflix generate` validates at the flag boundary and
/// this path does not. Prompts render text and resources are reads; neither can
/// start a generation.
actor MCPServer {

    /// Advertised server identity.
    static let serverName = "openflix"

    /// How long a client may cache a list result. Tools are stable for as long
    /// as the binary is; generations and recipes change under the agent's feet.
    private static let toolListTTLms = 300_000
    private static let resourceListTTLms = 5_000
    private static let promptListTTLms = 15_000

    /// Whether a legacy handshake was ever seen on this session. Not enforced —
    /// nothing here requires it, which is exactly what lets a modern client skip
    /// it — but a test asserts modern requests are served while this is false.
    private(set) var didHandshake = false

    // MARK: - Main loop

    func run() async {
        // Read JSON-RPC messages line by line from stdin
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8) else {
                writeResponse(MCPResponse.error(id: nil, code: MCPErrorCode.parseError, message: "Invalid UTF-8"))
                continue
            }

            do {
                let request = try JSONDecoder().decode(MCPRequest.self, from: data)
                let response = await handleRequest(request)
                if let response = response {
                    writeResponse(response)
                }
            } catch {
                writeResponse(MCPResponse.error(id: nil, code: MCPErrorCode.parseError, message: "Parse error: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Request dispatch

    func handleRequest(_ request: MCPRequest) async -> MCPResponse? {
        let envelope = MCPRequestEnvelope.classify(request)

        // A modern client naming a revision we do not serve gets the error the
        // spec designed for exactly this, carrying the list to retry with.
        // Silence — the legacy server's answer — leaves it guessing.
        if envelope.isUnsupportedVersion, let requested = envelope.protocolVersion {
            return unsupportedVersion(id: request.id, requested: requested)
        }

        switch request.method {
        // Modern lifecycle
        case MCPMethod.discover:
            return complete(id: request.id, discoverResult())

        // Legacy lifecycle
        case MCPMethod.initialize:
            return complete(id: request.id, initializeResult(request))
        case MCPMethod.initialized, MCPMethod.cancelled:
            return nil // notification, no response
        case MCPMethod.shutdown, MCPMethod.ping:
            return complete(id: request.id, .dictionary([:]))

        // Tool methods
        case MCPMethod.toolsList:
            return complete(id: request.id, toolsListResult())
        case MCPMethod.toolsCall:
            return await handleToolsCall(request)

        // Resource methods
        case MCPMethod.resourcesList:
            return complete(id: request.id, resourcesListResult())
        case MCPMethod.resourcesTemplates:
            return complete(id: request.id, resourceTemplatesResult())
        case MCPMethod.resourcesRead:
            return await handleResourcesRead(request)

        // Prompt methods
        case MCPMethod.promptsList:
            return complete(id: request.id, promptsListResult())
        case MCPMethod.promptsGet:
            return handlePromptsGet(request)
        case MCPMethod.complete:
            return complete(id: request.id, completionResult(request))

        default:
            return MCPResponse.error(id: request.id, code: MCPErrorCode.methodNotFound,
                                     message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Result envelope

    /// Every result carries `resultType: "complete"`.
    ///
    /// The 2026-07-28 schema requires it; earlier revisions never saw it, and the
    /// same schema says an absent `resultType` means `"complete"` — so a legacy
    /// client reading an extra key it does not know is the benign direction of
    /// that rule. One shape for both eras beats two that can disagree.
    private func complete(id: AnyCodableValue?, _ result: AnyCodableValue) -> MCPResponse {
        var object = result.objectValue ?? [:]
        object["resultType"] = .string(MCPResultType.complete)
        return MCPResponse.success(id: id, result: .dictionary(object))
    }

    /// A list result with the caching hints 2026-07-28 added. `private` is the
    /// only honest scope: every byte is one person's own keys, spend and work.
    private static func cacheable(_ object: [String: AnyCodableValue], ttlMs: Int) -> AnyCodableValue {
        var result = object
        result["ttlMs"] = .int(ttlMs)
        result["cacheScope"] = .string("private")
        return .dictionary(result)
    }

    private func unsupportedVersion(id: AnyCodableValue?, requested: String) -> MCPResponse {
        MCPResponse.error(
            id: id,
            code: MCPModernErrorCode.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: .dictionary([
                "supported": .array(MCPProtocolVersion.supported.map { .string($0) }),
                "requested": .string(requested),
            ]))
    }

    // MARK: - Lifecycle

    /// Modern: `server/discover`. Answerable with no handshake, which is the
    /// whole point — it is both the modern probe and the era-detection
    /// mechanism a dual-era client uses to find out what we are.
    private func discoverResult() -> AnyCodableValue {
        Self.cacheable([
            "supportedVersions": .array(MCPProtocolVersion.supported.map { .string($0) }),
            "capabilities": capabilities(),
            "serverInfo": .dictionary([
                "name": .string(Self.serverName),
                "version": .string(OpenFlixVersion.current),
            ]),
            "instructions": .string(Self.instructions),
        ], ttlMs: Self.toolListTTLms)
    }

    /// Legacy: the `initialize` handshake reply, unchanged in shape from the one
    /// this server has always sent. The version echoed back is the one the
    /// client asked for when we serve it, and the floor otherwise.
    private func initializeResult(_ request: MCPRequest) -> AnyCodableValue {
        didHandshake = true
        let requested = request.params?["protocolVersion"]?.stringValue
        return .dictionary([
            "protocolVersion": .string(MCPProtocolVersion.negotiateLegacy(requested: requested)),
            "capabilities": capabilities(),
            "serverInfo": .dictionary([
                "name": .string(Self.serverName),
                "version": .string(OpenFlixVersion.current),
            ]),
            "instructions": .string(Self.instructions),
        ])
    }

    /// What this server offers. `listChanged` is deliberately absent everywhere:
    /// we send no list-changed notifications, and advertising one would be a lie
    /// a client would then wait on.
    private func capabilities() -> AnyCodableValue {
        .dictionary([
            "tools": .dictionary([:]),
            "resources": .dictionary([:]),
            "prompts": .dictionary([:]),
            "completions": .dictionary([:]),
        ])
    }

    static let instructions =
        "OpenFlix CLI: generate video from text through the user's own BYOK provider accounts. "
        + "The generate, generate_submit and retry_generation tools SPEND THE USER'S REAL MONEY and cannot be undone — "
        + "call budget_status first and confirm with the user before using them. "
        + "Everything else here reads local state. Saved .openflix recipes are exposed as prompts; "
        + "rendering one produces prompt text and never submits anything."

    // MARK: - Tools

    private func toolsListResult() -> AnyCodableValue {
        let tools = MCPToolRegistry.allTools.map { $0.toAnyCodable() }
        return Self.cacheable(["tools": .array(tools)], ttlMs: Self.toolListTTLms)
    }

    private func handleToolsCall(_ request: MCPRequest) async -> MCPResponse {
        guard let params = request.params,
              case .string(let toolName) = params["name"] else {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: "Missing 'name' parameter")
        }

        let arguments: [String: AnyCodableValue]
        if case .dictionary(let args) = params["arguments"] {
            arguments = args
        } else {
            arguments = [:]
        }

        do {
            let result = try await dispatchTool(name: toolName, arguments: arguments)
            return complete(id: request.id, .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string(jsonString(result)),
                    ])
                ]),
                // The typed half of the same answer (2025-06-18+). The text block
                // stays for clients that never learned to read this one.
                "structuredContent": AnyCodableValue.sanitized(result),
            ]))
        } catch let error as OpenFlixError {
            let structured = StructuredError.from(error)
            return complete(id: request.id, .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string(jsonString(structured.jsonRepresentation)),
                    ])
                ]),
                "isError": .bool(true),
            ]))
        } catch {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.internalError,
                                     message: error.localizedDescription)
        }
    }

    // MARK: - Resources

    private func resourcesListResult() -> AnyCodableValue {
        let resources = MCPToolRegistry.allResources.map { $0.toAnyCodable() }
        return Self.cacheable(["resources": .array(resources)], ttlMs: Self.resourceListTTLms)
    }

    private func resourceTemplatesResult() -> AnyCodableValue {
        let templates = MCPToolRegistry.allResourceTemplates.map { $0.toAnyCodable() }
        return Self.cacheable(["resourceTemplates": .array(templates)], ttlMs: Self.resourceListTTLms)
    }

    private func handleResourcesRead(_ request: MCPRequest) async -> MCPResponse {
        guard let params = request.params,
              case .string(let uri) = params["uri"] else {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: "Missing 'uri' parameter")
        }

        do {
            let content = try await readResource(uri: uri)
            return complete(id: request.id, .dictionary([
                "contents": .array([
                    .dictionary([
                        "uri": .string(uri),
                        "mimeType": .string("application/json"),
                        "text": .string(content),
                    ])
                ])
            ]))
        } catch {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: "Unknown resource: \(uri)",
                                     data: .dictionary(["uri": .string(uri)]))
        }
    }

    // MARK: - Prompts

    private func promptsListResult() -> AnyCodableValue {
        let prompts = MCPToolRegistry.allPrompts(recipes: RecipeStore.shared.all())
            .map { $0.toAnyCodable() }
        return Self.cacheable(["prompts": .array(prompts)], ttlMs: Self.promptListTTLms)
    }

    private func handlePromptsGet(_ request: MCPRequest) -> MCPResponse {
        guard let name = request.params?["name"]?.stringValue, !name.isEmpty else {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: "Missing 'name' parameter")
        }
        switch MCPPromptRenderer.render(name: name,
                                        arguments: request.params?["arguments"],
                                        recipes: RecipeStore.shared.all()) {
        case .success(let payload):
            return complete(id: request.id, payload)
        case .failure(let failure):
            // The prompts spec names -32602 for an unknown prompt *and* for a
            // missing required argument, so both land here.
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: failure.message)
        }
    }

    private func completionResult(_ request: MCPRequest) -> AnyCodableValue {
        MCPCompletion.complete(
            ref: request.params?["ref"],
            argumentName: request.params?["argument"]?["name"]?.stringValue ?? "",
            value: request.params?["argument"]?["value"]?.stringValue ?? "",
            recipes: RecipeStore.shared.all())
    }

    // MARK: - Tool dispatch

    private func dispatchTool(name: String, arguments: [String: AnyCodableValue]) async throws -> [String: Any] {
        switch name {
        case "generate":
            return try await toolGenerate(arguments)
        case "generate_submit":
            return try await toolGenerateSubmit(arguments)
        case "generate_poll":
            return try await toolGeneratePoll(arguments)
        case "list_generations":
            return toolListGenerations(arguments)
        case "get_generation":
            return try toolGetGeneration(arguments)
        case "cancel_generation":
            return try await toolCancelGeneration(arguments)
        case "retry_generation":
            return try await toolRetryGeneration(arguments)
        case "list_providers":
            return toolListProviders()
        case "evaluate_quality":
            return try await toolEvaluateQuality(arguments)
        case "submit_feedback":
            return try toolSubmitFeedback(arguments)
        case "submit_vote":
            return try await toolSubmitVote(arguments)
        case "get_metrics":
            return toolGetMetrics(arguments)
        case "budget_status":
            return await toolBudgetStatus()
        case "project_run":
            return try await toolProjectRun(arguments)
        case "health_check":
            return try await toolHealthCheck()
        default:
            throw OpenFlixError.invalidResponse("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool Implementations

    /// Resolve provider/model for the generate tools: explicit pair, or
    /// route == "smart" → PreferenceRouter (community win rates). Returns the
    /// routing JSON for the response when smart routing decided.
    private func resolveProviderModel(_ args: [String: AnyCodableValue]) async throws
        -> (provider: String, model: String, routing: [String: Any]?) {
        if let provider = optionalString(args, "provider"),
           let model = optionalString(args, "model") {
            return (provider, model, nil)
        }
        guard optionalString(args, "route") == "smart" else {
            throw OpenFlixError.invalidResponse("provider and model are required unless route == \"smart\"")
        }
        let decision = try await PreferenceRouter.decide(
            category: optionalString(args, "category"),
            needsImageToVideo: false,
            duration: optionalDouble(args, "duration_seconds")
        )
        return (decision.provider, decision.model, decision.json)
    }

    private func toolGenerate(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let prompt = try requireString(args, "prompt")
        let (provider, model, routing) = try await resolveProviderModel(args)

        let options = GenerationEngine.Options(
            pollInterval: 3,
            timeout: optionalDouble(args, "timeout") ?? 300,
            outputURL: nil,
            stream: false,
            skipDownload: false,
            maxRetries: optionalInt(args, "max_retries") ?? 0
        )

        let gen = try await GenerationEngine.submitAndWait(
            prompt: prompt,
            negativePrompt: optionalString(args, "negative_prompt"),
            provider: provider,
            model: model,
            durationSeconds: optionalDouble(args, "duration_seconds"),
            aspectRatio: optionalString(args, "aspect_ratio"),
            width: optionalInt(args, "width"),
            height: optionalInt(args, "height"),
            options: options
        )
        var result = gen.jsonRepresentation
        if let routing { result["routing"] = routing }
        return result
    }

    private func toolGenerateSubmit(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let prompt = try requireString(args, "prompt")
        let (provider, model, routing) = try await resolveProviderModel(args)

        let gen = try await GenerationEngine.submit(
            prompt: prompt,
            negativePrompt: optionalString(args, "negative_prompt"),
            provider: provider,
            model: model,
            durationSeconds: optionalDouble(args, "duration_seconds"),
            aspectRatio: optionalString(args, "aspect_ratio"),
            width: optionalInt(args, "width"),
            height: optionalInt(args, "height")
        )
        var result = gen.jsonRepresentation
        if let routing { result["routing"] = routing }
        return result
    }

    private func toolGeneratePoll(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard var gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }

        let shouldWait = optionalBool(args, "wait") ?? false
        if shouldWait && !gen.status.isTerminal {
            let timeout = optionalDouble(args, "timeout") ?? 300
            let options = GenerationEngine.Options(pollInterval: 3, timeout: timeout)
            gen = try await GenerationEngine.waitForCompletion(gen: &gen, apiKey: nil, options: options)
        }
        return gen.jsonRepresentation
    }

    private func toolListGenerations(_ args: [String: AnyCodableValue]) -> [String: Any] {
        var gens = GenerationStore.shared.all()

        if let status = optionalString(args, "status") {
            gens = gens.filter { $0.status.rawValue == status }
        }
        if let provider = optionalString(args, "provider") {
            gens = gens.filter { $0.provider == provider }
        }
        if let search = optionalString(args, "search") {
            let lower = search.lowercased()
            gens = gens.filter { $0.prompt.lowercased().contains(lower) }
        }

        let limit = optionalInt(args, "limit") ?? 20
        let results = Array(gens.prefix(limit))

        return [
            "generations": results.map { $0.jsonRepresentation },
            "total": gens.count,
            "returned": results.count,
        ]
    }

    private func toolGetGeneration(_ args: [String: AnyCodableValue]) throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        return gen.jsonRepresentation
    }

    private func toolCancelGeneration(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard !gen.status.isTerminal else {
            throw OpenFlixError.invalidResponse("Generation is already in terminal state: \(gen.status.rawValue)")
        }
        // Route through the real provider cancel path (same as `openflix cancel`),
        // preserving the local state flip as fallback when the provider has no
        // cancel API (cancelNotSupported) or the call fails.
        var remoteCancelled = false
        var note: String?
        switch await CancelService.attemptRemoteCancel(gen: gen, apiKey: nil) {
        case .cancelled:
            remoteCancelled = true
        case .notSupported(let error):
            note = "\(error.errorDescription ?? "cancel not supported") — cancelled locally only"
        case .bestEffortFailed:
            note = "provider cancel failed — cancelled locally only"
        case .noRemoteTask:
            note = "no remote task — cancelled locally only"
        }
        GenerationStore.shared.update(id: genId) {
            $0.status = .cancelled
            $0.completedAt = Date()
        }
        var result: [String: Any] = [
            "status": "cancelled",
            "generation_id": genId,
            "remote_cancelled": remoteCancelled,
        ]
        if let note { result["note"] = note }
        return result
    }

    private func toolRetryGeneration(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard gen.status == .failed else {
            throw OpenFlixError.invalidResponse("Can only retry failed generations (current: \(gen.status.rawValue))")
        }

        let newGen = try await GenerationEngine.submit(
            prompt: gen.prompt,
            negativePrompt: gen.negativePrompt,
            provider: gen.provider,
            model: gen.model,
            durationSeconds: gen.durationSeconds,
            aspectRatio: gen.aspectRatio,
            width: gen.widthPx,
            height: gen.heightPx,
            // Reproduce the original inputs — dropping these silently resubmits a
            // different, still-billed generation (see RetryCommand).
            referenceImageURL: gen.referenceImageURL.flatMap { URL(string: $0) },
            extraParams: gen.extraParams?.mapValues { $0.toAny() } ?? [:]
        )
        return newGen.jsonRepresentation
    }

    private func toolListProviders() -> [String: Any] {
        let models = ProviderRegistry.shared.allModels
        return [
            "providers": models.map { $0.jsonRepresentation },
            "count": models.count,
        ]
    }

    private func toolEvaluateQuality(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard gen.status == .succeeded else {
            throw OpenFlixError.invalidResponse("Can only evaluate succeeded generations")
        }
        guard let localPath = gen.localPath else {
            throw OpenFlixError.invalidResponse("No local video file for evaluation")
        }

        let evaluatorStr = optionalString(args, "evaluator") ?? "heuristic"
        let threshold = optionalDouble(args, "threshold") ?? 0
        let evaluatorType: QualityConfig.EvaluatorType = evaluatorStr == "llm-vision" ? .llmVision : .heuristic

        let config = QualityConfig(
            enabled: true,
            evaluator: evaluatorType,
            threshold: threshold
        )

        let result = try await QualityGate.evaluate(
            generation: gen,
            videoPath: localPath,
            shot: nil,
            config: config
        )

        return [
            "generation_id": genId,
            "score": result.score,
            "evaluator": result.evaluator,
            "reasoning": result.reasoning as Any,
            "dimensions": result.dimensions as Any,
            "passed": result.score >= threshold,
        ]
    }

    private func toolSubmitFeedback(_ args: [String: AnyCodableValue]) throws -> [String: Any] {
        let genId = try requireIdentifier(args, "generation_id")
        let score = try requireDouble(args, "score")
        _ = optionalString(args, "reason") // accepted but not stored by CLI metrics

        guard score >= 0 && score <= 100 else {
            throw OpenFlixError.invalidResponse("Score must be between 0 and 100")
        }

        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }

        ProviderMetricsStore.shared.recordFeedback(
            provider: gen.provider,
            model: gen.model,
            score: score
        )

        return [
            "status": "recorded",
            "generation_id": genId,
            "provider": gen.provider,
            "model": gen.model,
            "score": score,
        ]
    }

    private func toolSubmitVote(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let winnerId = try requireIdentifier(args, "winner_generation_id")
        let loserId = try requireIdentifier(args, "loser_generation_id")

        let result = try await PreferenceVoteClient.vote(
            winnerId: winnerId, loserId: loserId,
            category: optionalString(args, "category"),
            context: "mcp"
        )

        return [
            "status": "shared",
            "winner_generation_id": winnerId,
            "loser_generation_id": loserId,
            "accepted": result.accepted,
            "duplicates_ignored": result.duplicatesIgnored,
        ]
    }

    private func toolGetMetrics(_ args: [String: AnyCodableValue]) -> [String: Any] {
        var metrics = ProviderMetricsStore.shared.allMetrics()
        if let provider = optionalString(args, "provider") {
            metrics = metrics.filter { $0.provider == provider }
        }

        let sortKey = optionalString(args, "sort") ?? "quality"
        switch sortKey {
        case "latency":
            metrics.sort { $0.avgLatencyMs < $1.avgLatencyMs }
        case "cost":
            metrics.sort { $0.totalCostUSD < $1.totalCostUSD }
        case "success_rate":
            metrics.sort { $0.successRate > $1.successRate }
        default: // quality
            metrics.sort { $0.avgQuality > $1.avgQuality }
        }

        return [
            "metrics": metrics.map { $0.jsonRepresentation },
            "count": metrics.count,
        ]
    }

    private func toolBudgetStatus() async -> [String: Any] {
        return await BudgetManager.shared.statusSummary()
    }

    private func toolProjectRun(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let projectId = try requireIdentifier(args, "project_id")
        guard let project = ProjectStore.shared.get(projectId) else {
            throw OpenFlixError.generationNotFound("Project '\(projectId)' not found")
        }
        return [
            "project_id": projectId,
            "name": project.name,
            "status": "use 'openflix project run \(projectId)' for full execution",
        ]
    }

    private func toolHealthCheck() async throws -> [String: Any] {
        let available = ProviderRouter.availableProviders()
        let all = ProviderRegistry.shared.all.map { $0.providerId }
        return [
            "providers": all.map { id in
                [
                    "provider": id,
                    "configured": available.contains(id),
                ] as [String : Any]
            },
            "configured_count": available.count,
            "total_count": all.count,
        ]
    }

    // MARK: - Resource reading

    private func readResource(uri: String) async throws -> String {
        switch uri {
        case "openflix://providers":
            let models = ProviderRegistry.shared.allModels
            return jsonString(["providers": models.map { $0.jsonRepresentation }])
        case "openflix://metrics":
            let metrics = ProviderMetricsStore.shared.allMetrics()
            return jsonString(["metrics": metrics.map { $0.jsonRepresentation }])
        case "openflix://budget":
            let status = await BudgetManager.shared.statusSummary()
            return jsonString(status)
        default:
            break
        }

        // Templated reads. The id is validated *before* it reaches the stores,
        // which resolve it straight into `~/.openflix/<kind>/<id>.json`: an id
        // here is a path component chosen by a model, and `..` must never get
        // that far. Real ids are UUIDs, so nothing legitimate is rejected.
        if let id = templateID(uri, prefix: "openflix://generation/") {
            guard let gen = GenerationStore.shared.get(id) else {
                throw OpenFlixError.generationNotFound(id)
            }
            return jsonString(gen.jsonRepresentation)
        }
        if let id = templateID(uri, prefix: "openflix://recipe/") {
            guard let recipe = RecipeStore.shared.get(id) else {
                throw OpenFlixError.invalidResponse("No such recipe: \(id)")
            }
            return jsonString(Self.recipeJSON(recipe))
        }

        throw OpenFlixError.invalidResponse("Unknown resource: \(uri)")
    }

    /// The id in `openflix://<kind>/<id>`, or nil when the URI is not that shape
    /// or the id is not a well-formed identifier.
    private func templateID(_ uri: String, prefix: String) -> String? {
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        guard MCPIdentifier.isWellFormed(id) else { return nil }
        return id
    }

    /// A recipe as an agent needs to see it: enough to understand the template
    /// and its arguments, which is what makes `prompts/get recipe_<id>` legible.
    static func recipeJSON(_ recipe: CLIRecipe) -> [String: Any] {
        var d: [String: Any] = [
            "id": recipe.id,
            "name": recipe.name,
            "prompt_text": recipe.promptText,
            "negative_prompt_text": recipe.negativePromptText,
            "generation_count": recipe.generationCount,
            "prompt_name": "\(MCPToolRegistry.recipePromptPrefix)\(recipe.id)",
        ]
        if let v = recipe.provider        { d["provider"] = v }
        if let v = recipe.model           { d["model"] = v }
        if let v = recipe.aspectRatio     { d["aspect_ratio"] = v }
        if let v = recipe.durationSeconds, v.isFinite { d["duration_seconds"] = v }
        if let v = recipe.category        { d["category"] = v }
        if let args = recipe.args, !args.isEmpty {
            d["args"] = args.map { arg -> [String: Any] in
                var a: [String: Any] = ["name": arg.name, "type": arg.type,
                                        "required": arg.defaultValue == nil]
                if let d = arg.defaultValue { a["default"] = d.stringValue }
                if let c = arg.choices      { a["choices"] = c }
                if let s = arg.description  { a["description"] = s }
                return a
            }
        }
        return d
    }

    // MARK: - Helpers

    private func writeResponse(_ response: MCPResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response), let str = String(data: data, encoding: .utf8) {
            print(str)
            fflush(stdout)
            return
        }
        // A reply that will not serialise used to be dropped on the floor, which
        // on a request/response pipe is indistinguishable from a hang: the agent
        // waits for a line that is never coming. Answer with the error instead.
        let idEncoder = JSONEncoder()
        let idJSON = response.id
            .flatMap { try? idEncoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        print(#"{"error":{"code":-32603,"message":"Unserialisable reply"},"id":\#(idJSON),"jsonrpc":"2.0"}"#)
        fflush(stdout)
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func requireString(_ args: [String: AnyCodableValue], _ key: String) throws -> String {
        guard case .string(let v) = args[key] else {
            throw OpenFlixError.invalidResponse("Missing required parameter: \(key)")
        }
        return v
    }

    /// A record id from tool arguments, checked against the same grammar the
    /// resource templates use.
    ///
    /// `GenerationStore`, `RecipeStore` and `ProjectStore` all turn an id into a
    /// filename with `appendingPathComponent`, and every id arriving here was
    /// chosen by a model that may have been reading attacker-controlled text.
    /// Real ids are UUIDs, so this refuses nothing a caller legitimately has.
    private func requireIdentifier(_ args: [String: AnyCodableValue], _ key: String) throws -> String {
        let value = try requireString(args, key)
        guard MCPIdentifier.isWellFormed(value) else {
            throw OpenFlixError.invalidResponse(
                "Parameter '\(key)' is not a valid id (letters, digits, '.', '_' and '-' only, max \(MCPIdentifier.maxLength) characters)")
        }
        return value
    }

    private func requireDouble(_ args: [String: AnyCodableValue], _ key: String) throws -> Double {
        switch args[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: throw OpenFlixError.invalidResponse("Missing required parameter: \(key)")
        }
    }

    private func optionalString(_ args: [String: AnyCodableValue], _ key: String) -> String? {
        if case .string(let v) = args[key] { return v }
        return nil
    }

    private func optionalInt(_ args: [String: AnyCodableValue], _ key: String) -> Int? {
        if case .int(let v) = args[key] { return v }
        return nil
    }

    private func optionalDouble(_ args: [String: AnyCodableValue], _ key: String) -> Double? {
        switch args[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    private func optionalBool(_ args: [String: AnyCodableValue], _ key: String) -> Bool? {
        if case .bool(let v) = args[key] { return v }
        return nil
    }
}

// Extension for terminal status check
private extension CLIGeneration.GenerationStatus {
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }
}
