import Foundation

// MARK: - Recipe args (formatVersion 3)
//
// v3 recipes may declare typed arguments; `{{name}}` placeholders in
// promptText / negativePromptText / parameter values are substituted at run
// time from `--arg name=value` flags (or workflow stage `args`), falling back
// to declared defaults. v2 bundles (no args) decode and behave exactly as
// before.

/// A declared value that may be a JSON string or number (`default` in arg
/// specs, values in `uses.args`).
public enum RecipeArgValue: Codable, Equatable {
    case string(String)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a string or a number")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }

    /// Rendered form used for `{{name}}` substitution. Whole numbers drop the
    /// trailing ".0" so `duration: 8` renders as "8", not "8.0".
    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
            return String(n)
        }
    }
}

/// One declared recipe argument (formatVersion 3).
public struct RecipeArg: Codable, Equatable {
    public var name: String
    public var type: String              // "string" | "number" | "enum"
    public var defaultValue: RecipeArgValue?
    public var choices: [String]?        // enum only
    public var description: String?

    public init(name: String, type: String,
                defaultValue: RecipeArgValue? = nil,
                choices: [String]? = nil, description: String? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.choices = choices
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name, type, choices, description
        case defaultValue = "default"
    }
}

/// A composition reference: this recipe uses another recipe with fixed args.
/// Declared metadata in v1 — operationally, composition runs through workflow
/// stages (`"recipe": "<recipe-id>"`), not recursive recipe execution.
public struct RecipeUse: Codable, Equatable {
    public var recipeId: String
    public var args: [String: RecipeArgValue]?

    public init(recipeId: String, args: [String: RecipeArgValue]? = nil) {
        self.recipeId = recipeId
        self.args = args
    }
}

// MARK: - Errors

public enum RecipeArgError: Error, LocalizedError {
    case missingArg(String)
    case unknownArg(String)
    case invalidNumber(name: String, value: String)
    case invalidChoice(name: String, value: String, choices: [String])
    case invalidSpec(String)

    public var errorDescription: String? {
        switch self {
        case .missingArg(let name):
            return "Missing required arg '\(name)' (no default declared). Pass --arg \(name)=<value>."
        case .unknownArg(let name):
            return "Unknown arg '\(name)' — the recipe does not declare it."
        case .invalidNumber(let name, let value):
            return "Arg '\(name)' expects a number, got '\(value)'."
        case .invalidChoice(let name, let value, let choices):
            return "Arg '\(name)' must be one of [\(choices.joined(separator: ", "))], got '\(value)'."
        case .invalidSpec(let m):
            return "Invalid arg spec: \(m)"
        }
    }

    public var code: String {
        switch self {
        case .missingArg:    return "missing_arg"
        case .unknownArg:    return "unknown_arg"
        case .invalidNumber: return "invalid_number"
        case .invalidChoice: return "invalid_choice"
        case .invalidSpec:   return "invalid_arg_spec"
        }
    }
}

// MARK: - Resolver (pure)

public enum RecipeArgResolver {

    public static let validTypes: Set<String> = ["string", "number", "enum"]

    /// Structural validation of a declared arg list.
    public static func validate(_ args: [RecipeArg]) throws {
        var seen = Set<String>()
        for arg in args {
            guard !arg.name.isEmpty else {
                throw RecipeArgError.invalidSpec("arg name cannot be empty")
            }
            guard seen.insert(arg.name).inserted else {
                throw RecipeArgError.invalidSpec("duplicate arg '\(arg.name)'")
            }
            guard validTypes.contains(arg.type) else {
                throw RecipeArgError.invalidSpec(
                    "arg '\(arg.name)' has unknown type '\(arg.type)' (expected string, number, or enum)")
            }
            if arg.type == "enum" {
                guard let choices = arg.choices, !choices.isEmpty else {
                    throw RecipeArgError.invalidSpec("enum arg '\(arg.name)' requires non-empty choices")
                }
            } else if arg.choices != nil {
                throw RecipeArgError.invalidSpec("arg '\(arg.name)': choices are only allowed for enum args")
            }
            if let def = arg.defaultValue {
                try checkValue(def.stringValue, for: arg)
            }
        }
    }

    /// Resolve final substitution values: provided values (from repeated
    /// `--arg name=value` flags or workflow stage `args`) win, declared
    /// defaults fill the gaps, and a missing arg with no default is a
    /// structured `missing_arg` error. Unknown provided names are rejected.
    public static func resolve(args: [RecipeArg], provided: [String: String]) throws -> [String: String] {
        try validate(args)
        let declared = Set(args.map(\.name))
        for name in provided.keys.sorted() where !declared.contains(name) {
            throw RecipeArgError.unknownArg(name)
        }
        var values: [String: String] = [:]
        for arg in args {
            if let v = provided[arg.name] {
                try checkValue(v, for: arg)
                values[arg.name] = v
            } else if let def = arg.defaultValue {
                values[arg.name] = def.stringValue
            } else {
                throw RecipeArgError.missingArg(arg.name)
            }
        }
        return values
    }

    /// Parse repeated `--arg name=value` flags. The value may contain `=`.
    public static func parseArgFlags(_ flags: [String]) throws -> [String: String] {
        var provided: [String: String] = [:]
        for flag in flags {
            let parts = flag.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw RecipeArgError.invalidSpec("--arg expects name=value, got '\(flag)'")
            }
            provided[parts[0]] = parts[1]
        }
        return provided
    }

    /// Replace exact `{{name}}` placeholders in a SINGLE left-to-right pass.
    /// Placeholders without a matching value are left untouched (v2 recipes with
    /// literal braces are unaffected).
    ///
    /// Single-pass matters: the old per-key loop rescanned already-substituted
    /// text, so an arg *value* containing `{{other}}` was expanded or not
    /// depending on unspecified dictionary order — non-reproducible output and a
    /// value-injection vector. Here each source placeholder is resolved exactly
    /// once and substituted values are never re-examined.
    public static func substitute(_ text: String, values: [String: String]) -> String {
        guard !values.isEmpty, text.contains("{{") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([^{}]+)\\}\\}") else { return text }
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 2 else { return }
            let full = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: full.location - lastEnd))
            let name = ns.substring(with: match.range(at: 1))
            result += values[name] ?? ns.substring(with: full)
            lastEnd = full.location + full.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }

    private static func checkValue(_ value: String, for arg: RecipeArg) throws {
        switch arg.type {
        case "number":
            // Double("nan"/"inf"/"1e999") all parse successfully — reject them so
            // a non-finite value can't be substituted into numeric contexts.
            guard let d = Double(value), d.isFinite else {
                throw RecipeArgError.invalidNumber(name: arg.name, value: value)
            }
        case "enum":
            let choices = arg.choices ?? []
            guard choices.contains(value) else {
                throw RecipeArgError.invalidChoice(name: arg.name, value: value, choices: choices)
            }
        default:
            break
        }
    }
}

// MARK: - Recipe substitution

extension Recipe {

    /// Return a copy with `{{name}}` placeholders resolved in promptText,
    /// negativePromptText, and string parameter values.
    public func substituting(_ values: [String: String]) -> Recipe {
        guard !values.isEmpty else { return self }
        var recipe = self
        recipe.promptText = RecipeArgResolver.substitute(promptText, values: values)
        recipe.negativePromptText = RecipeArgResolver.substitute(negativePromptText, values: values)
        if let json = parametersJSON, let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if let s = value as? String {
                    out[key] = RecipeArgResolver.substitute(s, values: values)
                } else {
                    out[key] = value
                }
            }
            if let outData = try? JSONSerialization.data(withJSONObject: out) {
                recipe.parametersJSON = String(data: outData, encoding: .utf8)
            }
        }
        return recipe
    }

    /// parametersJSON as a string map (non-string values rendered with "\()").
    public func parameterStrings() -> [String: String] {
        guard let json = parametersJSON, let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { "\($0)" }
    }
}
