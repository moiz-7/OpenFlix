import XCTest
@testable import OpenFlixKit

/// The shared action vocabulary: argument validation, effect → annotation
/// derivation, and the manifest and result contracts every surface emits.
final class ActionVocabularyTests: XCTestCase {

    private let schema = JSONSchema.object(
        required: ["prompt"],
        properties: [
            "prompt": JSONSchema.string("What to make", maxLength: 10),
            "limit": JSONSchema.integer("How many", minimum: 0, maximum: 5),
            "threshold": JSONSchema.number("Score", minimum: 0, maximum: 100),
            "sort": JSONSchema.enumeration("Order", ["a", "b"]),
            "wait": JSONSchema.boolean("Block"),
            "tags": JSONSchema.array("Tags", items: .object(["type": .string("string")])),
        ])

    private func refusal(_ arguments: JSONValue) -> ActionInputError? {
        do {
            try ActionValidator.validate(arguments, against: schema)
            return nil
        } catch let error as ActionInputError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    // MARK: - Validation

    func testAValidCallPasses() {
        XCTAssertNil(refusal(.object([
            "prompt": .string("fox"), "limit": .int(3), "threshold": .int(80),
            "sort": .string("b"), "wait": .bool(true), "tags": .array([.string("x")]),
        ])))
    }

    /// On a paid call, a misspelled argument silently ignored is a default
    /// silently billed. It is refused, and the refusal lists what is accepted.
    func testAnUnknownArgumentIsRefusedWithTheAcceptedNames() {
        let error = refusal(.object(["prompt": .string("fox"), "duration": .int(5)]))
        XCTAssertEqual(error?.argument, "duration")
        XCTAssertTrue(error?.message.contains("Accepted:") == true)
        XCTAssertTrue(error?.message.contains("limit") == true)
    }

    func testAMissingRequiredArgumentCarriesItsDescription() {
        let error = refusal(.object([:]))
        XCTAssertEqual(error?.argument, "prompt")
        XCTAssertTrue(error?.message.contains("What to make") == true, error?.message ?? "")
    }

    func testNullReadsAsAbsent() {
        XCTAssertNil(refusal(.object(["prompt": .string("fox"), "limit": .null])))
        XCTAssertEqual(refusal(.object(["prompt": .null]))?.argument, "prompt")
        XCTAssertEqual(refusal(.null)?.argument, "prompt",
                       "null arguments read as {} — and {} is missing the required prompt")
    }

    func testTypesBoundsEnumsAndLengthsAreEnforced() {
        let cases: [(String, JSONValue)] = [
            ("prompt", .int(1)),
            ("prompt", .string("way more than ten")),
            ("limit", .int(-1)),
            ("limit", .int(6)),
            ("limit", .double(2.5)),
            ("threshold", .double(100.5)),
            ("threshold", .string("80")),
            ("sort", .string("c")),
            ("wait", .string("true")),
            ("tags", .array([.int(1)])),
            ("tags", .string("x")),
        ]
        for (name, value) in cases {
            var arguments: [String: JSONValue] = ["prompt": .string("fox")]
            arguments[name] = value
            XCTAssertEqual(refusal(.object(arguments))?.argument, name, "\(name) = \(value)")
        }
    }

    func testIntegersCountAsNumbers() {
        XCTAssertNil(refusal(.object(["prompt": .string("fox"), "threshold": .int(80)])))
    }

    func testArgumentsMustBeAnObject() {
        XCTAssertNotNil(refusal(.array([])))
        XCTAssertNotNil(refusal(.string("prompt=fox")))
    }

    // MARK: - Effects → annotations

    private func descriptor(_ effect: ActionEffect, openWorld: Bool = true,
                            idempotent: Bool = false) -> ActionDescriptor {
        ActionDescriptor(name: "x", title: "X", description: "Does x.", effect: effect,
                         openWorld: openWorld, idempotent: idempotent,
                         inputSchema: JSONSchema.object(properties: [:]))
    }

    /// MCP cannot say "costs money", and a client decides whether to ask the
    /// human from `destructiveHint` — so spend is destructive by construction.
    func testSpendIsAlwaysDestructive() {
        let hints = descriptor(.spend).annotations
        XCTAssertFalse(hints.readOnlyHint)
        XCTAssertEqual(hints.destructiveHint, true)
        XCTAssertTrue(hints.openWorldHint)
    }

    func testReadsCarryNoWriteHints() {
        let hints = descriptor(.read, openWorld: false).annotations
        XCTAssertTrue(hints.readOnlyHint)
        XCTAssertNil(hints.destructiveHint)
        XCTAssertNil(hints.idempotentHint)
        XCTAssertFalse(hints.openWorldHint)
    }

    func testEveryEffectMapsToExactlyOneReadOnlyAndDestructiveAnswer() {
        for effect in ActionEffect.allCases {
            let hints = descriptor(effect).annotations
            XCTAssertEqual(hints.readOnlyHint, effect == .read, "\(effect)")
            if effect != .read {
                XCTAssertEqual(hints.destructiveHint, effect == .spend || effect == .destructive, "\(effect)")
            }
        }
    }

    func testSpendingOrSharingWithoutLeavingTheMachineIsAProblem() {
        XCTAssertFalse(descriptor(.spend, openWorld: false).problems.isEmpty)
        XCTAssertFalse(descriptor(.share, openWorld: false).problems.isEmpty)
        XCTAssertTrue(descriptor(.localWrite, openWorld: false).problems.isEmpty)
    }

    func testAnOpenInputSchemaOrAnUndescribedPropertyIsAProblem() {
        let open = ActionDescriptor(
            name: "x", title: "X", description: "Does x.", effect: .read, openWorld: false,
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]))
        XCTAssertTrue(open.problems.contains { $0.contains("additionalProperties") })

        let undescribed = ActionDescriptor(
            name: "x", title: "X", description: "Does x.", effect: .read, openWorld: false,
            inputSchema: JSONSchema.object(properties: ["q": .object(["type": .string("string")])]))
        XCTAssertTrue(undescribed.problems.contains { $0.contains("no description") })
    }

    func testNamesKeepToTheModelBoundaryGrammar() {
        XCTAssertTrue(ActionDescriptor.isWellFormedName("list_generations"))
        XCTAssertFalse(ActionDescriptor.isWellFormedName("library.search"))
        XCTAssertFalse(ActionDescriptor.isWellFormedName(""))
        XCTAssertFalse(ActionDescriptor.isWellFormedName(String(repeating: "a", count: 65)))
    }

    // MARK: - Contracts

    func testTheManifestCarriesEffectAnnotationsAndSchema() {
        let manifest = ActionManifest.document(host: "h", version: "1", actions: [descriptor(.spend)])
        XCTAssertEqual(manifest["contract"]?.stringValue, "openflix.action_manifest.v1")
        let entry = manifest["actions"]?.arrayValue?.first
        XCTAssertEqual(entry?["effect"]?.stringValue, "spend")
        XCTAssertEqual(entry?["annotations"]?["destructiveHint"]?.boolValue, true)
        XCTAssertNotNil(entry?["input_schema"]?.objectValue)
    }

    func testARefusalAndAFailureAreDistinguishable() {
        let refused = ActionResult.failure(action: "a", ActionFailure(
            code: "BUDGET_EXCEEDED", errorClass: .policy, message: "no"))
        let failed = ActionResult.failure(action: "a", ActionFailure(
            code: "PROVIDER_SERVER_ERROR", errorClass: .upstream, message: "500", retryable: true))
        XCTAssertEqual(refused["status"]?.stringValue, "refused")
        XCTAssertEqual(failed["status"]?.stringValue, "failed")
        XCTAssertEqual(failed["error"]?["retryable"]?.boolValue, true)
        XCTAssertEqual(ActionResult.success(action: "a", data: .object([:]))["status"]?.stringValue, "ok")
    }

    func testEveryErrorClassHasAnHTTPStatus() {
        for errorClass in ActionErrorClass.allCases {
            XCTAssertTrue((400...599).contains(errorClass.httpStatus), "\(errorClass)")
        }
    }

    // MARK: - JSONValue

    func testNonFiniteNumbersNeverReachTheEncoder() {
        XCTAssertEqual(JSONValue(any: Double.nan), .null)
        XCTAssertEqual(JSONValue.double(.infinity).jsonString(), "null")
    }

    func testFoundationValuesRoundTrip() {
        let any: [String: Any] = ["a": 1, "b": 2.5, "c": "x", "d": true, "e": [1, 2], "f": ["g": NSNull()]]
        let json = JSONValue(any: any)
        XCTAssertEqual(json["a"], .int(1))
        XCTAssertEqual(json["b"], .double(2.5))
        XCTAssertEqual(json["d"], .bool(true))
        XCTAssertEqual(json["f"]?["g"], .null)
        XCTAssertEqual(JSONValue(any: json.anyValue), json)
    }

    /// A number parsed by `JSONSerialization` must stay a number, and a
    /// boolean a boolean, even though both arrive as `NSNumber`.
    func testParsedNumbersAndBooleansKeepTheirKind() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"one":1,"yes":true,"half":0.5,"two":2.0}"#.utf8))
        let json = JSONValue(any: parsed)
        XCTAssertEqual(json["one"], .int(1))
        XCTAssertEqual(json["yes"], .bool(true))
        XCTAssertEqual(json["half"], .double(0.5))
        XCTAssertEqual(json["two"]?.doubleValue, 2.0)
    }
}
