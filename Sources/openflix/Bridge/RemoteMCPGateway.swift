import Foundation
import OpenFlixKit

/// What one remote agent's grant allows over MCP, and how its calls run.
///
/// `openflix serve` answers MCP at `/mcp` (Streamable HTTP) for agents such as
/// OpenClaw and Hermes, through the same protocol engine as `openflix mcp`.
/// This is the part that differs for a remote caller:
///
/// - **tools/list** shows only what the grant allows — the CLI's actions and,
///   when the app is open with agent access on, the app's own tools.
/// - **Spending is two tool calls.** An MCP client cannot add a header per
///   call, so the bridge's quote handshake is carried by tools instead:
///   `request_spend` prices the call and returns a single-use `op_hash`; the
///   agent shows the user the summary; `confirm_spend` runs exactly the quoted
///   call, once. Spending tools are never offered directly.
/// - Every call is checked against the grant again — never trusted from the list.
struct RemoteMCPGateway: Sendable {

    let grant: AgentGrant
    let gate: BridgeGate
    let relay: AppRelay?

    static let instructions =
        "OpenFlix over your agent grant: generate video through the user's own provider accounts, run their saved "
        + "recipes, and play video for them in the OpenFlix player. To show the user a video, call play_video — never "
        + "`open`, VLC or QuickTime — or attach it to your chat reply as MEDIA:<local_path>. "
        + "SPENDING IS TWO STEPS: call request_spend with the action (generate_submit, run_recipe or retry_generation) "
        + "and its arguments, show the user the summary and estimated cost, and only after they approve call "
        + "confirm_spend with the op_hash. Then poll with generate_poll. Your grant's daily cap is enforced here."

    // MARK: - Tool list

    func toolDefinitions() async -> [MCPToolDefinition] {
        var tools = CLIActionCatalog.all
            .filter { $0.effect != .spend && BridgeGate.refusal(for: $0, grant: grant) == nil }
        if grant.allows(.spend) {
            tools += [Self.requestSpend, Self.confirmSpend]
        }
        if let relay, let app = try? await relay.descriptors() {
            tools += app.filter { tool in
                CLIActionCatalog.descriptor(named: tool.name) == nil
                    && BridgeGate.refusal(for: tool, grant: grant) == nil
            }
        }
        return tools.map(MCPToolDefinition.init)
    }

    // MARK: - Calls

    func call(_ name: String, arguments: [String: AnyCodableValue]) async throws -> [String: Any] {
        switch name {
        case Self.requestSpend.name:
            return try await requestSpend(arguments)
        case Self.confirmSpend.name:
            return try await confirmSpend(arguments)
        default:
            break
        }

        if let descriptor = CLIActionCatalog.descriptor(named: name) {
            if let refusal = BridgeGate.refusal(for: descriptor, grant: grant) { throw refusal }
            if descriptor.effect == .spend {
                throw ActionFailure(code: "USE_REQUEST_SPEND", errorClass: .approvalRequired,
                                    message: "'\(name)' spends money. Call request_spend with {\"action\": \"\(name)\", \"arguments\": {…}}, show the user the quote, then confirm_spend.")
            }
            return try await CLIActions.run(name, arguments: arguments,
                                            context: ActionContext(caller: .remoteAgent(grant.name)))
        }

        guard let relay else {
            throw ActionFailure(code: "NOT_FOUND", errorClass: .notFound, message: "No tool '\(name)'.")
        }
        let descriptors: [ActionDescriptor]
        do { descriptors = try await relay.descriptors() } catch { throw BridgeRouter.relayFailure(error) }
        guard let descriptor = descriptors.first(where: { $0.name == name }) else {
            throw ActionFailure(code: "NOT_FOUND", errorClass: .notFound, message: "No tool '\(name)'.")
        }
        if let refusal = BridgeGate.refusal(for: descriptor, grant: grant) { throw refusal }
        try ActionValidator.validate(JSONValue(.dictionary(arguments)), against: descriptor.inputSchema)
        let outcome: Result<JSONValue, ActionFailure>
        do { outcome = try await relay.call(name, arguments: JSONValue(.dictionary(arguments))) }
        catch { throw BridgeRouter.relayFailure(error) }
        switch outcome {
        case .success(let data):
            if case .object = data { return (data.anyValue as? [String: Any]) ?? [:] }
            return ["result": data.anyValue]
        case .failure(let failure):
            throw failure
        }
    }

    private func requestSpend(_ arguments: [String: AnyCodableValue]) async throws -> [String: Any] {
        guard grant.allows(.spend) else {
            throw BridgeGate.refusal(for: Self.requestSpend, grant: grant)
                ?? ActionFailure(code: "GRANT_DENIED", errorClass: .policy, message: "This grant may not spend.")
        }
        try ActionValidator.validate(JSONValue(.dictionary(arguments)), against: Self.requestSpend.inputSchema)
        let action = try CLIActions.requireString(arguments, "action")
        let inner = arguments["arguments"]?.objectValue ?? [:]
        let quote = try await gate.quote(action: action, arguments: inner, grant: grant)
        var data = (quote["data"]?.anyValue as? [String: Any]) ?? [:]
        data["action"] = action
        data["next_step"] = "Show the user the summary and estimated cost. Only if they approve, call confirm_spend with this op_hash. It expires in \(Int(BridgeGate.quoteTTL / 60)) minutes and works once."
        return data
    }

    private func confirmSpend(_ arguments: [String: AnyCodableValue]) async throws -> [String: Any] {
        try ActionValidator.validate(JSONValue(.dictionary(arguments)), against: Self.confirmSpend.inputSchema)
        let opHash = try CLIActions.requireString(arguments, "op_hash")

        // A retry of a confirmation that already ran answers with its result
        // instead of "stale", so a dropped response cannot read as a failure.
        let key = "mcp-confirm:\(opHash)"
        switch try await gate.begin(key: key, grant: grant, requestDigest: opHash) {
        case .replay(let previous):
            // The first answer, success or failure, exactly as it was.
            if let failure = previous["failure"] {
                throw ActionFailure(code: failure["code"]?.stringValue ?? "FAILED",
                                    errorClass: failure["class"]?.stringValue.flatMap(ActionErrorClass.init(rawValue:)) ?? .internal,
                                    message: failure["message"]?.stringValue ?? "",
                                    retryable: false, details: .object(["replayed": .bool(true)]))
            }
            var replayed = (previous["result"]?.anyValue as? [String: Any]) ?? [:]
            replayed["replayed"] = true
            return replayed
        case .proceed:
            break
        }

        let claimed: (action: String, resolved: [String: AnyCodableValue], estimate: Double)
        do {
            claimed = try await gate.claim(opHash: opHash, grant: grant)
        } catch {
            await gate.forget(key: key, grant: grant)
            throw error
        }
        do {
            let result = try await CLIActions.run(claimed.action, arguments: claimed.resolved,
                                                  context: ActionContext(caller: .remoteAgent(grant.name)))
            try? await gate.recordSpend(grant: grant, amountUSD: claimed.estimate)
            await gate.finish(key: key, grant: grant, requestDigest: opHash,
                              response: .object(["result": JSONValue(any: result)]))
            return result
        } catch {
            let failure = CLIActions.failure(from: error)
            await gate.finish(key: key, grant: grant, requestDigest: opHash,
                              response: .object(["failure": .object([
                                  "code": .string(failure.code), "class": .string(failure.errorClass.rawValue),
                                  "message": .string(failure.message)])]))
            throw failure
        }
    }

    // MARK: - The two spend tools

    static let requestSpend = ActionDescriptor(
        name: "request_spend",
        title: "Quote a paid action (spends nothing)",
        description: "Step 1 of spending: price a paid action — generate_submit, run_recipe or retry_generation — without running it. Returns a summary, the estimated cost, what is left of your daily cap, and a single-use op_hash. Show the user the summary and cost; call confirm_spend only after they approve.",
        effect: .read, openWorld: false,
        inputSchema: JSONSchema.object(
            required: ["action", "arguments"],
            properties: [
                "action": JSONSchema.enumeration("The paid action to quote",
                                                 CLIActions.quotableActions.sorted()),
                "arguments": JSONSchema.freeformObject("That action's arguments, exactly as you would pass them to it"),
            ]),
        outputSchema: JSONSchema.result(
            required: ["op_hash", "summary", "estimated_cost_usd"],
            properties: [
                "op_hash": JSONSchema.string("Pass this to confirm_spend after the user approves"),
                "summary": JSONSchema.string("One line to show the user"),
                "estimated_cost_usd": JSONSchema.number("Estimated cost in USD"),
                "cap_remaining_usd": JSONSchema.number("What is left of today's cap before this call"),
                "expires_in_seconds": JSONSchema.integer("How long the quote is good for"),
            ]))

    static let confirmSpend = ActionDescriptor(
        name: "confirm_spend",
        title: "Run a quoted paid action (spends money)",
        description: "Step 2 of spending: run exactly the call request_spend quoted, once. Only after the user approved that quote. SPENDS THE USER'S OWN PROVIDER CREDIT. Retrying the same op_hash returns the first result rather than spending again.",
        effect: .spend, openWorld: true,
        inputSchema: JSONSchema.object(
            required: ["op_hash"],
            properties: ["op_hash": JSONSchema.string("The op_hash from request_spend", maxLength: 128)]),
        outputSchema: CLIActionCatalog.generationSchema,
        returnsUntrustedText: true)
}
