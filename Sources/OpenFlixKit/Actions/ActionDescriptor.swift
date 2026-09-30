import Foundation

// MARK: - The action vocabulary
//
// One description per thing OpenFlix can do, shared by every surface that
// offers it: the MCP server, `openflix action`, and any bridge an agent talks
// to. Each surface derives what it tells a client — MCP annotations, a
// manifest — from this one record, so what a tool *claims* about itself cannot
// drift from what the policy that guards it *assumes*.

/// What running an action does to the world. Drives both the MCP annotations
/// a client reads and the approval an agent host asks a person for.
///
/// MCP's four hints cannot say "costs money", so spending is its own effect
/// here rather than a meaning smuggled into `destructiveHint`.
public enum ActionEffect: String, Codable, CaseIterable, Sendable {
    /// Reads state and changes nothing.
    case read
    /// Brings local state up to date with work already paid for (polling a
    /// running job). No new spend, nothing the user would call a change.
    case refresh
    /// Drives something reversible, like a player.
    case control
    /// Writes local state that can be written again (a score, a saved item).
    case localWrite = "local_write"
    /// Removes or cancels something that cannot be brought back.
    case destructive
    /// Spends the user's money. Irreversible by definition.
    case spend
    /// Publishes something beyond this machine (a community vote).
    case share

    /// Whether this effect by itself makes the action a mutation.
    public var isReadOnly: Bool { self == .read }

    /// MCP's `destructiveHint`: the caller cannot undo it. Spend is
    /// destructive — a client uses this hint to decide whether to ask the
    /// human first, and money spent is not coming back.
    public var isDestructive: Bool { self == .destructive || self == .spend }

    /// Effects that by definition leave the machine.
    public var requiresOpenWorld: Bool { self == .spend || self == .share }
}

/// MCP's four tool hints, derived — never declared — from an action's effect.
public struct ActionAnnotations: Equatable, Sendable {
    public let readOnlyHint: Bool
    /// Meaningful only when `readOnlyHint` is false; nil for reads.
    public let destructiveHint: Bool?
    /// Meaningful only when `readOnlyHint` is false; nil for reads.
    public let idempotentHint: Bool?
    public let openWorldHint: Bool
}

/// One thing OpenFlix can do, described for every surface that offers it.
public struct ActionDescriptor: Equatable, Sendable {
    /// Stable identifier. It is also the MCP tool name, so it keeps to the
    /// `[a-zA-Z0-9_-]` grammar a model boundary accepts.
    public let name: String
    /// Display label.
    public let title: String
    /// Written for a model: what it does, what it costs, when not to call it.
    public let description: String
    public let effect: ActionEffect
    /// Touches something outside this machine (a provider, a registry).
    public let openWorld: Bool
    /// Calling twice with the same arguments has no effect beyond the first.
    public let idempotent: Bool
    /// JSON Schema for the arguments. Always an object with
    /// `additionalProperties: false`: a misspelled argument on a paid call must
    /// be refused, not silently ignored while the default is billed.
    public let inputSchema: JSONValue
    /// JSON Schema for a successful result, when the action has a fixed shape.
    public let outputSchema: JSONValue?
    /// The result carries text that came from somewhere else (a prompt, a
    /// provider's message). An agent host should fence it as untrusted.
    public let returnsUntrustedText: Bool

    public init(name: String, title: String, description: String,
                effect: ActionEffect, openWorld: Bool, idempotent: Bool = false,
                inputSchema: JSONValue, outputSchema: JSONValue? = nil,
                returnsUntrustedText: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.effect = effect
        self.openWorld = openWorld
        self.idempotent = idempotent
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.returnsUntrustedText = returnsUntrustedText
    }

    public var annotations: ActionAnnotations {
        if effect.isReadOnly {
            return ActionAnnotations(readOnlyHint: true, destructiveHint: nil,
                                     idempotentHint: nil, openWorldHint: openWorld)
        }
        return ActionAnnotations(readOnlyHint: false, destructiveHint: effect.isDestructive,
                                 idempotentHint: idempotent, openWorldHint: openWorld)
    }

    /// Everything wrong with this description, empty when it is sound. A
    /// catalog test runs this over every action, so a malformed entry fails
    /// the build rather than confusing an agent.
    public var problems: [String] {
        var found: [String] = []
        if !ActionDescriptor.isWellFormedName(name) {
            found.append("\(name): name must be 1-64 of [a-zA-Z0-9_-]")
        }
        if effect.requiresOpenWorld && !openWorld {
            found.append("\(name): a \(effect.rawValue) action leaves the machine, so it must be openWorld")
        }
        if description.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("\(name): description is empty")
        }
        found.append(contentsOf: JSONSchema.problems(inObjectSchema: inputSchema).map { "\(name): \($0)" })
        return found
    }

    public static func isWellFormedName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The machine-readable manifest entry: what `openflix action list` prints
    /// and what an agent host registers a tool from.
    public var manifestEntry: JSONValue {
        let hints = annotations
        var annotationObject: [String: JSONValue] = [
            "readOnlyHint": .bool(hints.readOnlyHint),
            "openWorldHint": .bool(hints.openWorldHint),
        ]
        if let d = hints.destructiveHint { annotationObject["destructiveHint"] = .bool(d) }
        if let i = hints.idempotentHint { annotationObject["idempotentHint"] = .bool(i) }

        var entry: [String: JSONValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "effect": .string(effect.rawValue),
            "annotations": .object(annotationObject),
            "input_schema": inputSchema,
            "returns_untrusted_text": .bool(returnsUntrustedText),
        ]
        if let outputSchema { entry["output_schema"] = outputSchema }
        return .object(entry)
    }
}

/// The manifest contract: every action a host offers, in one document.
public enum ActionManifest {
    public static let contract = "openflix.action_manifest.v1"

    public static func document(host: String, version: String,
                                actions: [ActionDescriptor]) -> JSONValue {
        .object([
            "contract": .string(contract),
            "host": .string(host),
            "version": .string(version),
            "actions": .array(actions.map(\.manifestEntry)),
        ])
    }
}

// MARK: - Schema builders

/// Builders for the JSON Schema subset actions use, so every catalog entry is
/// written the same way and carries the same guarantees.
public enum JSONSchema {

    /// An object schema that refuses unknown properties.
    public static func object(required: [String] = [],
                              properties: [String: JSONValue]) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    /// An object schema describing a result. Results are open: a new field in
    /// a later version must not make an old client's validator reject it.
    public static func result(required: [String] = [],
                              properties: [String: JSONValue]) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    public static func string(_ description: String, maxLength: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let maxLength { schema["maxLength"] = .int(maxLength) }
        return .object(schema)
    }

    public static func enumeration(_ description: String, _ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description),
                 "enum": .array(values.map { .string($0) })])
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("number"), "description": .string(description)]
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }

    public static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    public static func array(_ description: String, items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }

    public static func freeformObject(_ description: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(description)])
    }

    /// Structural problems with an input schema: it must be a closed object
    /// whose required names are all declared and whose properties all say what
    /// they are for (a model reads those descriptions to fill them in).
    static func problems(inObjectSchema schema: JSONValue) -> [String] {
        var found: [String] = []
        guard schema["type"]?.stringValue == "object" else { return ["input schema must be an object"] }
        if schema["additionalProperties"]?.boolValue != false {
            found.append("input schema must set additionalProperties: false")
        }
        let properties = schema["properties"]?.objectValue ?? [:]
        for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        where properties[name] == nil {
            found.append("required property '\(name)' is not declared")
        }
        for (name, property) in properties where (property["description"]?.stringValue ?? "").isEmpty {
            found.append("property '\(name)' has no description")
        }
        return found
    }
}
