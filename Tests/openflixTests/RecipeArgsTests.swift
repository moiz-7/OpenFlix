import XCTest
@testable import openflix

final class RecipeArgsTests: XCTestCase {

    private func arg(_ name: String, type: String = "string",
                     default def: RecipeArgValue? = nil,
                     choices: [String]? = nil) -> RecipeArg {
        RecipeArg(name: name, type: type, defaultValue: def, choices: choices, description: nil)
    }

    // MARK: - Substitution (pure)

    func testSubstituteReplacesPlaceholders() {
        let out = RecipeArgResolver.substitute(
            "a {{subject}} at {{time}}, {{subject}} again",
            values: ["subject": "fox", "time": "dawn"])
        XCTAssertEqual(out, "a fox at dawn, fox again")
    }

    func testSubstituteLeavesUnknownPlaceholdersUntouched() {
        let out = RecipeArgResolver.substitute("keep {{unknown}} intact", values: ["subject": "fox"])
        XCTAssertEqual(out, "keep {{unknown}} intact")
    }

    func testSubstituteNoValuesIsIdentity() {
        XCTAssertEqual(RecipeArgResolver.substitute("{{a}}", values: [:]), "{{a}}")
    }

    // MARK: - Resolution

    func testResolveUsesProvidedValueOverDefault() throws {
        let values = try RecipeArgResolver.resolve(
            args: [arg("subject", default: .string("cat"))],
            provided: ["subject": "dog"])
        XCTAssertEqual(values["subject"], "dog")
    }

    func testResolveFallsBackToDefault() throws {
        let values = try RecipeArgResolver.resolve(
            args: [arg("subject", default: .string("cat")),
                   arg("duration", type: "number", default: .number(8))],
            provided: [:])
        XCTAssertEqual(values["subject"], "cat")
        XCTAssertEqual(values["duration"], "8")  // whole number renders without ".0"
    }

    func testResolveMissingRequiredArgThrowsMissingArg() {
        XCTAssertThrowsError(try RecipeArgResolver.resolve(args: [arg("subject")], provided: [:])) {
            guard case RecipeArgError.missingArg(let name)? = $0 as? RecipeArgError else {
                return XCTFail("expected missingArg, got \($0)")
            }
            XCTAssertEqual(name, "subject")
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "missing_arg")
        }
    }

    func testResolveUnknownProvidedArgThrows() {
        XCTAssertThrowsError(try RecipeArgResolver.resolve(args: [], provided: ["nope": "x"])) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "unknown_arg")
        }
    }

    func testResolveNumberValidation() {
        XCTAssertThrowsError(try RecipeArgResolver.resolve(
            args: [arg("n", type: "number")], provided: ["n": "not-a-number"])) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "invalid_number")
        }
        XCTAssertNoThrow(try RecipeArgResolver.resolve(
            args: [arg("n", type: "number")], provided: ["n": "4.5"]))
    }

    func testResolveEnumValidation() {
        let style = arg("style", type: "enum", choices: ["anime", "noir"])
        XCTAssertThrowsError(try RecipeArgResolver.resolve(args: [style], provided: ["style": "western"])) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "invalid_choice")
        }
        XCTAssertNoThrow(try RecipeArgResolver.resolve(args: [style], provided: ["style": "noir"]))
    }

    // MARK: - Spec validation

    func testValidateRejectsDuplicateNamesAndBadTypes() {
        XCTAssertThrowsError(try RecipeArgResolver.validate([arg("a"), arg("a")])) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "invalid_arg_spec")
        }
        XCTAssertThrowsError(try RecipeArgResolver.validate([arg("a", type: "boolean")]))
        XCTAssertThrowsError(try RecipeArgResolver.validate([arg("", type: "string")]))
    }

    func testValidateEnumRequiresChoicesAndChoicesOnlyForEnum() {
        XCTAssertThrowsError(try RecipeArgResolver.validate([arg("e", type: "enum")]))
        XCTAssertThrowsError(try RecipeArgResolver.validate([arg("s", choices: ["x"])]))
        XCTAssertThrowsError(try RecipeArgResolver.validate(
            [arg("e", type: "enum", default: .string("z"), choices: ["x", "y"])])) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "invalid_choice")
        }
    }

    // MARK: - Flag parsing

    func testParseArgFlags() throws {
        let provided = try RecipeArgResolver.parseArgFlags(["a=1", "b=x=y"])
        XCTAssertEqual(provided, ["a": "1", "b": "x=y"])
        XCTAssertThrowsError(try RecipeArgResolver.parseArgFlags(["novalue"])) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "invalid_arg_spec")
        }
    }

    // MARK: - CLIRecipe substitution

    func testRecipeSubstitutingRewritesPromptNegativeAndParams() throws {
        var recipe = CLIRecipe(name: "t", promptText: "a {{subject}} running",
                               negativePromptText: "no {{avoid}}")
        recipe.parametersJSON = #"{"camera": "{{subject}} cam", "seed": 42}"#
        let out = recipe.substituting(["subject": "fox", "avoid": "blur"])
        XCTAssertEqual(out.promptText, "a fox running")
        XCTAssertEqual(out.negativePromptText, "no blur")
        let params = out.parameterStrings()
        XCTAssertEqual(params["camera"], "fox cam")
        XCTAssertEqual(params["seed"], "42")  // non-string values untouched
    }

    // MARK: - Bundle formatVersion 3

    func testBundleVersionIs3OnlyWithArgsOrUses() {
        var plain = RecipeBundle.ExportedRecipe(
            id: "id", name: "n", promptText: "p", negativePromptText: "")
        XCTAssertEqual(RecipeBundle.formatVersion(for: [plain]), 2)
        plain.args = [RecipeArg(name: "a", type: "string", defaultValue: nil,
                                choices: nil, description: nil)]
        XCTAssertEqual(RecipeBundle.formatVersion(for: [plain]), 3)
        plain.args = nil
        plain.uses = [RecipeUse(recipeId: "other", args: ["a": .number(1)])]
        XCTAssertEqual(RecipeBundle.formatVersion(for: [plain]), 3)
    }

    func testV3BundleRoundtripAndV2Decode() throws {
        // v3 roundtrip: args with string/number defaults + uses survive encode/decode
        var recipe = RecipeBundle.ExportedRecipe(
            id: "id", name: "n", promptText: "a {{subject}}", negativePromptText: "")
        recipe.args = [
            RecipeArg(name: "subject", type: "string", defaultValue: .string("fox"),
                      choices: nil, description: "main subject"),
            RecipeArg(name: "style", type: "enum", defaultValue: .string("anime"),
                      choices: ["anime", "noir"], description: nil),
            RecipeArg(name: "duration", type: "number", defaultValue: .number(7.5),
                      choices: nil, description: nil),
        ]
        recipe.uses = [RecipeUse(recipeId: "base-recipe", args: ["subject": .string("owl")])]
        var bundle = RecipeBundle(exportedAt: Date(), author: nil, recipes: [recipe])
        bundle.formatVersion = RecipeBundle.formatVersion(for: [recipe])

        let decoded = try RecipeBundle.decode(from: try bundle.encode())
        XCTAssertEqual(decoded.formatVersion, 3)
        let r = try XCTUnwrap(decoded.recipes.first)
        XCTAssertEqual(r.args?.count, 3)
        XCTAssertEqual(r.args?[0].defaultValue, .string("fox"))
        XCTAssertEqual(r.args?[1].choices, ["anime", "noir"])
        XCTAssertEqual(r.args?[2].defaultValue, .number(7.5))
        XCTAssertEqual(r.uses?.first?.recipeId, "base-recipe")
        XCTAssertEqual(r.uses?.first?.args?["subject"], .string("owl"))

        // The encoded JSON uses the "default" key (not "defaultValue")
        let json = String(data: try bundle.encode(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"default\""))
        XCTAssertFalse(json.contains("defaultValue"))

        // v2 bundle (no args) decodes with nil args/uses — behavior unchanged
        let v2 = """
        {"formatVersion": 2, "exportedAt": "2026-07-04T00:00:00Z",
         "recipes": [{"id": "x", "name": "n", "promptText": "p", "negativePromptText": ""}]}
        """
        let v2Decoded = try RecipeBundle.decode(from: Data(v2.utf8))
        XCTAssertNil(v2Decoded.recipes.first?.args)
        XCTAssertNil(v2Decoded.recipes.first?.uses)
        XCTAssertEqual(RecipeBundle.formatVersion(for: v2Decoded.recipes), 2)
    }

    func testCLIRecipeCarriesArgsThroughImportAndExport() throws {
        var exported = RecipeBundle.ExportedRecipe(
            id: "id", name: "n", promptText: "a {{subject}}", negativePromptText: "")
        exported.args = [RecipeArg(name: "subject", type: "string",
                                   defaultValue: .string("fox"), choices: nil, description: nil)]
        exported.uses = [RecipeUse(recipeId: "base", args: nil)]

        let imported = CLIRecipe(from: exported)
        XCTAssertEqual(imported.args?.count, 1)
        XCTAssertEqual(imported.uses?.first?.recipeId, "base")

        let reExported = imported.toExported()
        XCTAssertEqual(reExported.args, exported.args)
        XCTAssertEqual(reExported.uses, exported.uses)
        XCTAssertEqual(RecipeBundle.formatVersion(for: [reExported]), 3)

        // jsonRepresentation surfaces args for agents
        let dict = imported.jsonRepresentation
        XCTAssertNotNil(dict["args"])
        XCTAssertNotNil(dict["uses"])
    }
}
