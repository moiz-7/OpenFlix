import Foundation

// MARK: - Who is asking

/// Who invoked an action. Surfaces set it; policy and audit read it.
public enum ActionCaller: Equatable, Sendable {
    /// A person at a terminal.
    case cli
    /// A person in the app.
    case ui
    /// An agent on this machine (an MCP client, a CLI-wrapping skill). The
    /// name is whatever the agent reported, and is informational only.
    case localAgent(String?)
    /// An agent reaching in over a network bridge, identified by its grant.
    case remoteAgent(String)
    /// A Shortcut or Siri.
    case shortcut

    public var label: String {
        switch self {
        case .cli: return "cli"
        case .ui: return "ui"
        case .localAgent(let name): return name.map { "local_agent:\($0)" } ?? "local_agent"
        case .remoteAgent(let grant): return "remote_agent:\(grant)"
        case .shortcut: return "shortcut"
        }
    }
}

/// Progress from a long-running action, for surfaces that can show it.
public struct ActionProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let message: String

    public init(completed: Int, total: Int, message: String) {
        self.completed = completed
        self.total = total
        self.message = message
    }
}

/// What an action knows about the call it is serving.
public struct ActionContext: Sendable {
    public let caller: ActionCaller
    /// Nil when the surface cannot deliver progress.
    public let progress: (@Sendable (ActionProgress) -> Void)?

    public init(caller: ActionCaller, progress: (@Sendable (ActionProgress) -> Void)? = nil) {
        self.caller = caller
        self.progress = progress
    }
}

// MARK: - The result envelope

/// Coarse failure classes an agent can branch on without knowing a host's
/// individual error codes. An HTTP bridge maps each to one status.
public enum ActionErrorClass: String, Codable, CaseIterable, Sendable {
    case invalidInput = "invalid_input"
    case notFound = "not_found"
    /// A rule said no: budget, safety, a hook, a missing grant.
    case policy
    /// Would run, but a person must approve it first.
    case approvalRequired = "approval_required"
    case conflict
    case rateLimited = "rate_limited"
    /// A provider or remote service failed.
    case upstream
    /// Something this action needs is not available right now.
    case unavailable
    case `internal`

    /// A refusal means nothing was attempted — the caller can fix the call and
    /// try again at no cost. Everything else was attempted and failed.
    public var isRefusal: Bool {
        switch self {
        case .invalidInput, .notFound, .policy, .approvalRequired, .conflict: return true
        case .rateLimited, .upstream, .unavailable, .internal: return false
        }
    }

    public var httpStatus: Int {
        switch self {
        case .invalidInput: return 400
        case .notFound: return 404
        case .policy: return 403
        case .approvalRequired: return 428
        case .conflict: return 409
        case .rateLimited: return 429
        case .upstream: return 502
        case .unavailable: return 503
        case .internal: return 500
        }
    }
}

/// An action that did not succeed, in the envelope's terms.
public struct ActionFailure: Error, Equatable, Sendable {
    /// The host's own machine-readable code (e.g. `BUDGET_EXCEEDED`).
    public let code: String
    public let errorClass: ActionErrorClass
    public let message: String
    public let retryable: Bool
    public let details: JSONValue?

    public init(code: String, errorClass: ActionErrorClass, message: String,
                retryable: Bool = false, details: JSONValue? = nil) {
        self.code = code
        self.errorClass = errorClass
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    public init(_ input: ActionInputError) {
        var details: JSONValue?
        if let argument = input.argument { details = .object(["argument": .string(argument)]) }
        self.init(code: "INPUT_INVALID", errorClass: .invalidInput,
                  message: input.message, retryable: false, details: details)
    }
}

/// The one result shape every non-MCP surface returns.
///
/// MCP keeps its own shape (`structuredContent` is the bare result, and a
/// failure is `isError`), because its `outputSchema` contract describes the
/// bare result. Everything else — `openflix action run`, an HTTP bridge —
/// returns this, so an agent parses one thing.
public enum ActionResult {
    public static let contract = "openflix.action_result.v1"

    public static func success(action: String, data: JSONValue) -> JSONValue {
        .object([
            "contract": .string(contract),
            "action": .string(action),
            "status": .string("ok"),
            "data": data,
        ])
    }

    public static func failure(action: String, _ failure: ActionFailure) -> JSONValue {
        var error: [String: JSONValue] = [
            "code": .string(failure.code),
            "class": .string(failure.errorClass.rawValue),
            "message": .string(failure.message),
            "retryable": .bool(failure.retryable),
        ]
        if let details = failure.details { error["details"] = details }
        return .object([
            "contract": .string(contract),
            "action": .string(action),
            "status": .string(failure.errorClass.isRefusal ? "refused" : "failed"),
            "error": .object(error),
        ])
    }
}
