import CryptoKit
import Foundation
import OpenFlixKit

/// Everything the bridge decides before an action runs for a remote agent:
/// whether its grant allows the action at all, and — for spending — the
/// quote → approval → execute handshake that keeps money under a person's
/// control.
///
/// The handshake mirrors the one agent hosts like Harbor already run on their
/// own side (stage an action, ask the owner, re-check, run exactly once):
///
/// 1. `quote` prices the call, checks it fits the grant's daily cap, and
///    returns a single-use `op_hash` bound to the grant, the action and the
///    exact arguments.
/// 2. The agent host shows the owner the quote and gets a yes.
/// 3. `claim` hands the quote back — same grant, same action, same arguments,
///    not expired, not already used — and the cap is checked again, because
///    other spending may have landed in between.
///
/// Every spend also needs an `Idempotency-Key`, so a retry after a timeout
/// replays the first answer instead of billing twice.
actor BridgeGate {

    static let quoteTTL: TimeInterval = 15 * 60
    static let idempotencyTTL: TimeInterval = 24 * 60 * 60
    static let maxIdempotencyEntries = 2_000

    private let grants: AgentGrantStore
    private let now: @Sendable () -> Date

    init(grants: AgentGrantStore = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.grants = grants
        self.now = now
    }

    // MARK: - Authorization

    /// Why `grant` may not run an action with this effect, or nil if it may.
    nonisolated static func refusal(for descriptor: ActionDescriptor, grant: AgentGrant) -> ActionFailure? {
        guard grant.allows(descriptor.effect) else {
            let why = descriptor.effect == .spend && grant.effects.contains(.spend)
                ? "has a daily cap of $0"
                : "does not allow \(descriptor.effect.rawValue) actions"
            return ActionFailure(
                code: "GRANT_DENIED", errorClass: .policy,
                message: "Agent grant '\(grant.name)' \(why). A person can change that with `openflix agents grant`.",
                details: .object(["effect": .string(descriptor.effect.rawValue),
                                  "allowed_effects": .array(grant.effects.map { .string($0.rawValue) })]))
        }
        if descriptor.effect == .spend && !CLIActions.quotableActions.contains(descriptor.name) {
            let hint = descriptor.name == "generate"
                ? " It blocks for minutes; use generate_submit, then generate_poll."
                : ""
            return ActionFailure(
                code: "NOT_AVAILABLE_REMOTELY", errorClass: .policy,
                message: "'\(descriptor.name)' spends in a way the bridge cannot quote, so it is not available to remote agents.\(hint) Spending actions available: \(CLIActions.quotableActions.sorted().joined(separator: ", ")).")
        }
        return nil
    }

    // MARK: - Quotes

    private struct Quote {
        let grant: String
        let action: String
        let argumentsDigest: String
        let resolved: [String: AnyCodableValue]
        let estimatedCostUSD: Double
        let expiresAt: Date
    }

    private var quotes: [String: Quote] = [:]

    /// Prices a spend and checks it against the grant's cap. Returns the
    /// quote document the agent shows its owner.
    func quote(action: String, arguments: [String: AnyCodableValue],
               grant: AgentGrant) async throws -> JSONValue {
        let priced = try await CLIActions.quote(action, arguments: arguments)
        let spent = grants.spentToday(grant.name, now: now())
        if let refusal = capRefusal(grant: grant, spent: spent, estimate: priced.estimatedCostUSD) {
            throw refusal
        }

        purgeExpired()
        let opHash = Self.digest("\(grant.name)\n\(action)\n\(Self.canonical(arguments))\n\(UUID().uuidString)")
        quotes[opHash] = Quote(grant: grant.name, action: action,
                               argumentsDigest: Self.digest(Self.canonical(arguments)),
                               resolved: priced.resolvedArguments,
                               estimatedCostUSD: priced.estimatedCostUSD,
                               expiresAt: now().addingTimeInterval(Self.quoteTTL))

        return .object([
            "contract": .string(ActionResult.contract),
            "action": .string(action),
            "status": .string("quote"),
            "data": .object([
                "op_hash": .string(opHash),
                "expires_in_seconds": .int(Int(Self.quoteTTL)),
                "single_use": .bool(true),
                "summary": .string(priced.summary),
                "provider": .string(priced.provider),
                "model": .string(priced.model),
                "estimated_cost_usd": .double(Self.round4(priced.estimatedCostUSD)),
                "daily_cap_usd": .double(grant.dailyCapUSD),
                "spent_today_usd": .double(Self.round4(spent)),
                "cap_remaining_usd": .double(Self.round4(max(0, grant.dailyCapUSD - spent))),
                "next_step": .string("Show the summary and cost to the user. If they approve, POST the same arguments to /v1/actions/\(action) with headers OpenFlix-Quote: <op_hash> and Idempotency-Key: <a new unique value>."),
            ]),
        ])
    }

    /// Takes the quote for this exact call, or explains why there is none.
    /// Single use: a claimed quote is gone, whatever happens next.
    func claim(opHash: String?, action: String, arguments: [String: AnyCodableValue],
               grant: AgentGrant) throws -> (resolved: [String: AnyCodableValue], estimate: Double) {
        guard let opHash, !opHash.isEmpty else {
            throw ActionFailure(
                code: "QUOTE_REQUIRED", errorClass: .approvalRequired,
                message: "'\(action)' spends money: POST the same arguments to /v1/actions/\(action):preflight first, show the user the quote, then call again with the OpenFlix-Quote header.")
        }
        purgeExpired()
        guard let quote = quotes[opHash], quote.grant == grant.name else {
            throw ActionFailure(code: "QUOTE_STALE", errorClass: .conflict,
                                message: "No live quote with that op_hash for this agent — it expired, was already used, or the bridge restarted. Quote again.")
        }
        guard quote.action == action,
              quote.argumentsDigest == Self.digest(Self.canonical(arguments)) else {
            throw ActionFailure(code: "QUOTE_MISMATCH", errorClass: .conflict,
                                message: "The quote was for a different action or different arguments. The user approved that call, not this one; quote this one.")
        }
        quotes[opHash] = nil

        // Spending may have landed since the quote was issued.
        let spent = grants.spentToday(grant.name, now: now())
        if let refusal = capRefusal(grant: grant, spent: spent, estimate: quote.estimatedCostUSD) {
            throw refusal
        }
        return (quote.resolved, quote.estimatedCostUSD)
    }

    func recordSpend(grant: AgentGrant, amountUSD: Double) throws {
        try grants.recordSpend(grant.name, amountUSD: amountUSD, now: now())
    }

    private func capRefusal(grant: AgentGrant, spent: Double, estimate: Double) -> ActionFailure? {
        guard spent + estimate > grant.dailyCapUSD + 1e-9 else { return nil }
        return ActionFailure(
            code: "AGENT_CAP_EXCEEDED", errorClass: .policy,
            message: String(format: "This would take agent '%@' past its daily cap: $%.2f estimated + $%.2f already spent today > $%.2f. A person can raise the cap with `openflix agents grant`.",
                            grant.name, estimate, spent, grant.dailyCapUSD),
            details: .object(["estimated_cost_usd": .double(Self.round4(estimate)),
                              "spent_today_usd": .double(Self.round4(spent)),
                              "daily_cap_usd": .double(grant.dailyCapUSD)]))
    }

    private func purgeExpired() {
        let t = now()
        quotes = quotes.filter { $0.value.expiresAt > t }
    }

    // MARK: - Idempotency

    private enum Remembered {
        case inFlight(requestDigest: String)
        case done(requestDigest: String, response: JSONValue, at: Date)
    }

    private var remembered: [String: Remembered] = [:]

    enum IdempotencyDecision {
        /// Run it; call `finish` with the outcome.
        case proceed
        /// Already answered — return this, do not run it again.
        case replay(JSONValue)
    }

    /// Records that `key` is about to run this request for this grant.
    func begin(key: String, grant: AgentGrant, requestDigest: String) throws -> IdempotencyDecision {
        let slot = "\(grant.name)\n\(key)"
        purgeRemembered()
        switch remembered[slot] {
        case .none:
            remembered[slot] = .inFlight(requestDigest: requestDigest)
            return .proceed
        case .inFlight(let digest):
            throw ActionFailure(
                code: digest == requestDigest ? "IN_PROGRESS" : "IDEMPOTENCY_KEY_REUSED",
                errorClass: .conflict,
                message: digest == requestDigest
                    ? "This request is still running. Retry the same Idempotency-Key shortly to get its result."
                    : "That Idempotency-Key is already in use for a different request. Use a new key per request.")
        case .done(let digest, let response, _):
            guard digest == requestDigest else {
                throw ActionFailure(code: "IDEMPOTENCY_KEY_REUSED", errorClass: .conflict,
                                    message: "That Idempotency-Key was already used for a different request. Use a new key per request.")
            }
            return .replay(response)
        }
    }

    func finish(key: String, grant: AgentGrant, requestDigest: String, response: JSONValue) {
        remembered["\(grant.name)\n\(key)"] = .done(requestDigest: requestDigest, response: response, at: now())
    }

    /// A request that failed before anything was attempted can be retried
    /// with the same key.
    func forget(key: String, grant: AgentGrant) {
        remembered["\(grant.name)\n\(key)"] = nil
    }

    private func purgeRemembered() {
        let cutoff = now().addingTimeInterval(-Self.idempotencyTTL)
        remembered = remembered.filter {
            if case .done(_, _, let at) = $0.value { return at > cutoff }
            return true
        }
        if remembered.count > Self.maxIdempotencyEntries {
            let oldest = remembered.compactMap { entry -> (String, Date)? in
                if case .done(_, _, let at) = entry.value { return (entry.key, at) }
                return nil
            }.sorted { $0.1 < $1.1 }
            for (key, _) in oldest.prefix(remembered.count - Self.maxIdempotencyEntries) {
                remembered[key] = nil
            }
        }
    }

    // MARK: - Helpers

    /// Key-sorted JSON, so two spellings of the same arguments are the same
    /// arguments.
    nonisolated static func canonical(_ arguments: [String: AnyCodableValue]) -> String {
        JSONValue(.dictionary(arguments)).jsonString()
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func round4(_ v: Double) -> Double {
        v.isFinite ? (v * 10_000).rounded() / 10_000 : 0
    }
}
