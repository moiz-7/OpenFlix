import Foundation
import OpenFlixKit

/// Turns one HTTP request into one answer. Pure with respect to the network —
/// the server hands it parsed requests — so every route, refusal and the whole
/// spend handshake are testable without a socket.
///
/// Routes (all JSON; everything but `/v1/health` needs `Authorization: Bearer`):
///
///     GET  /v1/health                        liveness, no auth, says nothing private
///     GET  /v1/manifest                      the actions this agent's grant allows
///     POST /v1/actions/{name}:preflight      quote a spending action
///     POST /v1/actions/{name}                run an action (spend: OpenFlix-Quote +
///                                            Idempotency-Key headers required)
///
/// Answers are the `openflix.action_result.v1` envelope; the HTTP status
/// follows the error class (400 bad input, 403 policy, 404, 409 conflict,
/// 428 quote required, 502/503 upstream/unavailable).
struct BridgeRouter: Sendable {

    static let host = "openflix-bridge"

    let grants: AgentGrantStore
    let gate: BridgeGate
    /// Nil disables relaying to the app entirely.
    let relay: AppRelay?

    func handle(_ request: BridgeHTTPRequest) async -> BridgeHTTPResponse {
        // A browser page can reach 127.0.0.1 and would send its Origin. Agents
        // never do. Refusing it closes the drive-by path even before auth.
        if request.header("origin") != nil {
            return error(403, code: "BROWSER_ORIGIN", "Browser requests are not accepted by the OpenFlix bridge.")
        }

        if request.path == "/v1/health" {
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .json(200, .object(["ok": .bool(true), "service": .string(Self.host),
                                       "version": .string(OpenFlixVersion.current)]))
        }

        guard let grant = authenticate(request) else {
            return error(401, code: "UNAUTHORIZED",
                         "Send Authorization: Bearer <token>. A person issues tokens with `openflix agents grant`.",
                         headers: ["WWW-Authenticate": "Bearer"])
        }

        if request.path == "/v1/manifest" {
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return await manifest(for: grant)
        }

        let prefix = "/v1/actions/"
        guard request.path.hasPrefix(prefix) else {
            return error(404, code: "NOT_FOUND", "No route \(request.path). See GET /v1/manifest.")
        }
        guard request.method == "POST" else { return methodNotAllowed("POST") }

        var name = String(request.path.dropFirst(prefix.count))
        let isPreflight = name.hasSuffix(":preflight")
        if isPreflight { name = String(name.dropLast(":preflight".count)) }

        let arguments: [String: AnyCodableValue]
        switch Self.parseBody(request.body) {
        case .success(let parsed): arguments = parsed
        case .failure(let failure): return respond(name, .failure(failure), grant: grant)
        }

        let outcome = await run(name: name, arguments: arguments, preflight: isPreflight,
                                request: request, grant: grant)
        return respond(name, outcome, grant: grant)
    }

    // MARK: - Actions

    enum Outcome {
        case success(JSONValue)
        case quote(JSONValue)
        case replay(JSONValue)
        case failure(ActionFailure)
    }

    private func run(name: String, arguments: [String: AnyCodableValue], preflight: Bool,
                     request: BridgeHTTPRequest, grant: AgentGrant) async -> Outcome {
        // The CLI's own actions first; the app's only for names the CLI lacks.
        if let descriptor = CLIActionCatalog.descriptor(named: name) {
            if let refusal = BridgeGate.refusal(for: descriptor, grant: grant) { return .failure(refusal) }
            if preflight {
                guard descriptor.effect == .spend else {
                    return .failure(ActionFailure(code: "INPUT_INVALID", errorClass: .invalidInput,
                                                  message: "Only spending actions are quoted; '\(name)' can be called directly."))
                }
                do {
                    return .quote(try await gate.quote(action: name, arguments: arguments, grant: grant))
                } catch {
                    return .failure(CLIActions.failure(from: error))
                }
            }
            if descriptor.effect == .spend {
                return await spend(name, arguments: arguments, request: request, grant: grant)
            }
            return await runCLI(name, arguments: arguments, grant: grant)
        }

        if let relay {
            let descriptors: [ActionDescriptor]
            do {
                descriptors = try await relay.descriptors()
            } catch {
                if !Self.knownAppTools.contains(name) {
                    return .failure(ActionFailure(code: "NOT_FOUND", errorClass: .notFound,
                                                  message: "No action '\(name)'. See GET /v1/manifest."))
                }
                return .failure(Self.relayFailure(error))
            }
            if let descriptor = descriptors.first(where: { $0.name == name }) {
                if preflight {
                    return .failure(ActionFailure(code: "INPUT_INVALID", errorClass: .invalidInput,
                                                  message: "Only spending actions are quoted; '\(name)' can be called directly."))
                }
                if let refusal = BridgeGate.refusal(for: descriptor, grant: grant) { return .failure(refusal) }
                do {
                    try ActionValidator.validate(JSONValue(.dictionary(arguments)), against: descriptor.inputSchema)
                } catch {
                    return .failure(CLIActions.failure(from: error))
                }
                do {
                    switch try await relay.call(name, arguments: JSONValue(.dictionary(arguments))) {
                    case .success(let data): return .success(data)
                    case .failure(let failure): return .failure(failure)
                    }
                } catch {
                    return .failure(Self.relayFailure(error))
                }
            }
        }

        return .failure(ActionFailure(code: "NOT_FOUND", errorClass: .notFound,
                                      message: "No action '\(name)'. See GET /v1/manifest."))
    }

    /// The app's tools as of this release, so asking for one while the app is
    /// closed says "unavailable" rather than "no such action".
    static let knownAppTools: Set<String> = ["library_search", "player_state", "player_control", "generation_list"]

    private func runCLI(_ name: String, arguments: [String: AnyCodableValue],
                        grant: AgentGrant) async -> Outcome {
        do {
            let data = try await CLIActions.run(name, arguments: arguments,
                                                context: ActionContext(caller: .remoteAgent(grant.name)))
            return .success(JSONValue(any: data))
        } catch {
            return .failure(CLIActions.failure(from: error))
        }
    }

    /// Quote claimed, idempotency held, cap re-checked, then the one door —
    /// with the *quoted* arguments, so what was approved is what runs.
    private func spend(_ name: String, arguments: [String: AnyCodableValue],
                       request: BridgeHTTPRequest, grant: AgentGrant) async -> Outcome {
        guard let key = request.header("idempotency-key"), !key.isEmpty, key.count <= 200 else {
            return .failure(ActionFailure(
                code: "IDEMPOTENCY_KEY_REQUIRED", errorClass: .invalidInput,
                message: "Spending actions need an Idempotency-Key header (a new unique value per request), so a retry after a timeout cannot bill twice."))
        }
        let quoteHash = request.header("openflix-quote")
        let digest = BridgeGate.digest("\(name)\n\(BridgeGate.canonical(arguments))\n\(quoteHash ?? "")")

        do {
            switch try await gate.begin(key: key, grant: grant, requestDigest: digest) {
            case .replay(let previous): return .replay(previous)
            case .proceed: break
            }
        } catch {
            return .failure(CLIActions.failure(from: error))
        }

        let claimed: (resolved: [String: AnyCodableValue], estimate: Double)
        do {
            claimed = try await gate.claim(opHash: quoteHash, action: name, arguments: arguments, grant: grant)
        } catch {
            // Nothing was attempted, so the same key may be used again.
            await gate.forget(key: key, grant: grant)
            return .failure(CLIActions.failure(from: error))
        }

        let outcome = await runCLI(name, arguments: claimed.resolved, grant: grant)
        let envelope: JSONValue
        switch outcome {
        case .success(let data):
            do {
                try await gate.recordSpend(grant: grant, amountUSD: claimed.estimate)
            } catch {
                CLILog.error("bridge.ledger_write_failed", ["agent": grant.name, "error": "\(error)"])
            }
            envelope = ActionResult.success(action: name, data: data)
        case .failure(let failure):
            envelope = ActionResult.failure(action: name, failure)
        default:
            envelope = ActionResult.failure(action: name, ActionFailure(code: "INTERNAL_ERROR", errorClass: .internal,
                                                                         message: "unexpected outcome"))
        }
        await gate.finish(key: key, grant: grant, requestDigest: digest, response: envelope)
        return outcome
    }

    // MARK: - Manifest

    private func manifest(for grant: AgentGrant) async -> BridgeHTTPResponse {
        var entries: [JSONValue] = CLIActionCatalog.all
            .filter { BridgeGate.refusal(for: $0, grant: grant) == nil }
            .map { Self.tagged($0.manifestEntry, host: "openflix-cli") }

        var app: [String: JSONValue] = ["available": .bool(false)]
        if let relay {
            do {
                let tools = try await relay.descriptors()
                entries += tools
                    .filter { CLIActionCatalog.descriptor(named: $0.name) == nil }
                    .filter { BridgeGate.refusal(for: $0, grant: grant) == nil }
                    .map { Self.tagged($0.manifestEntry, host: AppRelay.host) }
                app["available"] = .bool(true)
            } catch {
                app["reason"] = .string(Self.relayFailure(error).message)
            }
        } else {
            app["reason"] = .string("app relay disabled (openflix serve --no-app)")
        }

        return .json(200, .object([
            "contract": .string(ActionManifest.contract),
            "host": .string(Self.host),
            "version": .string(OpenFlixVersion.current),
            "agent": .object([
                "name": .string(grant.name),
                "effects": .array(grant.effects.map { .string($0.rawValue) }),
                "daily_cap_usd": .double(grant.dailyCapUSD),
            ]),
            "app": .object(app),
            "actions": .array(entries),
        ]))
    }

    private static func tagged(_ entry: JSONValue, host: String) -> JSONValue {
        guard case .object(var object) = entry else { return entry }
        object["host"] = .string(host)
        return .object(object)
    }

    // MARK: - Plumbing

    private func authenticate(_ request: BridgeHTTPRequest) -> AgentGrant? {
        guard let value = request.header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return grants.authenticate(token: String(parts[1]).trimmingCharacters(in: .whitespaces))
    }

    static func parseBody(_ body: Data) -> Result<[String: AnyCodableValue], ActionFailure> {
        if body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .success([:]) }
        guard let value = try? JSONDecoder().decode(AnyCodableValue.self, from: body),
              case .dictionary(let object) = value else {
            return .failure(ActionFailure(code: "INPUT_INVALID", errorClass: .invalidInput,
                                          message: "The request body must be a JSON object of arguments."))
        }
        return .success(object)
    }

    static func relayFailure(_ error: Error) -> ActionFailure {
        switch error {
        case AppRelay.RelayError.unavailable(let message):
            return ActionFailure(code: "APP_UNAVAILABLE", errorClass: .unavailable, message: message, retryable: true)
        case AppRelay.RelayError.protocolError(let message):
            return ActionFailure(code: "APP_PROTOCOL_ERROR", errorClass: .upstream, message: message)
        default:
            return ActionFailure(code: "APP_UNAVAILABLE", errorClass: .unavailable,
                                 message: error.localizedDescription, retryable: true)
        }
    }

    private func respond(_ action: String, _ outcome: Outcome, grant: AgentGrant) -> BridgeHTTPResponse {
        let status: Int
        let body: JSONValue
        var headers: [String: String] = [:]
        switch outcome {
        case .success(let data):
            status = 200
            body = ActionResult.success(action: action, data: data)
        case .quote(let quote):
            status = 200
            body = quote
        case .replay(let previous):
            // The first answer, status and all.
            status = previous["status"]?.stringValue == "ok" ? 200
                : (previous["error"]?["class"]?.stringValue.flatMap(ActionErrorClass.init(rawValue:))?.httpStatus ?? 409)
            body = previous
            headers["Idempotent-Replayed"] = "true"
        case .failure(let failure):
            status = failure.errorClass.httpStatus
            body = ActionResult.failure(action: action, failure)
        }
        // Metadata only: who, what, how it went. Never the arguments — they
        // carry prompts, which stay out of logs everywhere in this CLI.
        CLILog.info("bridge.request", [
            "agent": grant.name, "action": action, "http_status": status,
            "status": body["status"]?.stringValue ?? "",
            "error_code": body["error"]?["code"]?.stringValue ?? "",
        ])
        return .json(status, body, headers: headers)
    }

    private func error(_ status: Int, code: String, _ message: String,
                       headers: [String: String] = [:]) -> BridgeHTTPResponse {
        .json(status, .object(["error": .object(["code": .string(code), "message": .string(message)])]),
              headers: headers)
    }

    private func methodNotAllowed(_ allowed: String) -> BridgeHTTPResponse {
        error(405, code: "METHOD_NOT_ALLOWED", "Use \(allowed).", headers: ["Allow": allowed])
    }
}
