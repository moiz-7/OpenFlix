import Foundation

// MARK: - MCP JSON-RPC 2.0 Protocol Types

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: AnyCodableValue?
    let method: String
    let params: [String: AnyCodableValue]?
}

struct MCPResponse: Codable {
    let jsonrpc: String
    let id: AnyCodableValue?
    let result: AnyCodableValue?
    let error: MCPError?

    static func success(id: AnyCodableValue?, result: AnyCodableValue) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    static func error(id: AnyCodableValue?, code: Int, message: String, data: AnyCodableValue? = nil) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: nil, error: MCPError(code: code, message: message, data: data))
    }
}

struct MCPError: Codable {
    let code: Int
    let message: String
    let data: AnyCodableValue?
}

struct MCPNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: [String: AnyCodableValue]?
}

// MARK: - Protocol revisions and eras (C0-2)
//
// The Model Context Protocol changed shape on **2026-07-28**. That revision
// removed the session from the protocol core: there is no
// `initialize`/`initialized` handshake and no `Mcp-Session-Id`. Instead **every
// request carries its own protocol version, client identity and client
// capabilities** in `_meta`, a server advertises itself through a
// `server/discover` RPC, and every result carries a `resultType` discriminator
// so a client can tell a finished answer from one that needs more input.
//
// The spec calls the two shapes **modern** (per-request metadata) and **legacy**
// (`initialize` handshake), and its compatibility matrix is blunt about mixing
// them:
//
//   | Client   | Server   | Outcome   |
//   | Modern   | Legacy   | **Fails** |
//   | Legacy   | Modern   | **Fails** |
//   | Dual-era | either   | Works     |
//   | either   | Dual-era | Works     |
//
// `openflix mcp` shipped legacy-only (`2024-11-05`). That is the row that
// matters, and it matters *more* here than in the OpenFlix app: this is the
// server that exposes `generate`, `generate_submit` and `project_run` — the one
// that spends the user's own provider credit. The app's server refuses
// generation by name and points agents here. So a modern-only client would find
// the read-only half of the product working and the half that actually creates
// video silently unavailable, and "fails" in that matrix explicitly includes
// *staying silent* or *answering an era-ambiguous method under legacy
// semantics*.
//
// Hence dual-era: `initialize` keeps working exactly as it does today for every
// client in the wild, and `server/discover` + per-request `_meta` works for the
// ones arriving next. The transport does not change — the spec's transports page
// says a custom transport over a reliable byte stream **SHOULD** reuse the stdio
// framing, which is the newline-delimited JSON-RPC already on this wire.

enum MCPProtocolVersion {

    /// The current revision: stateless core, per-request `_meta`,
    /// `server/discover`, `resultType` on every result.
    static let modern = "2026-07-28"

    /// The revision that introduced `structuredContent`, `outputSchema` and tool
    /// `annotations` — all three of which this server now emits, which is what
    /// makes claiming it honest rather than decorative.
    static let structured = "2025-06-18"

    /// The revision `openflix mcp` shipped with. Kept because a client pinned to
    /// it is a client that works today, and breaking it to "be modern" would
    /// trade a real user for a hypothetical one.
    static let legacy = "2024-11-05"

    /// Every revision this server serves, newest first.
    ///
    /// Deliberately short: each entry is a revision whose behaviour was read and
    /// implemented. `2025-11-25` and `2025-03-26` are real revisions we have not
    /// verified, so we do not claim them — claiming a version you have not read
    /// is how a client ends up with a subtly wrong answer instead of an honest
    /// `UnsupportedProtocolVersionError`.
    static let supported: [String] = [modern, structured, legacy]

    static func isSupported(_ version: String) -> Bool {
        supported.contains(version)
    }

    /// The revision to echo from a legacy `initialize` reply.
    ///
    /// A legacy client asking for a version we serve gets that version back;
    /// anything else — including a client that somehow asks for the modern
    /// revision through the handshake that revision deleted — gets `legacy`,
    /// which is the floor every MCP client in the wild can speak.
    static func negotiateLegacy(requested: String?) -> String {
        guard let requested, isSupported(requested), requested != modern else { return legacy }
        return requested
    }
}

/// The `_meta` keys the 2026-07-28 schema reserves on a request. The
/// `io.modelcontextprotocol/` prefix is reserved for the protocol itself, so
/// they are spelled out once here rather than inline at each use site.
enum MCPRequestMetaKey {
    /// `RequestMetaObject."io.modelcontextprotocol/protocolVersion"` — required.
    static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    /// `…/clientInfo` — optional `{name, version}`, display/logging only.
    static let clientInfo = "io.modelcontextprotocol/clientInfo"
    /// `…/clientCapabilities` — required; an empty object means "no optional
    /// capabilities". Servers **MUST NOT** infer capabilities from earlier
    /// requests, which is the whole point of a stateless core.
    static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    /// `…/logLevel` — deprecated as of 2026-07-28 (SEP-2577). Read, never required.
    static let logLevel = "io.modelcontextprotocol/logLevel"
}

enum MCPModernErrorCode {
    /// `UNSUPPORTED_PROTOCOL_VERSION` from the 2026-07-28 schema. Turns "unknown
    /// version" from silence into a diagnosis carrying the list to retry with.
    static let unsupportedProtocolVersion = -32022
}

enum MCPResultType {
    /// "the request completed successfully and the result contains the final
    /// content" — the only value this server produces. It has nothing to ask the
    /// client for mid-call, so it never emits `input_required` (MRTR).
    static let complete = "complete"
}

/// What one inbound request says about the client that sent it.
///
/// Era is decided **per request**, which is what a stateless protocol means:
/// there is no connection state to consult, and a single stdio session may
/// legitimately carry a legacy handshake and then modern requests (a dual-era
/// client probing) without anything getting confused.
struct MCPRequestEnvelope: Equatable {

    enum Era: Equatable {
        /// Carries `_meta.io.modelcontextprotocol/protocolVersion`, or is a
        /// method that only exists in the modern revision.
        case modern
        /// The `initialize` handshake era — every client that exists today.
        case legacy
    }

    let era: Era
    /// The version the client declared, when it declared one.
    let protocolVersion: String?
    /// Self-reported, unverified, display-only. Never used for any decision.
    let clientName: String?
    let clientVersion: String?

    /// True when this request declared a revision this server does not serve.
    var isUnsupportedVersion: Bool {
        guard era == .modern, let protocolVersion else { return false }
        return !MCPProtocolVersion.isSupported(protocolVersion)
    }

    /// Classify a request. `server/discover` is modern by definition — it is the
    /// probe the spec tells a dual-era client to send *before* anything else,
    /// and a legacy client has no reason to send it.
    static func classify(_ request: MCPRequest) -> MCPRequestEnvelope {
        let meta = request.params?["_meta"]
        let declared = meta?[MCPRequestMetaKey.protocolVersion]?.stringValue
        let info = meta?[MCPRequestMetaKey.clientInfo]

        let era: Era = (declared != nil || request.method == MCPMethod.discover) ? .modern : .legacy

        return MCPRequestEnvelope(
            era: era,
            protocolVersion: declared,
            clientName: info?["name"]?.stringValue,
            clientVersion: info?["version"]?.stringValue)
    }
}

/// Every JSON-RPC method this server answers, in one place, so the server, the
/// docs and the tests cannot drift into three different spellings.
enum MCPMethod {
    // Modern
    static let discover           = "server/discover"
    // Legacy lifecycle
    static let initialize         = "initialize"
    static let initialized        = "notifications/initialized"
    static let cancelled          = "notifications/cancelled"
    static let ping               = "ping"
    static let shutdown           = "shutdown"
    // Server features
    static let toolsList          = "tools/list"
    static let toolsCall          = "tools/call"
    static let resourcesList      = "resources/list"
    static let resourcesTemplates = "resources/templates/list"
    static let resourcesRead      = "resources/read"
    static let promptsList        = "prompts/list"
    static let promptsGet         = "prompts/get"
    static let complete           = "completion/complete"
}

// MARK: - MCP Tool / Resource / Prompt Definitions

/// The behavioural hints from the `ToolAnnotations` schema (2025-06-18+).
///
/// These matter more than they look, because **two of the four schema defaults
/// are the pessimistic value**: an unannotated tool is assumed `destructive` and
/// `openWorld`. Before this, `list_providers` (a local table lookup) and
/// `generate` (an irreversible charge against the user's provider credit) were
/// indistinguishable on the wire.
///
/// `destructiveHint` and `idempotentHint` are only meaningful when
/// `readOnlyHint` is false, so they are emitted only there rather than sent as
/// keys a client is told to ignore.
struct MCPToolAnnotations: Codable, Equatable {
    /// The tool does not modify anything.
    let readOnlyHint: Bool
    /// The tool may perform updates the caller cannot undo.
    ///
    /// **Spend counts.** There is no "costs money" hint in MCP, and a client
    /// uses `destructiveHint` to decide whether to ask the human first. Marking
    /// a tool that charges a provider `destructiveHint: false` would *lower* the
    /// caution it gets today, since unannotated means destructive — so every
    /// tool that spends keeps the pessimistic value on purpose.
    let destructiveHint: Bool
    /// Calling twice with the same arguments has no effect beyond the first.
    let idempotentHint: Bool
    /// The tool touches something outside this machine.
    let openWorldHint: Bool

    init(readOnly: Bool, destructive: Bool = true, idempotent: Bool = false, openWorld: Bool) {
        self.readOnlyHint = readOnly
        self.destructiveHint = destructive
        self.idempotentHint = idempotent
        self.openWorldHint = openWorld
    }

    /// A local read: touches nothing, leaves the machine never.
    static let localRead = MCPToolAnnotations(readOnly: true, openWorld: false)

    func toAnyCodable() -> AnyCodableValue {
        var object: [String: AnyCodableValue] = [
            "readOnlyHint": .bool(readOnlyHint),
            "openWorldHint": .bool(openWorldHint),
        ]
        if !readOnlyHint {
            object["destructiveHint"] = .bool(destructiveHint)
            object["idempotentHint"] = .bool(idempotentHint)
        }
        return .dictionary(object)
    }
}

struct MCPToolDefinition: Codable {
    let name: String
    /// Display label, distinct from the identifier `tools/call` uses.
    let title: String
    let description: String
    let inputSchema: [String: AnyCodableValue]
    let annotations: MCPToolAnnotations
    /// The typed contract on `structuredContent`. This is what makes a result
    /// chainable rather than prose an agent has to re-parse.
    let outputSchema: [String: AnyCodableValue]?

    init(name: String,
         title: String,
         description: String,
         inputSchema: [String: AnyCodableValue],
         annotations: MCPToolAnnotations,
         outputSchema: [String: AnyCodableValue]? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.outputSchema = outputSchema
    }

    func toAnyCodable() -> AnyCodableValue {
        var object: [String: AnyCodableValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .dictionary(inputSchema),
            "annotations": annotations.toAnyCodable(),
        ]
        if let outputSchema { object["outputSchema"] = .dictionary(outputSchema) }
        return .dictionary(object)
    }
}

struct MCPResourceDefinition: Codable {
    let uri: String
    let name: String
    let description: String
    let mimeType: String

    func toAnyCodable() -> AnyCodableValue {
        .dictionary([
            "uri": .string(uri),
            "name": .string(name),
            "description": .string(description),
            "mimeType": .string(mimeType),
        ])
    }
}

/// `resources/templates/list` — how an agent names a record it has an id for,
/// without the server enumerating every record it owns.
struct MCPResourceTemplateDefinition: Codable {
    let uriTemplate: String
    let name: String
    let description: String
    let mimeType: String

    func toAnyCodable() -> AnyCodableValue {
        .dictionary([
            "uriTemplate": .string(uriTemplate),
            "name": .string(name),
            "description": .string(description),
            "mimeType": .string(mimeType),
        ])
    }
}

struct MCPPromptDefinition: Codable {
    struct Argument: Codable, Equatable {
        let name: String
        let description: String
        let required: Bool
        /// Offered through `completion/complete`. Empty for free-text arguments.
        let choices: [String]

        init(name: String, description: String, required: Bool, choices: [String] = []) {
            self.name = name
            self.description = description
            self.required = required
            self.choices = choices
        }
    }

    /// The identifier a client calls `prompts/get` with.
    let name: String
    /// Human-readable label. Recipes keep their own name here.
    let title: String
    let description: String
    let arguments: [Argument]
    /// The recipe this prompt renders, when it is a recipe prompt.
    let recipeId: String?

    func toAnyCodable() -> AnyCodableValue {
        var object: [String: AnyCodableValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
        ]
        if !arguments.isEmpty {
            object["arguments"] = .array(arguments.map { argument in
                .dictionary([
                    "name": .string(argument.name),
                    "description": .string(argument.description),
                    "required": .bool(argument.required),
                ])
            })
        }
        return .dictionary(object)
    }
}

// MARK: - Identifier grammar

/// The id grammar for anything an agent can name through MCP.
///
/// `GenerationStore`/`RecipeStore` resolve an id straight into a filename
/// (`~/.openflix/generations/<id>.json`), so an id is a path component, and an
/// MCP argument is a string chosen by a model reading untrusted text. Real ids
/// are UUIDs, so this rejects nothing legitimate — it just stops `..` and `/`
/// from ever reaching `appendingPathComponent`.
enum MCPIdentifier {
    static let maxLength = 128

    static func isWellFormed(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxLength, id.first != "." else { return false }
        return id.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
        }
    }
}

/// Tool names cross the model boundary, where the schema's `name` is
/// `^[a-zA-Z0-9_-]{1,128}$` — a dot is illegal there even though it is legal in
/// a record id.
enum MCPToolName {
    static func isWellFormed(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
        }
    }
}

// MARK: - MCP Standard Error Codes

enum MCPErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

// MARK: - AnyCodableValue conveniences

extension AnyCodableValue {

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v):    return Double(v)
        default:             return nil
        }
    }

    var arrayValue: [AnyCodableValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: AnyCodableValue]? {
        if case .dictionary(let v) = self { return v }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> AnyCodableValue? {
        objectValue?[key]
    }

    /// Convert a `[String: Any]` tool result into something that is guaranteed
    /// to encode.
    ///
    /// `AnyCodableValue.from` maps anything unrecognised to `.null`, but it will
    /// happily carry a non-finite `Double`, and `JSONEncoder` **throws** on
    /// those. On this server a throw at encode time means no line is written at
    /// all and the agent waits forever, so a NaN is turned into `null` here
    /// rather than into a hang. (The pre-existing text path degraded to `"{}"`
    /// for the same input, which is why this never showed up before.)
    static func sanitized(_ value: Any) -> AnyCodableValue {
        switch value {
        case let v as String:        return .string(v)
        case let v as Bool:          return .bool(v)
        case let v as Int:           return .int(v)
        case let v as Double:        return v.isFinite ? .double(v) : .null
        case let v as Float:         return v.isFinite ? .double(Double(v)) : .null
        case let v as NSNumber:      return sanitizedNumber(v)
        case let v as [String: Any]: return .dictionary(v.mapValues { sanitized($0) })
        case let v as [Any]:         return .array(v.map { sanitized($0) })
        case let v as AnyCodableValue: return v
        default:                     return .null
        }
    }

    private static func sanitizedNumber(_ number: NSNumber) -> AnyCodableValue {
        let double = number.doubleValue
        guard double.isFinite else { return .null }
        if double == double.rounded(), abs(double) < 9.0e15 { return .int(number.intValue) }
        return .double(double)
    }
}
