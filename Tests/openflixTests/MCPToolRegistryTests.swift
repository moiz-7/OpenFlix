import XCTest
@testable import openflix

/// Invariants of the MCP **tool registry** — the schemas an agent reads before
/// it is allowed to spend money.
///
/// Scoped deliberately narrow. The dual-era protocol work (versions,
/// annotations, `outputSchema`, prompts, completions) is owned elsewhere and in
/// flight, so nothing here asserts on protocol revisions or on the *number* of
/// tools; adding tools must never fail these. What is asserted is the part that
/// has to hold in every era: names an MCP client will accept, schemas that are
/// valid JSON Schema, and the money tools still requiring their arguments.
///
/// The sharp one is `required ⊆ properties`. A `required` entry with no
/// matching property is legal-looking Swift and invalid JSON Schema: strict
/// clients reject the whole `tools/list` payload, so a one-word typo in a
/// property key takes down *every* tool, not just its own.
final class MCPToolRegistryTests: XCTestCase {

    private var tools: [MCPToolDefinition] { MCPToolRegistry.allTools }

    /// Local rather than an extension on `AnyCodableValue`: that type lives in
    /// a file another agent is actively reworking, and a test file must not
    /// widen its API.
    private func array(_ value: AnyCodableValue?) -> [AnyCodableValue]? {
        guard case .array(let items)? = value else { return nil }
        return items
    }

    private func object(_ value: AnyCodableValue?) -> [String: AnyCodableValue]? {
        value?.objectValue
    }

    // MARK: - Names

    func testToolNamesAreUnique() {
        let names = tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "duplicate tool name — a client keyed by name would silently shadow one")
    }

    func testToolNamesMatchTheConventionalMCPGrammar() {
        // Lowercase, digits and underscore. Clients surface these to models as
        // callable identifiers; spaces, slashes and dots are what break them.
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "_"))
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty)
            XCTAssertTrue(tool.name.unicodeScalars.allSatisfy { allowed.contains($0) },
                          "tool name '\(tool.name)' is not [a-z0-9_]")
            XCTAssertTrue(tool.name.first.map { $0.isLetter } ?? false,
                          "tool name '\(tool.name)' must start with a letter")
        }
    }

    func testEveryToolHasANonEmptyDescription() {
        // The description is the only thing a model reads before choosing to
        // call something that bills a provider.
        for tool in tools {
            XCTAssertFalse(tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "tool '\(tool.name)' has no description")
        }
    }

    // MARK: - Schema validity

    func testEveryInputSchemaIsAnObjectSchemaWithAPropertiesMap() {
        for tool in tools {
            XCTAssertEqual(tool.inputSchema["type"]?.stringValue, "object",
                           "tool '\(tool.name)' inputSchema is not an object schema")
            XCTAssertNotNil(object(tool.inputSchema["properties"]),
                            "tool '\(tool.name)' has no properties map")
        }
    }

    func testEveryRequiredArgumentIsDeclaredInProperties() {
        for tool in tools {
            guard let required = array(tool.inputSchema["required"]) else { continue }
            let properties = object(tool.inputSchema["properties"]) ?? [:]
            for entry in required {
                let key = entry.stringValue ?? "<non-string>"
                XCTAssertNotNil(properties[key],
                                "tool '\(tool.name)' requires '\(key)' but never declares it — "
                                + "invalid JSON Schema; strict clients reject the whole tools/list")
            }
        }
    }

    func testRequiredIsOmittedRatherThanEmpty() {
        // `"required": []` is legal but noisy, and some validators treat an
        // empty required array as a schema error. The builder omits it.
        for tool in tools {
            if let required = array(tool.inputSchema["required"]) {
                XCTAssertFalse(required.isEmpty, "tool '\(tool.name)' emits an empty required array")
            }
        }
    }

    func testEveryPropertyDeclaresATypeAndADescription() {
        let jsonSchemaTypes: Set<String> = ["string", "integer", "number", "boolean", "array", "object"]
        for tool in tools {
            let properties = object(tool.inputSchema["properties"]) ?? [:]
            for (key, value) in properties {
                let prop = object(value) ?? [:]
                let type = prop["type"]?.stringValue
                XCTAssertNotNil(type, "\(tool.name).\(key) has no type")
                if let type {
                    XCTAssertTrue(jsonSchemaTypes.contains(type),
                                  "\(tool.name).\(key) has non-JSON-Schema type '\(type)'")
                }
                let description = prop["description"]?.stringValue ?? ""
                XCTAssertFalse(description.isEmpty, "\(tool.name).\(key) has no description")
            }
        }
    }

    func testEveryToolSchemaSurvivesJSONEncoding() {
        // `tools/list` is serialised to the client; a value that cannot encode
        // takes the entire response with it.
        for tool in tools {
            XCTAssertNoThrow(try JSONEncoder().encode(tool), "tool '\(tool.name)' is not encodable")
        }
    }

    // MARK: - The money tools

    func testTheToolsThatSpendMoneyAreStillPresent() {
        // The CLI's MCP server is the one that bills — the app's server refuses
        // generation by name and points agents here. These three are the whole
        // reason this surface exists.
        for name in ["generate", "generate_submit", "project_run"] {
            XCTAssertTrue(tools.contains { $0.name == name }, "money tool '\(name)' disappeared")
        }
    }

    func testGenerationToolsRequireAPrompt() {
        for name in ["generate", "generate_submit"] {
            guard let tool = tools.first(where: { $0.name == name }) else {
                return XCTFail("missing tool \(name)")
            }
            let required = (array(tool.inputSchema["required"]) ?? []).compactMap(\.stringValue)
            XCTAssertTrue(required.contains("prompt"),
                          "\(name) must not be callable without a prompt")
        }
    }

    func testProjectRunRequiresAProjectId() throws {
        let tool = try XCTUnwrap(tools.first { $0.name == "project_run" })
        let required = (array(tool.inputSchema["required"]) ?? []).compactMap(\.stringValue)
        XCTAssertTrue(required.contains("project_id"))
    }

    func testDurationIsANumberNotAnIntegerOnTheGenerationTools() {
        // The engine takes `Double?` and guards `isFinite` before any
        // conversion. Declaring the schema as `integer` would push clients into
        // sending pre-rounded values and hide the range the CLI actually
        // validates.
        for name in ["generate", "generate_submit"] {
            guard let tool = tools.first(where: { $0.name == name }) else { continue }
            let properties = object(tool.inputSchema["properties"]) ?? [:]
            XCTAssertEqual(object(properties["duration_seconds"])?["type"]?.stringValue,
                           "number", "\(name).duration_seconds should be a JSON number")
        }
    }

    func testToolArgumentKeysAreSnakeCaseUnlikeTheOnDiskRecords() {
        // The MCP surface is snake_case on purpose (it mirrors the CLI's JSON
        // output shape), while the on-disk records the app reads are camelCase.
        // Both are contracts; this pins the MCP half so a well-meaning
        // "consistency" pass has to break a test to change it.
        for tool in tools {
            for key in (object(tool.inputSchema["properties"]) ?? [:]).keys {
                XCTAssertFalse(key.contains { $0.isUppercase },
                               "\(tool.name).\(key) is not snake_case")
            }
        }
    }

    // MARK: - Resources

    func testResourceURIsAreUniqueAndUseTheOpenFlixScheme() {
        let uris = MCPToolRegistry.allResources.map(\.uri)
        XCTAssertEqual(Set(uris).count, uris.count, "duplicate resource URI")
        for uri in uris {
            XCTAssertTrue(uri.hasPrefix("openflix://"),
                          "resource '\(uri)' does not use the openflix:// scheme")
        }
    }

    func testEveryResourceIsDescribedAndTyped() {
        for resource in MCPToolRegistry.allResources {
            XCTAssertFalse(resource.name.isEmpty, "resource \(resource.uri) has no name")
            XCTAssertFalse(resource.description.isEmpty,
                           "resource \(resource.uri) has no description")
            XCTAssertEqual(resource.mimeType, "application/json")
        }
    }
}
