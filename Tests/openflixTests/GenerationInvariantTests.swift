import XCTest
import OpenFlixKit
@testable import openflix

/// Plan 06 · C1-1 (duration is unvalidated outside `generate`) and
/// C1-2 (reference images vanish instead of being refused).
///
/// Both are honesty bugs on a money path: the user asked for something the
/// system could not do, and instead of saying so it quietly did something else
/// and billed for it.
final class GenerationInvariantTests: XCTestCase {

    // A model with a known ceiling, so the model-max branch is exercised
    // without depending on a particular provider catalog entry.
    private func model(max: Double?) -> CLIProviderModel {
        CLIProviderModel(providerId: "fal", providerName: "fal.ai",
                         modelId: "test-model", displayName: "Test",
                         defaultWidth: nil, defaultHeight: nil,
                         maxDurationSeconds: max, costPerSecondUSD: 0.05,
                         supportsImageToVideo: true)
    }

    private func validate(_ duration: Double?, modelMax: Double? = 10) throws {
        try GenerationEngine.validateDuration(duration, providerID: "fal",
                                              model: "test-model",
                                              modelInfo: model(max: modelMax))
    }

    private func assertRefused(_ duration: Double?, modelMax: Double? = 10,
                               contains fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try validate(duration, modelMax: modelMax), file: file, line: line) { error in
            guard let e = error as? OpenFlixError else {
                return XCTFail("expected OpenFlixError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(e.code, "invalid_input", file: file, line: line)
            XCTAssertTrue((e.errorDescription ?? "").localizedCaseInsensitiveContains(fragment),
                          "message '\(e.errorDescription ?? "")' lacks '\(fragment)'", file: file, line: line)
        }
    }

    // MARK: - C1-1 · duration invariant at the choke point

    func testNoDurationIsAlwaysAllowed() throws {
        // Omitting duration is legitimate — the provider bills its own default,
        // which the budget pre-flight already accounts for.
        try validate(nil)
    }

    func testDurationWithinModelCeilingIsAllowed() throws {
        try validate(5)
        try validate(10)      // exactly the model max
        try validate(0.5)     // sub-second is odd but not impossible
    }

    func testNaNDurationIsRefusedNotNormalised() {
        // Previously: durationInt() returned nil, the provider silently used
        // its default duration, and the user was billed for a generation they
        // never described. Also the value that makes `Int(Double)` abort.
        assertRefused(.nan, contains: "finite")
    }

    func testInfiniteDurationIsRefused() {
        assertRefused(.infinity, contains: "finite")
        assertRefused(-.infinity, contains: "finite")
    }

    func testZeroAndNegativeDurationsAreRefused() {
        assertRefused(0, contains: "positive")
        assertRefused(-4, contains: "positive")
    }

    func testDurationAboveGlobalCeilingIsRefused() {
        // 9 999 s used to be clamped to 3600 by durationInt(), then clamped
        // again by the provider — nobody ever told the user.
        assertRefused(9_999, modelMax: nil, contains: "maximum allowed")
        assertRefused(601, modelMax: nil, contains: "600")
    }

    func testExactlyTheGlobalCeilingIsAllowedWhenTheModelHasNoLimit() throws {
        try validate(GenerationEngine.maxRequestDurationSeconds, modelMax: nil)
    }

    func testDurationAboveModelCeilingIsRefusedWithTheCeilingInTheMessage() {
        assertRefused(30, modelMax: 10, contains: "model max 10s")
    }

    func testUnknownModelStillGetsTheGlobalCeiling() throws {
        // modelInfo == nil happens for models not in the local catalog. The
        // global bound must still apply; the model bound cannot.
        try GenerationEngine.validateDuration(120, providerID: "fal", model: "unlisted", modelInfo: nil)
        XCTAssertThrowsError(
            try GenerationEngine.validateDuration(1_000, providerID: "fal", model: "unlisted", modelInfo: nil))
    }

    func testRefusalNamesTheProviderAndModel() {
        XCTAssertThrowsError(try validate(9_999)) { error in
            let message = (error as? OpenFlixError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("fal/test-model"), "message should identify what was refused: \(message)")
        }
    }

    func testRefusalIsStructuredAsInputInvalidForAgents() {
        let structured = StructuredError.from(.invalidInput("duration 9999s exceeds maximum allowed (600s)."))
        XCTAssertEqual(structured.code, .inputInvalid)
        XCTAssertFalse(structured.retryable)
        XCTAssertEqual(structured.jsonRepresentation["code"] as? String, "INPUT_INVALID")
    }

    func testInvalidInputErrorCodeMatchesTheGenerateFlagBoundary() {
        // `generate` reports code "invalid_input" from its flag parser. The
        // engine must report the same code for the same refusal, or scripts
        // that branch on it break depending on which surface they used.
        XCTAssertEqual(OpenFlixError.invalidInput("x").code, "invalid_input")
    }

    func testFormatSecondsTrimsTheTrailingZero() {
        XCTAssertEqual(GenerationEngine.formatSeconds(600), "600")
        XCTAssertEqual(GenerationEngine.formatSeconds(4.5), "4.5")
        XCTAssertEqual(GenerationEngine.formatSeconds(10), "10")
    }

    func testDurationValidationDoesNotTrapOnValuesThatBreakIntConversion() {
        // Belt and braces: validateDuration must never itself use Int(Double).
        for value in [Double.nan, .infinity, -.infinity, 1e30, -1e30] {
            XCTAssertThrowsError(try validate(value, modelMax: nil), "\(value) should be refused")
        }
    }

    // MARK: - C1-2 · reference images must never vanish

    /// The exact expression every non-flag call site used before this fix.
    private func legacyParse(_ raw: String?) -> URL? {
        raw.flatMap { URL(string: $0) }
    }

    func testNilAndBlankMeanNoReferenceImage() throws {
        XCTAssertNil(try GenerationEngine.parseReferenceImage(nil))
        XCTAssertNil(try GenerationEngine.parseReferenceImage(""))
        XCTAssertNil(try GenerationEngine.parseReferenceImage("   "))
        XCTAssertNil(try GenerationEngine.parseReferenceImage("\n\t "))
    }

    func testRemoteURLsPassThroughUnchanged() throws {
        let https = try XCTUnwrap(try GenerationEngine.parseReferenceImage("https://x.com/a.png"))
        XCTAssertEqual(https.absoluteString, "https://x.com/a.png")
        let http = try XCTUnwrap(try GenerationEngine.parseReferenceImage("http://x.com/a.png"))
        XCTAssertEqual(http.absoluteString, "http://x.com/a.png")
    }

    func testWhitespaceAroundAURLIsTrimmedNotRejected() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("  https://x.com/a.png\n"))
        XCTAssertEqual(url.absoluteString, "https://x.com/a.png")
    }

    /// **The regression that would have caught C1-2.**
    ///
    /// `URL(string:)` returns nil for a range of ordinary strings — a space
    /// anywhere on macOS 14 (this package's minimum deployment target), a space
    /// in the host on every version, an empty string. `flatMap` turned that nil
    /// into "no reference image": the generation was submitted as
    /// text-to-video, billed, and the honest refusal in
    /// `validateReferenceImage` never got the chance to fire.
    ///
    /// The invariant is version-independent even though which inputs trip it is
    /// not: **whenever the legacy expression loses the value, the new parser
    /// must not.**
    func testNoInputThatLegacyParsingDroppedIsSilentlyLostNow() {
        let inputs = [
            "https://x.com/my ref.png",
            "https://x.com/folder name/ref.png",
            "/Users/me/My Photos/ref.png",
            "/Users/me/ref.png",
            "~/Pictures/My Ref.png",
            "ref.png",
            "https://ex ample.com/a.png",
            "file:///Users/me/My Photos/a.png",
            "https://x.com/a%20b.png",
        ]
        for input in inputs where legacyParse(input) == nil {
            do {
                let parsed = try GenerationEngine.parseReferenceImage(input)
                XCTAssertNotNil(parsed, "'\(input)' was dropped silently — the exact C1-2 bug")
            } catch {
                // Refusing with a message is the other acceptable outcome.
                XCTAssertEqual((error as? OpenFlixError)?.code, "invalid_input",
                               "'\(input)' must be refused with an actionable error")
            }
        }
        // Guard against this test quietly becoming vacuous if Foundation gets
        // even more lenient: at least one input must still be unparsable.
        XCTAssertTrue(inputs.contains { legacyParse($0) == nil },
                      "no input exercises the nil path any more — pick harsher ones")
    }

    func testRemoteURLWithASpaceIsEncodedRatherThanDropped() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("https://x.com/my ref.png"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.hasSuffix("my%20ref.png"), "got \(url.absoluteString)")
    }

    func testAlreadyEncodedURLIsNotDoubleEncoded() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("https://x.com/a%20b.png"))
        XCTAssertEqual(url.absoluteString, "https://x.com/a%20b.png")
        XCTAssertFalse(url.absoluteString.contains("%2520"))
    }

    func testQueryStringSurvivesNormalisation() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("https://x.com/a.png?sig=abc"))
        XCTAssertEqual(url.query, "sig=abc")
    }

    func testUnfixableRemoteURLIsRefusedOutLoudNotDropped() {
        // A space in the *host* cannot be encoded away — a host may not contain
        // one. Inventing "ex%20ample.com" would be the same sin in a new
        // costume, so this is refused with a message instead.
        XCTAssertThrowsError(try GenerationEngine.parseReferenceImage("https://ex ample.com/a.png")) { error in
            guard let e = error as? OpenFlixError else { return XCTFail("wrong error type") }
            XCTAssertEqual(e.code, "invalid_input")
            XCTAssertTrue((e.errorDescription ?? "").contains("reference image"))
        }
        XCTAssertNil(legacyParse("https://ex ample.com/a.png"),
                     "precondition: this is exactly what used to vanish")
    }

    func testLocalPathBecomesAFileURLSoTheChokePointCanRefuseIt() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("/Users/me/My Photos/ref.png"))
        XCTAssertEqual(url.scheme, "file")
        // …and the honest refusal now actually fires.
        XCTAssertThrowsError(try GenerationEngine.validateReferenceImage(url, providerID: "fal")) { error in
            XCTAssertTrue(((error as? OpenFlixError)?.errorDescription ?? "").contains("public http(s) URL"))
        }
    }

    func testTildePathIsExpanded() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("~/Pictures/ref.png"))
        XCTAssertEqual(url.scheme, "file")
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertTrue(url.path.hasSuffix("/Pictures/ref.png"))
    }

    func testRelativePathBecomesAnAbsoluteFileURL() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("ref.png"))
        XCTAssertEqual(url.scheme, "file")
        XCTAssertTrue(url.path.hasPrefix("/"))
    }

    func testExplicitFileSchemeIsPreservedAndRefused() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("file:///Users/me/a.png"))
        XCTAssertEqual(url.scheme, "file")
        XCTAssertThrowsError(try GenerationEngine.validateReferenceImage(url, providerID: "kling"))
    }

    func testForeignSchemeIsPreservedSoTheMessageQuotesWhatTheUserWrote() throws {
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("ftp://host/a.png"))
        XCTAssertEqual(url.scheme, "ftp")
        XCTAssertThrowsError(try GenerationEngine.validateReferenceImage(url, providerID: "fal")) { error in
            XCTAssertTrue(((error as? OpenFlixError)?.errorDescription ?? "").contains("ftp://host/a.png"))
        }
    }

    func testLocalProviderStillAcceptsALocalReference() throws {
        // ComfyUI runs on the same machine — the documented exemption. It must
        // survive the parse change, and now receives a well-formed file URL.
        let url = try XCTUnwrap(try GenerationEngine.parseReferenceImage("/tmp/My Ref.png"))
        try GenerationEngine.validateReferenceImage(url, providerID: "local")
    }

    func testNormalizeRemoteURLRejectsWhatItCannotRepresent() {
        XCTAssertNil(GenerationEngine.normalizeRemoteURL("https://"))
        XCTAssertNil(GenerationEngine.normalizeRemoteURL("https:///no-host/a.png"))
        XCTAssertNil(GenerationEngine.normalizeRemoteURL("not-a-url"))
        XCTAssertNotNil(GenerationEngine.normalizeRemoteURL("https://x.com/a b.png"))
    }

    // MARK: - Ingestion-level duration checks (fail before anything is billed)

    private func stageJSON(duration: Double?) -> Data {
        let extra = duration.map { ",\"duration\":\($0)" } ?? ""
        return Data("""
        {"name":"t","stages":[{"id":"a","prompt":"p","provider":"fal","model":"fal-ai/veo3"\(extra)}]}
        """.utf8)
    }

    /// Decoded but NOT validated — `WorkflowParser.parse` validates, which is
    /// exactly what these tests are exercising.
    private func stage(duration: Double?) -> WorkflowSpec {
        try! JSONDecoder().decode(WorkflowSpec.self, from: stageJSON(duration: duration))
    }

    func testWorkflowValidationAcceptsASaneDuration() throws {
        try WorkflowParser.validate(stage(duration: 5))
        try WorkflowParser.validate(stage(duration: nil))
    }

    func testWorkflowValidationRefusesImpossibleDurations() {
        for bad in [0.0, -2, 601, 100_000] {
            XCTAssertThrowsError(try WorkflowParser.validate(stage(duration: bad)), "\(bad) should be refused") { error in
                guard let e = error as? WorkflowSpecError else { return XCTFail("wrong error type") }
                XCTAssertEqual(e.code, "invalid_duration")
                XCTAssertTrue((e.errorDescription ?? "").contains("stage 'a'")
                              || (e.errorDescription ?? "").contains("Stage 'a'"))
            }
        }
    }

    func testWorkflowFileIngestionRefusesTheDurationBeforeAnythingRuns() {
        // The real entry point: `workflow run <file>` parses, and parse()
        // validates. An impossible duration never reaches the DAG executor.
        XCTAssertThrowsError(try WorkflowParser.parse(data: stageJSON(duration: 9_999), path: "wf.json")) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "invalid_duration")
        }
        XCTAssertNoThrow(try WorkflowParser.parse(data: stageJSON(duration: 5), path: "wf.json"))
    }

    func testWorkflowDryRunCannotBlessAPlanTheRunWouldRefuse() {
        // The point of validating at ingestion as well as at the choke point:
        // `workflow run --dry-run` must not report a happy plan for a duration
        // the real run refuses.
        XCTAssertThrowsError(try WorkflowParser.validate(stage(duration: 5_000)))
        XCTAssertThrowsError(try validate(5_000, modelMax: nil))
    }
}
