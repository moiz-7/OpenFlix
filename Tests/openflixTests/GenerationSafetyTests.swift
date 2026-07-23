import XCTest
import OpenFlixKit
@testable import openflix

/// Regression tests for the 2026-07-17 video-generation stress-test fixes:
/// non-finite duration crash (F1), local reference-image rejection (F2),
/// and the budget pre-flight estimate that closes the no-duration bypass (F3).
final class GenerationSafetyTests: XCTestCase {

    // MARK: - F1: durationInt() must never trap

    private func request(duration: Double?) -> GenerationRequest {
        GenerationRequest(prompt: "p", model: "m", durationSeconds: duration)
    }

    func testDurationIntNormalValueRoundsToInt() {
        XCTAssertEqual(request(duration: 5).durationInt(), 5)
        XCTAssertEqual(request(duration: 4.6).durationInt(), 5)   // rounds
        XCTAssertEqual(request(duration: 4.4).durationInt(), 4)
    }

    func testDurationIntNilForMissingOrNonPositive() {
        XCTAssertNil(request(duration: nil).durationInt())
        XCTAssertNil(request(duration: 0).durationInt())
        XCTAssertNil(request(duration: -3).durationInt())
    }

    func testDurationIntNilForNonFinite_doesNotTrap() {
        // These are the values that make a bare `Int(Double)` abort the process.
        // Reachable via workflow/MCP/batch/recipe/scatter, which skip the
        // flag-level duration validation that `generate` performs.
        XCTAssertNil(request(duration: .nan).durationInt())
        XCTAssertNil(request(duration: .infinity).durationInt())
        XCTAssertNil(request(duration: -.infinity).durationInt())
    }

    func testDurationIntClampsAbsurdValues_doesNotTrap() {
        // 1e30 overflows Int and would trap without the clamp.
        XCTAssertEqual(request(duration: 1e30).durationInt(), 3600)
        XCTAssertEqual(request(duration: 5000).durationInt(max: 3600), 3600)
    }

    // MARK: - F2: reference-image URL must be remote-fetchable

    func testValidateReferenceImageAllowsRemoteURLs() throws {
        try GenerationEngine.validateReferenceImage(URL(string: "https://x.com/a.png"), providerID: "fal")
        try GenerationEngine.validateReferenceImage(URL(string: "http://x.com/a.png"), providerID: "runway")
        try GenerationEngine.validateReferenceImage(nil, providerID: "fal")  // no image is fine
    }

    func testValidateReferenceImageRejectsLocalFileURL() {
        XCTAssertThrowsError(
            try GenerationEngine.validateReferenceImage(URL(fileURLWithPath: "/tmp/a.png"), providerID: "fal")
        ) { error in
            guard let e = error as? OpenFlixError else { return XCTFail("wrong error type") }
            XCTAssertEqual(e.code, "invalid_response")
            XCTAssertTrue((e.errorDescription ?? "").contains("public http(s) URL"))
        }
    }

    func testValidateReferenceImageRejectsSchemelessPath() {
        // The batch/scatter/project paths build reference URLs with
        // URL(string:), which yields a non-nil, scheme-less URL for a bare path.
        XCTAssertThrowsError(
            try GenerationEngine.validateReferenceImage(URL(string: "/Users/me/a.png"), providerID: "kling")
        )
    }

    func testValidateReferenceImageExemptsLocalProvider() throws {
        // ComfyUI runs on the same machine; it ignores the reference image but
        // a local path must not be rejected for it.
        try GenerationEngine.validateReferenceImage(URL(fileURLWithPath: "/tmp/a.png"), providerID: "local")
    }

    // MARK: - F3: budget pre-flight estimate

    func testPreflightEstimateUsesDefaultDurationWhenNil() {
        // No duration must NOT estimate $0 — providers bill their default
        // duration, so the gate has to run. cps=0.10 × default 4s = 0.40.
        let est = GenerationEngine.preflightEstimate(durationSeconds: nil, costPerSecondUSD: 0.10)
        XCTAssertEqual(est, 0.10 * GenerationEngine.defaultBillableDurationSeconds, accuracy: 1e-9)
        XCTAssertGreaterThan(est, 0)
    }

    func testPreflightEstimateUsesGivenDuration() {
        XCTAssertEqual(GenerationEngine.preflightEstimate(durationSeconds: 8, costPerSecondUSD: 0.05),
                       0.40, accuracy: 1e-9)
    }

    func testPreflightEstimateZeroWhenNoCost() {
        XCTAssertEqual(GenerationEngine.preflightEstimate(durationSeconds: 8, costPerSecondUSD: nil), 0)
        XCTAssertEqual(GenerationEngine.preflightEstimate(durationSeconds: 8, costPerSecondUSD: 0), 0)
    }

    func testPreflightEstimateSanitizesNonFiniteDuration() {
        // NaN would make cps*dur NaN, and `NaN > limit` is always false —
        // silently defeating the gate. It must fall back to the default.
        let est = GenerationEngine.preflightEstimate(durationSeconds: .nan, costPerSecondUSD: 0.10)
        XCTAssertTrue(est.isFinite)
        XCTAssertEqual(est, 0.10 * GenerationEngine.defaultBillableDurationSeconds, accuracy: 1e-9)
    }

    // MARK: - Scatter with no targets must not crash (index out of range)

    private func makeShot() -> Shot {
        Shot(id: "s1", sceneId: "sc", name: "s1", orderIndex: 0, prompt: "p",
             negativePrompt: nil, status: .pending, provider: nil, model: nil,
             duration: nil, aspectRatio: nil, width: nil, height: nil,
             referenceImageURL: nil, referenceAssetId: nil, extraParams: [:],
             dependencies: [], generationIds: [], selectedGenerationId: nil,
             routingDecision: nil, estimatedCostUSD: nil, actualCostUSD: nil,
             maxRetries: nil, errorMessage: nil, qualityScore: nil,
             evaluationReasoning: nil, evaluationDimensions: nil,
             createdAt: Date(), startedAt: nil, completedAt: nil)
    }

    func testScatterWithEmptyTargetsReturnsEmpty_doesNotTrap() async {
        // window = max(1, min(8, 0)) == 1 → the old priming loop read targets[0]
        // on an empty array and aborted the whole run. The pinned scatter path
        // can hand in [] (no keys configured / capability filter empties it).
        let results = await ScatterGatherExecutor.scatter(
            shot: makeShot(), targets: [], apiKey: nil,
            options: GenerationEngine.Options())
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Retry must be able to reproduce the original request (F4/retry)

    func testGenerationPersistsReferenceImageAndExtraParams() throws {
        var gen = CLIGeneration(
            id: "g1", status: .succeeded, provider: "fal", model: "fal-ai/veo3",
            prompt: "p", negativePrompt: nil, aspectRatio: nil,
            widthPx: nil, heightPx: nil, durationSeconds: 4,
            remoteTaskId: nil, statusURL: nil, remoteVideoURL: nil, localPath: nil,
            estimatedCostUSD: 0.2, actualCostUSD: nil, errorMessage: nil,
            retryCount: 0, projectId: nil, shotId: nil,
            createdAt: Date(), submittedAt: nil, completedAt: nil)
        gen.referenceImageURL = "https://x.com/a.png"
        gen.extraParams = ["seed": .int(42), "audio": .bool(true)]

        // Round-trips through the store's JSON encoding, so `retry` can recover
        // the exact inputs instead of resubmitting a different T2V request.
        let encoded = try JSONEncoder().encode(gen)
        let decoded = try JSONDecoder().decode(CLIGeneration.self, from: encoded)
        XCTAssertEqual(decoded.referenceImageURL, "https://x.com/a.png")
        XCTAssertEqual(decoded.extraParams?["seed"]?.toAny() as? Int, 42)
        XCTAssertEqual(decoded.extraParams?["audio"]?.toAny() as? Bool, true)
        XCTAssertEqual(gen.jsonRepresentation["reference_image_url"] as? String, "https://x.com/a.png")
    }

    func testOldGenerationRecordDecodesWithNilNewFields() throws {
        // Backward compatibility: a record written before these fields existed
        // must still decode (optional + defaulted), not throw.
        let legacy = """
        {"id":"g0","status":"succeeded","provider":"fal","model":"m","prompt":"p",
         "retryCount":0,"createdAt":"2026-07-17T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let gen = try decoder.decode(CLIGeneration.self, from: Data(legacy.utf8))
        XCTAssertNil(gen.referenceImageURL)
        XCTAssertNil(gen.extraParams)
    }
}
