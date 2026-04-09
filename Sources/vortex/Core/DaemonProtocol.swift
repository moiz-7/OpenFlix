import Foundation

// MARK: - JSON-RPC-like protocol over Unix domain socket

struct DaemonRequest: Codable {
    var id: String
    var method: String
    var params: [String: AnyCodableValue]?
}

struct DaemonResponse: Codable {
    var id: String
    var result: AnyCodableValue?
    var error: DaemonError?

    static func success(id: String, result: AnyCodableValue) -> DaemonResponse {
        DaemonResponse(id: id, result: result, error: nil)
    }

    static func failure(id: String, code: String, message: String) -> DaemonResponse {
        DaemonResponse(id: id, result: nil, error: DaemonError(code: code, message: message))
    }
}

struct DaemonError: Codable {
    var code: String
    var message: String
}

struct DaemonEvent: Codable {
    var type: String
    var projectId: String?
    var shotId: String?
    var data: [String: AnyCodableValue]

    enum CodingKeys: String, CodingKey {
        case type
        case projectId = "project_id"
        case shotId = "shot_id"
        case data
    }
}

// MARK: - AnyCodableValue

/// A type-erased Codable wrapper for heterogeneous JSON values.
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(v)
        } else if let v = try? container.decode([AnyCodableValue].self) {
            self = .array(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v):     try container.encode(v)
        case .int(let v):        try container.encode(v)
        case .double(let v):     try container.encode(v)
        case .bool(let v):       try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .array(let v):      try container.encode(v)
        case .null:              try container.encodeNil()
        }
    }

    /// Convert to plain Any value (for bridging to [String: Any] dictionaries).
    func toAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v):    return v
        case .double(let v): return v
        case .bool(let v):   return v
        case .dictionary(let v): return v.mapValues { $0.toAny() }
        case .array(let v):  return v.map { $0.toAny() }
        case .null:          return NSNull()
        }
    }

    /// Create from Any value (for bridging from [String: Any] dictionaries).
    static func from(_ value: Any) -> AnyCodableValue {
        switch value {
        case let v as String:                return .string(v)
        case let v as Int:                   return .int(v)
        case let v as Double:                return .double(v)
        case let v as Bool:                  return .bool(v)
        case let v as [String: Any]:         return .dictionary(v.mapValues { from($0) })
        case let v as [Any]:                 return .array(v.map { from($0) })
        default:                             return .null
        }
    }
}

// Wire format: each message is a single JSON line terminated by \n
// Events are pushed to all subscribed connections without a request ID.

enum DaemonMethods {
    static let health = "health"
    static let batchSubmit = "batch.submit"
    static let projectCreate = "project.create"
    static let projectRun = "project.run"
    static let projectPause = "project.pause"
    static let projectResume = "project.resume"
    static let projectCancel = "project.cancel"
    static let projectStatus = "project.status"
    static let projectList = "project.list"
    static let projectShotRetry = "project.shot.retry"
    static let projectShotSkip = "project.shot.skip"
    static let subscribe = "subscribe"
    static let unsubscribe = "unsubscribe"
    static let evaluate = "evaluate"
    static let feedback = "feedback"
    static let providerMetrics = "provider.metrics"
}
