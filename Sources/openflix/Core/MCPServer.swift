import Foundation
import OpenFlixKit

/// Serialises every write to stdout.
///
/// The response loop is serial, but a running `project_run` emits
/// `notifications/progress` from concurrently executing shots. Two `print`s
/// interleaving would produce a line that is not a JSON-RPC message, which on
/// this transport is unrecoverable — the framing *is* the newline.
private let mcpStdoutLock = NSLock()

/// A tool that understood the call perfectly and declined to act.
///
/// This is deliberately **not** a JSON-RPC `error`. That layer is for protocol
/// failures — a malformed request, an unknown method — and a client is entitled
/// to treat one as a transport problem. "I will not spend your money without a
/// cost ceiling" is a result the model must read and act on, which is exactly
/// what `isError: true` inside a tool result is for. The body is a JSON object
/// carrying the numbers needed to build the corrected call.
struct MCPToolRefusal: Error {
    let code: String
    let message: String
    let details: [String: Any]

    var payload: [String: Any] {
        var d = details
        d["error"] = code
        d["message"] = message
        return d
    }
}

/// Set by a watchdog task, read by the task that started it.
final class MCPTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Seconds → nanoseconds without a trapping conversion.
///
/// `UInt64(someDouble)` aborts the process on a non-finite or out-of-range
/// value, and this one comes from a tool argument. The caller clamps first;
/// this is the belt to that pair of braces.
func nanoseconds(_ seconds: Double) -> UInt64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return UInt64(Swift.min(seconds, 86_400) * 1_000_000_000)
}

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

    /// Set when serving a remote agent over `openflix serve`'s `/mcp`: its
    /// grant decides the tool list and every call. Nil for `openflix mcp`.
    private let remote: RemoteMCPGateway?

    init(remote: RemoteMCPGateway? = nil) {
        self.remote = remote
    }

    private var instructionsText: String {
        remote == nil ? Self.instructions : RemoteMCPGateway.instructions
    }

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
            return complete(id: request.id, await toolsListResult())
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
            "instructions": .string(instructionsText),
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
            "instructions": .string(instructionsText),
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
        + "project_run spends money once per shot across a whole graph: called with only a project_id it spends nothing "
        + "and returns a cost plan; executing needs confirm=true and an explicit max_cost_usd ceiling. "
        + "To show the user a video, call play_video (opens it in the OpenFlix player) — never `open`, VLC or "
        + "QuickTime — or attach it to a chat reply as MEDIA:<local_path>. Prefer a saved recipe (list_recipes, "
        + "run_recipe) over a raw prompt when one fits. "
        + "Everything else here reads local state. Saved .openflix recipes are exposed as prompts; "
        + "rendering one produces prompt text and never submits anything."

    // MARK: - Tools

    private func toolsListResult() async -> AnyCodableValue {
        let definitions = if let remote { await remote.toolDefinitions() } else { MCPToolRegistry.allTools }
        let tools = definitions.map { $0.toAnyCodable() }
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

        // Progress is opt-in: a client that wants it puts a token in the
        // request's `_meta`, and we send `notifications/progress` against that
        // token. No token means no notifications, which is why adding this
        // changes nothing for every client that exists today.
        let progressToken = params["_meta"]?["progressToken"]

        do {
            let result = try await dispatchTool(name: toolName, arguments: arguments,
                                                progressToken: progressToken)
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
        } catch let refusal as MCPToolRefusal {
            // In-band, like every other tool failure here, and deliberately
            // without `structuredContent`: the spec only guarantees a
            // structured result conforms to `outputSchema` on success, and a
            // strict client should not have to validate a refusal against it.
            // The text block is JSON, so nothing is lost.
            return complete(id: request.id, .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string(jsonString(refusal.payload)),
                    ])
                ]),
                "isError": .bool(true),
            ]))
        } catch let failure as ActionFailure {
            // A grant, quote or cap decision (remote agents): in-band, with the
            // class an agent can branch on.
            var body: [String: Any] = ["code": failure.code, "class": failure.errorClass.rawValue,
                                       "message": failure.message, "retryable": failure.retryable]
            if let details = failure.details { body["details"] = details.anyValue }
            return complete(id: request.id, .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string(jsonString(body)),
                    ])
                ]),
                "isError": .bool(true),
            ]))
        } catch let input as ActionInputError {
            // The arguments did not match the tool's schema, so nothing ran.
            // Same in-band shape as every other refusal of bad input.
            var body: [String: Any] = ["code": ErrorCode.inputInvalid.rawValue,
                                       "message": input.message, "retryable": false]
            if let argument = input.argument { body["details"] = ["argument": argument] }
            return complete(id: request.id, .dictionary([
                "content": .array([
                    .dictionary([
                        "type": .string("text"),
                        "text": .string(jsonString(body)),
                    ])
                ]),
                "isError": .bool(true),
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
        // Resources are reads of this machine's store; a remote grant without
        // read sees none.
        let resources = (remote.map { $0.grant.allows(.read) } ?? true)
            ? MCPToolRegistry.allResources.map { $0.toAnyCodable() } : []
        return Self.cacheable(["resources": .array(resources)], ttlMs: Self.resourceListTTLms)
    }

    private func resourceTemplatesResult() -> AnyCodableValue {
        let templates = MCPToolRegistry.allResourceTemplates.map { $0.toAnyCodable() }
        return Self.cacheable(["resourceTemplates": .array(templates)], ttlMs: Self.resourceListTTLms)
    }

    private func handleResourcesRead(_ request: MCPRequest) async -> MCPResponse {
        if let remote, !remote.grant.allows(.read) {
            return MCPResponse.error(id: request.id, code: MCPErrorCode.invalidParams,
                                     message: "This agent grant does not allow reads.")
        }
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

    /// Every tool call goes through `CLIActions.run` — the same door
    /// `openflix action run` uses — so argument validation cannot differ
    /// between this server and any other surface.
    private func dispatchTool(name: String, arguments: [String: AnyCodableValue],
                              progressToken: AnyCodableValue? = nil) async throws -> [String: Any] {
        if let remote {
            return try await remote.call(name, arguments: arguments)
        }
        let progress: (@Sendable (ActionProgress) -> Void)? = progressToken.map { token in
            { @Sendable p in Self.sendProgress(token: token, completed: p.completed, total: p.total, message: p.message) }
        }
        return try await CLIActions.run(name, arguments: arguments,
                                        context: ActionContext(caller: .localAgent(nil), progress: progress))
    }

    // MARK: - project_run (transport side)
    //
    // The tool itself is `CLIActions.toolProjectRun`. What stays here is what
    // only this transport has: the stdio progress notifications, and the
    // names tests have always reached for.

    static let projectRunDefaultTimeout = CLIActions.projectRunDefaultTimeout
    static let projectRunMaxTimeout = CLIActions.projectRunMaxTimeout

    func clampedRunTimeout(_ args: [String: AnyCodableValue]) -> Double {
        CLIActions.clampedRunTimeout(args)
    }

    /// `notifications/progress`. Spelled here rather than in `MCPMethod`
    /// because that enum belongs to the protocol workstream; fold it in there
    /// when the two files are next touched together.
    static let progressNotification = "notifications/progress"

    /// The `DAGProgress` sink, or nil when the client did not ask for progress.
    static func progressReporter(token: AnyCodableValue?)
        -> (@Sendable (DAGProgress) -> Void)? {
        guard let token else { return nil }
        return { p in
            sendProgress(token: token, completed: p.completed, total: p.total,
                         message: CLIActions.progressMessage(p))
        }
    }

    nonisolated static func sendProgress(token: AnyCodableValue?, completed: Int,
                                         total: Int, message: String) {
        guard let token else { return }
        writeNotification(progressNotification, [
            "progressToken": token,
            "progress": .int(completed),
            "total": .int(total),
            "message": .string(message),
        ])
    }

    /// Server-to-client notification. Nothing waits on it and nothing answers
    /// it, so a serialisation failure is dropped rather than escalated — the
    /// alternative is corrupting the response stream to report a lost hint.
    nonisolated static func writeNotification(_ method: String,
                                              _ params: [String: AnyCodableValue]) {
        guard let line = notificationLine(method, params) else { return }
        mcpStdoutLock.lock()
        print(line)
        fflush(stdout)
        mcpStdoutLock.unlock()
    }

    /// The exact bytes `writeNotification` would emit. Split out so a test can
    /// assert the framing without capturing the process's stdout.
    nonisolated static func notificationLine(_ method: String,
                                             _ params: [String: AnyCodableValue]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let notification = MCPNotification(jsonrpc: "2.0", method: method, params: params)
        guard let data = try? encoder.encode(notification) else { return nil }
        return String(data: data, encoding: .utf8)
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
            // Same lock as the progress notifications: a reply must never
            // interleave with a notification a still-running tool is emitting.
            mcpStdoutLock.lock()
            print(str)
            fflush(stdout)
            mcpStdoutLock.unlock()
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
}
