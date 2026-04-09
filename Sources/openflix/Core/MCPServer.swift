import Foundation

/// MCP server that communicates over stdio (stdin/stdout) using JSON-RPC 2.0.
actor MCPServer {

    private var initialized = false

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
        switch request.method {
        // Lifecycle
        case "initialize":
            return handleInitialize(request)
        case "notifications/initialized":
            return nil // notification, no response
        case "shutdown":
            return MCPResponse.success(id: request.id, result: .dictionary([:]))

        // Tool methods
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return await handleToolsCall(request)

        // Resource methods
        case "resources/list":
            return handleResourcesList(request)
        case "resources/read":
            return await handleResourcesRead(request)

        // Ping
        case "ping":
            return MCPResponse.success(id: request.id, result: .dictionary([:]))

        default:
            return MCPResponse.error(id: request.id, code: MCPErrorCode.methodNotFound,
                                     message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Lifecycle

    private func handleInitialize(_ request: MCPRequest) -> MCPResponse {
        initialized = true
        return MCPResponse.success(id: request.id, result: .dictionary([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .dictionary([
                "tools": .dictionary([:]),
                "resources": .dictionary([:]),
            ]),
            "serverInfo": .dictionary([
                "name": .string("openflix"),
                "version": .string("1.0.0"),
            ]),
        ]))
    }

    // MARK: - Tools

    private func handleToolsList(_ request: MCPRequest) -> MCPResponse {
        let tools = MCPToolRegistry.allTools.map { $0.toAnyCodable() }
        return MCPResponse.success(id: request.id, result: .dictionary([
            "tools": .array(tools)
        ]))
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
            return MCPResponse.success(id: request.id, result: .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string(jsonString(result)),
                    ])
                ])
            ]))
        } catch let error as OpenFlixError {
            let structured = StructuredError.from(error)
            return MCPResponse.success(id: request.id, result: .dictionary([
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

    private func handleResourcesList(_ request: MCPRequest) -> MCPResponse {
        let resources = MCPToolRegistry.allResources.map { $0.toAnyCodable() }
        return MCPResponse.success(id: request.id, result: .dictionary([
            "resources": .array(resources)
        ]))
    }

    private func handleResourcesRead(_ request: MCPRequest) async -> MCPResponse {
        guard let params = request.params,
              case .string(let uri) = params["uri"] else {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: "Missing 'uri' parameter")
        }

        do {
            let content = try await readResource(uri: uri)
            return MCPResponse.success(id: request.id, result: .dictionary([
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
                                     message: "Unknown resource: \(uri)")
        }
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
            return try toolCancelGeneration(arguments)
        case "retry_generation":
            return try await toolRetryGeneration(arguments)
        case "list_providers":
            return toolListProviders()
        case "evaluate_quality":
            return try await toolEvaluateQuality(arguments)
        case "submit_feedback":
            return try toolSubmitFeedback(arguments)
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

    private func toolGenerate(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let prompt = try requireString(args, "prompt")
        let provider = try requireString(args, "provider")
        let model = try requireString(args, "model")

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
        return gen.jsonRepresentation
    }

    private func toolGenerateSubmit(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let prompt = try requireString(args, "prompt")
        let provider = try requireString(args, "provider")
        let model = try requireString(args, "model")

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
        return gen.jsonRepresentation
    }

    private func toolGeneratePoll(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireString(args, "generation_id")
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
        let genId = try requireString(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        return gen.jsonRepresentation
    }

    private func toolCancelGeneration(_ args: [String: AnyCodableValue]) throws -> [String: Any] {
        let genId = try requireString(args, "generation_id")
        guard let gen = GenerationStore.shared.get(genId) else {
            throw OpenFlixError.generationNotFound(genId)
        }
        guard !gen.status.isTerminal else {
            throw OpenFlixError.invalidResponse("Generation is already in terminal state: \(gen.status.rawValue)")
        }
        GenerationStore.shared.update(id: genId) {
            $0.status = .cancelled
            $0.completedAt = Date()
        }
        return ["status": "cancelled", "generation_id": genId]
    }

    private func toolRetryGeneration(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let genId = try requireString(args, "generation_id")
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
            height: gen.heightPx
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
        let genId = try requireString(args, "generation_id")
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
        let genId = try requireString(args, "generation_id")
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
        let projectId = try requireString(args, "project_id")
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
            throw OpenFlixError.invalidResponse("Unknown resource: \(uri)")
        }
    }

    // MARK: - Helpers

    private func writeResponse(_ response: MCPResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(response),
              let str = String(data: data, encoding: .utf8) else { return }
        print(str)
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
