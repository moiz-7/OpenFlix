import XCTest
@testable import openflix

/// Pure parts of `workflow publish` / `workflow import`:
/// reference parsing, output-name derivation, name defaulting, and the
/// local spec-validation gate both commands run before touching the network.
final class WorkflowRegistryTests: XCTestCase {

    private let defaultBase = "https://registry.openflix.app"

    // MARK: - Reference resolution (id or full URL)

    func testResolveBareId() {
        let ref = WorkflowRegistryRef.resolve("wf_abc123", defaultBase: defaultBase)
        XCTAssertEqual(ref?.base, defaultBase)
        XCTAssertEqual(ref?.id, "wf_abc123")
    }

    func testResolveFullPageURL() {
        let ref = WorkflowRegistryRef.resolve(
            "https://registry.openflix.app/workflows/wf_abc123", defaultBase: defaultBase)
        XCTAssertEqual(ref?.base, "https://registry.openflix.app")
        XCTAssertEqual(ref?.id, "wf_abc123")
    }

    func testResolveFullAPIURLWithPort() {
        let ref = WorkflowRegistryRef.resolve(
            "http://127.0.0.1:8000/api/workflows/wf_9", defaultBase: defaultBase)
        XCTAssertEqual(ref?.base, "http://127.0.0.1:8000")
        XCTAssertEqual(ref?.id, "wf_9")
    }

    func testResolveRejectsInvalidInputs() {
        // URL without a workflows path segment
        XCTAssertNil(WorkflowRegistryRef.resolve(
            "https://registry.openflix.app/recipes/r1", defaultBase: defaultBase))
        // URL ending at /workflows with no id
        XCTAssertNil(WorkflowRegistryRef.resolve(
            "https://registry.openflix.app/workflows", defaultBase: defaultBase))
        // Bare id must not contain a slash
        XCTAssertNil(WorkflowRegistryRef.resolve("abc/def", defaultBase: defaultBase))
        // Empty / whitespace
        XCTAssertNil(WorkflowRegistryRef.resolve("   ", defaultBase: defaultBase))
    }

    // MARK: - Output-name derivation

    func testDefaultOutputFilenameSanitizesName() {
        XCTAssertEqual(WorkflowRegistryRef.defaultOutputFilename(name: "my-film"),
                       "my-film.workflow.json")
        XCTAssertEqual(WorkflowRegistryRef.defaultOutputFilename(name: "My Film: Act 2!"),
                       "My-Film--Act-2.workflow.json")
        // Path separators can never leak into the filename
        XCTAssertFalse(WorkflowRegistryRef.defaultOutputFilename(name: "../evil/name")
            .contains("/"))
        XCTAssertEqual(WorkflowRegistryRef.defaultOutputFilename(name: "///"),
                       "workflow.workflow.json")
    }

    // MARK: - Publish name defaulting

    func testEffectiveNamePrefersFlagThenSpec() {
        XCTAssertEqual(WorkflowRegistryRef.effectiveName(flag: "Override", specName: "spec-name"),
                       "Override")
        XCTAssertEqual(WorkflowRegistryRef.effectiveName(flag: nil, specName: "spec-name"),
                       "spec-name")
        XCTAssertEqual(WorkflowRegistryRef.effectiveName(flag: "   ", specName: "spec-name"),
                       "spec-name")
    }

    // MARK: - Spec-validation gate (same parser both commands call)

    func testValidationGateRejectsEmptyStages() {
        let data = Data(#"{"name": "x", "stages": []}"#.utf8)
        XCTAssertThrowsError(try WorkflowParser.parse(data: data, path: "x.json")) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "empty_stages")
        }
    }

    func testValidationGateAcceptsMinimalSpec() throws {
        let data = Data("""
        {"name": "ok", "stages": [
          {"id": "a", "prompt": "p", "provider": "fal", "model": "fal-ai/veo3"}
        ]}
        """.utf8)
        let spec = try WorkflowParser.parse(data: data, path: "ok.json")
        XCTAssertEqual(spec.stages.count, 1)
    }
}
