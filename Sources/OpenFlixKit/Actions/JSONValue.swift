import Foundation

// MARK: - JSON values for the action vocabulary
//
// Actions are described and validated as JSON because every surface that
// calls them — an MCP client, an HTTP agent, `openflix action run --input` —
// speaks JSON. This is the kit's own value type so the vocabulary does not
// depend on any one host's wire types.

/// A JSON value.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
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
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        // JSONEncoder throws on a non-finite Double; `null` is the only JSON for it.
        case .double(let v): if v.isFinite { try container.encode(v) } else { try container.encodeNil() }
        case .bool(let v):   try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .null:          try container.encodeNil()
        }
    }

    // MARK: Accessors

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// Integers read as numbers too: `{"threshold": 80}` is a number.
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v):    return Double(v)
        default:             return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    // MARK: Foundation bridging

    /// A `JSONSerialization`-style value (`[String: Any]`, `[Any]`, `NSNumber`…)
    /// as JSON. Anything that is not JSON, and any non-finite number, becomes
    /// `null` rather than a value an encoder would throw on.
    public init(any value: Any) {
        switch value {
        case let v as JSONValue:     self = v
        case let v as String:        self = .string(v)
        // Every number — Swift `Int`/`Double`/`Bool` included — bridges to
        // `NSNumber`, and a `JSONSerialization` 1 also answers `as? Bool`. The
        // Core Foundation type is the one reliable way to tell a boolean from
        // a number, so it is asked once, here, before anything else is.
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if let int = value as? Int, !(value is Double), !(value is Float) {
                self = .int(int)
            } else {
                let d = v.doubleValue
                if !d.isFinite {
                    self = .null
                } else if CFNumberIsFloatType(v) {
                    self = .double(d)
                } else {
                    self = .int(v.intValue)
                }
            }
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as [Any]:         self = .array(v.map { JSONValue(any: $0) })
        default:                     self = .null
        }
    }

    /// The inverse of `init(any:)`, for code that builds results with
    /// `JSONSerialization`-style dictionaries.
    public var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v):    return v
        case .double(let v): return v
        case .bool(let v):   return v
        case .object(let v): return v.mapValues { $0.anyValue }
        case .array(let v):  return v.map { $0.anyValue }
        case .null:          return NSNull()
        }
    }

    /// Compact, key-sorted JSON text.
    public func jsonString(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
