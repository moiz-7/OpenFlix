import Foundation

// MARK: - Argument validation
//
// Every surface validates an action's arguments here, against the action's own
// input schema, before the action runs. That is the point of having one door:
// a CLI flag, an MCP call and an HTTP request cannot disagree about what a
// valid `duration_seconds` is, because none of them decides.

/// An argument an action refused before running. Nothing has happened when
/// this is thrown.
public struct ActionInputError: Error, Equatable, Sendable {
    /// The argument at fault, when there is one.
    public let argument: String?
    public let message: String

    public init(argument: String?, message: String) {
        self.argument = argument
        self.message = message
    }
}

public enum ActionValidator {

    /// Checks `arguments` against `schema` (the subset `JSONSchema` builds:
    /// a closed object of scalar, enum, array and object properties with
    /// `required`, `enum`, `maxLength`, `minimum` and `maximum`).
    ///
    /// `null` for an optional argument reads as absent: clients commonly send
    /// it for "not set", and refusing it would help no one.
    public static func validate(_ arguments: JSONValue, against schema: JSONValue) throws {
        let given: [String: JSONValue]
        switch arguments {
        case .object(let object): given = object
        case .null: given = [:]
        default:
            throw ActionInputError(argument: nil, message: "arguments must be a JSON object")
        }

        let properties = schema["properties"]?.objectValue ?? [:]

        if schema["additionalProperties"]?.boolValue == false {
            // Sorted, so the same bad call always gets the same answer.
            for name in given.keys.sorted() where properties[name] == nil {
                let accepted = properties.keys.sorted().joined(separator: ", ")
                throw ActionInputError(
                    argument: name,
                    message: "unknown argument '\(name)'. Accepted: \(accepted.isEmpty ? "none" : accepted)")
            }
        }

        for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            if given[name] == nil || given[name] == .null {
                // The property's own description is the best hint at what to
                // pass — a model reading this can correct the call in one step.
                let hint = properties[name]?["description"]?.stringValue.map { ": \($0)" } ?? ""
                throw ActionInputError(argument: name, message: "missing required argument '\(name)'\(hint)")
            }
        }

        for name in given.keys.sorted() {
            guard let value = given[name], value != .null, let property = properties[name] else { continue }
            try check(value, against: property, argument: name)
        }
    }

    private static func check(_ value: JSONValue, against property: JSONValue, argument: String) throws {
        func refuse(_ message: String) -> ActionInputError {
            ActionInputError(argument: argument, message: "'\(argument)' \(message)")
        }

        switch property["type"]?.stringValue {
        case "string":
            guard let string = value.stringValue else { throw refuse("must be a string") }
            if let maxLength = property["maxLength"]?.intValue, string.count > maxLength {
                throw refuse("must be at most \(maxLength) characters (got \(string.count))")
            }
            if let allowed = property["enum"]?.arrayValue?.compactMap(\.stringValue),
               !allowed.contains(string) {
                throw refuse("must be one of: \(allowed.joined(separator: ", ")) (got \"\(string)\")")
            }
        case "integer":
            guard let int = value.intValue else { throw refuse("must be a whole number") }
            try checkBounds(Double(int), property, refuse)
        case "number":
            guard let number = value.doubleValue, number.isFinite else { throw refuse("must be a number") }
            try checkBounds(number, property, refuse)
        case "boolean":
            guard value.boolValue != nil else { throw refuse("must be true or false") }
        case "object":
            guard value.objectValue != nil else { throw refuse("must be a JSON object") }
        case "array":
            guard let items = value.arrayValue else { throw refuse("must be an array") }
            if let itemType = property["items"]?["type"]?.stringValue {
                for item in items where !matches(item, type: itemType) {
                    throw refuse("must contain only \(itemType) values")
                }
            }
        default:
            break
        }
    }

    private static func checkBounds(_ number: Double, _ property: JSONValue,
                                    _ refuse: (String) -> ActionInputError) throws {
        if let minimum = property["minimum"]?.doubleValue, number < minimum {
            throw refuse("must be at least \(format(minimum)) (got \(format(number)))")
        }
        if let maximum = property["maximum"]?.doubleValue, number > maximum {
            throw refuse("must be at most \(format(maximum)) (got \(format(number)))")
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch type {
        case "string":  return value.stringValue != nil
        case "integer": return value.intValue != nil
        case "number":  return value.doubleValue != nil
        case "boolean": return value.boolValue != nil
        case "object":  return value.objectValue != nil
        case "array":   return value.arrayValue != nil
        default:        return true
        }
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}
