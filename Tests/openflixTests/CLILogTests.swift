import XCTest
@testable import openflix

/// Tests for the operational log added in plan 06 (C1-3).
///
/// Two properties matter more than anything else here:
///   1. **stdout is never touched** — the CLI's JSON output is its API.
///   2. **nothing secret is ever written** — keys live in the keychain
///      precisely so they don't end up in a file. A redactor nobody tested is
///      worse than no logging at all, so every pattern gets a case below.
final class CLILogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openflix-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeLogger(level: CLILogLevel = .debug, maxBytes: Int = CLILog.defaultMaxFileBytes) -> CLILog {
        CLILog(directory: tempDir, level: level, maxFileBytes: maxBytes)
    }

    private func readLines(_ logger: CLILog) throws -> [[String: Any]] {
        guard let url = logger.fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    // MARK: - Level parsing and filtering

    func testLevelParsingAcceptsCanonicalNames() {
        XCTAssertEqual(CLILogLevel.parse("debug"), .debug)
        XCTAssertEqual(CLILogLevel.parse("info"), .info)
        XCTAssertEqual(CLILogLevel.parse("warn"), .warn)
        XCTAssertEqual(CLILogLevel.parse("error"), .error)
        XCTAssertEqual(CLILogLevel.parse("off"), .off)
    }

    func testLevelParsingAcceptsAliasesAndIsCaseInsensitive() {
        XCTAssertEqual(CLILogLevel.parse("VERBOSE"), .debug)
        XCTAssertEqual(CLILogLevel.parse(" Warning "), .warn)
        XCTAssertEqual(CLILogLevel.parse("none"), .off)
        XCTAssertEqual(CLILogLevel.parse("SILENT"), .off)
    }

    func testLevelParsingFallsBackForUnknownOrMissing() {
        XCTAssertEqual(CLILogLevel.parse(nil), .info)
        XCTAssertEqual(CLILogLevel.parse("banana"), .info)
        XCTAssertEqual(CLILogLevel.parse(nil, default: .off), .off)
    }

    func testLoggerDropsEntriesBelowItsLevel() throws {
        let logger = makeLogger(level: .warn)
        logger.debug("a.debug")
        logger.info("a.info")
        logger.warn("a.warn")
        logger.error("a.error")

        let events = try readLines(logger).compactMap { $0["event"] as? String }
        XCTAssertEqual(events, ["a.warn", "a.error"])
    }

    func testOffLevelWritesNothingAtAll() throws {
        let logger = makeLogger(level: .off)
        logger.error("should.not.appear")
        XCTAssertTrue(try readLines(logger).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logger.fileURL!.path))
    }

    func testNilFileURLIsSafeAndWritesNoFile() {
        let logger = CLILog(level: .debug, fileURL: nil)
        logger.info("no.sink")   // must not crash
        XCTAssertNil(logger.fileURL)
    }

    // MARK: - Record shape

    func testRecordCarriesTimestampLevelEventAndPid() throws {
        let logger = makeLogger()
        logger.info("generation.submitted", ["provider": "fal"])

        let lines = try readLines(logger)
        XCTAssertEqual(lines.count, 1)
        let entry = try XCTUnwrap(lines.first)
        XCTAssertEqual(entry["event"] as? String, "generation.submitted")
        XCTAssertEqual(entry["level"] as? String, "info")
        XCTAssertNotNil(entry["ts"] as? String)
        XCTAssertEqual(entry["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual((entry["fields"] as? [String: Any])?["provider"] as? String, "fal")
    }

    func testEachEntryIsOneParsableJSONLine() throws {
        let logger = makeLogger()
        for i in 0..<5 { logger.info("event.\(i)", ["n": i, "text": "multi\nline\tvalue"]) }
        let text = try String(contentsOf: logger.fileURL!, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 5, "one physical line per entry — embedded newlines must be escaped")
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    // MARK: - Redaction: sensitive field names

    func testSensitiveKeyNamesAreRedactedWhateverTheValue() {
        let out = CLIRedact.fields([
            "api_key": "totally-innocent-looking",
            "apiKey": "abc",
            "token": "xyz",
            "Authorization": "Basic dXNlcjpwdw==",
            "fal_key": "1234",
            "password": "hunter2",
        ])
        for key in ["api_key", "apiKey", "token", "Authorization", "fal_key", "password"] {
            XCTAssertEqual(out[key] as? String, CLIRedact.placeholder, "\(key) leaked")
        }
    }

    func testNonSensitiveKeysSurvive() {
        let out = CLIRedact.fields(["provider": "fal", "model": "veo3", "duration_seconds": 5])
        XCTAssertEqual(out["provider"] as? String, "fal")
        XCTAssertEqual(out["model"] as? String, "veo3")
        XCTAssertEqual(out["duration_seconds"] as? Int, 5)
    }

    func testRedactionRecursesIntoNestedDictionariesAndArrays() {
        let out = CLIRedact.fields([
            "request": ["headers": ["authorization": "Bearer abcdefghijklmnop"], "model": "veo3"],
            "attempts": [["token": "sk-abcdefghijklmnop"], ["ok": true]],
        ])
        let request = out["request"] as? [String: Any]
        let headers = request?["headers"] as? [String: Any]
        XCTAssertEqual(headers?["authorization"] as? String, CLIRedact.placeholder)
        XCTAssertEqual(request?["model"] as? String, "veo3")

        let attempts = out["attempts"] as? [Any]
        XCTAssertEqual((attempts?.first as? [String: Any])?["token"] as? String, CLIRedact.placeholder)
    }

    // MARK: - Redaction: credential-shaped free text

    func testBearerTokensAreScrubbedFromFreeText() {
        let scrubbed = CLIRedact.text("HTTP 401: {\"detail\":\"bad Bearer sk-live-9f8a7b6c5d4e3f2a\"}")
        XCTAssertFalse(scrubbed.contains("9f8a7b6c5d4e3f2a"))
        XCTAssertTrue(scrubbed.contains(CLIRedact.placeholder))
    }

    func testVendorShapedKeysAreScrubbed() {
        let cases = [
            "sk-abcdefghijklmnopqrstuvwx",
            "r8_ABCDEFGHIJKLMNOPQRSTUV0123456789",
            "key-0123456789abcdefabcd",
        ]
        for secret in cases {
            let scrubbed = CLIRedact.text("provider said: \(secret) is invalid")
            XCTAssertFalse(scrubbed.contains(secret), "\(secret) survived redaction")
        }
    }

    func testFalStyleKeyPairIsScrubbed() {
        let secret = "1b2c3d4e-5f60-7182-93a4-b5c6d7e8f900:0123456789abcdef0123456789abcdef"
        let scrubbed = CLIRedact.text("Authorization failed for \(secret)")
        XCTAssertFalse(scrubbed.contains(secret))
    }

    func testHeaderAndJSONPairsAreScrubbed() {
        XCTAssertFalse(CLIRedact.text("x-api-key: super-secret-value").contains("super-secret-value"))
        XCTAssertFalse(CLIRedact.text("{\"api_key\": \"super-secret-value\"}").contains("super-secret-value"))
        XCTAssertFalse(CLIRedact.text("authorization=abcdefgh").contains("abcdefgh"))
    }

    func testOrdinaryTextIsLeftAlone() {
        let message = "Generation failed: the model rejected the aspect ratio 21:9"
        XCTAssertEqual(CLIRedact.text(message), message)
    }

    func testSecretInAnOrdinaryFieldNeverReachesTheFile() throws {
        let logger = makeLogger()
        logger.error("generation.submit_failed", [
            "error": "HTTP 401 from fal: Bearer r8_ABCDEFGHIJKLMNOPQRSTUV0123456789 rejected",
        ])
        let text = try String(contentsOf: logger.fileURL!, encoding: .utf8)
        XCTAssertFalse(text.contains("r8_ABCDEFGHIJKLMNOPQRSTUV0123456789"))
        XCTAssertTrue(text.contains(CLIRedact.placeholder))
    }

    // MARK: - Redaction: URLs

    func testURLQueryIsRedactedBecauseSignedAssetURLsCarryCredentials() {
        let url = URL(string: "https://cdn.fal.ai/out.mp4?X-Amz-Signature=deadbeefcafe&expires=99")!
        let redacted = CLIRedact.url(url)
        XCTAssertNotNil(redacted)
        XCTAssertFalse(redacted!.contains("deadbeefcafe"))
        XCTAssertTrue(redacted!.hasPrefix("https://cdn.fal.ai/out.mp4"))
    }

    func testURLWithoutQueryIsUnchangedAndUserInfoIsStripped() {
        XCTAssertEqual(CLIRedact.url(URL(string: "https://cdn.fal.ai/out.mp4")), "https://cdn.fal.ai/out.mp4")
        let withUser = CLIRedact.url(URL(string: "https://user:pw@cdn.fal.ai/out.mp4"))
        XCTAssertNotNil(withUser)
        XCTAssertFalse(withUser!.contains("pw"))
    }

    func testNilURLRedactsToNil() {
        XCTAssertNil(CLIRedact.url(nil))
    }

    // MARK: - Redaction: prompts

    func testPromptIsRecordedAsADigestNotAsText() {
        let prompt = "a ceramic robot barista pours latte art in a neon Tokyo alley"
        let fields = CLIRedact.promptFields(prompt)
        XCTAssertEqual(fields["prompt_chars"] as? Int, prompt.count)
        let digest = try? XCTUnwrap(fields["prompt_sha256"] as? String)
        XCTAssertEqual(digest?.count, 12)
        XCTAssertNil(fields["prompt_preview"], "no preview unless explicitly asked for")
        for (_, value) in fields {
            XCTAssertNotEqual(value as? String, prompt)
        }
    }

    func testPromptDigestIsStableAndDistinguishing() {
        let a = CLIRedact.promptFields("same prompt")["prompt_sha256"] as? String
        let b = CLIRedact.promptFields("same prompt")["prompt_sha256"] as? String
        let c = CLIRedact.promptFields("different prompt")["prompt_sha256"] as? String
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testPromptPreviewIsOptInAndTruncated() {
        let prompt = String(repeating: "x", count: 200)
        let fields = CLIRedact.promptFields(prompt, includePreview: true)
        let preview = fields["prompt_preview"] as? String
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview!.count, 65)
    }

    // MARK: - File sink behaviour

    func testFileIsCreatedLazilyAndAppendedTo() throws {
        let logger = makeLogger()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logger.fileURL!.path))
        logger.info("first")
        logger.info("second")
        XCTAssertEqual(try readLines(logger).count, 2)
    }

    func testRotationKeepsExactlyOnePreviousFile() throws {
        let logger = makeLogger(maxBytes: 512)
        for i in 0..<40 { logger.info("filler.\(i)", ["pad": String(repeating: "y", count: 40)]) }
        let rolled = logger.fileURL!.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled.path), "expected a rolled-over log")
        let size = (try FileManager.default.attributesOfItem(atPath: logger.fileURL!.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(size, 512 * 4, "live log should stay bounded")
    }

    func testLoggingIsSafeFromConcurrentTasks() async throws {
        let logger = makeLogger()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { logger.info("concurrent.\(i)") }
            }
        }
        // Every line must still be individually parsable — interleaved writes
        // that tore a line apart would fail here.
        XCTAssertEqual(try readLines(logger).count, 40)
    }

    // MARK: - Non-JSON values must not lose the entry

    func testNonSerializableValuesDegradeToStringsInsteadOfDroppingTheLine() throws {
        struct Weird { let a = 1 }
        let logger = makeLogger()
        logger.info("odd.values", ["weird": Weird(), "nan": Double.nan, "date": Date(timeIntervalSince1970: 0)])
        let entry = try XCTUnwrap(try readLines(logger).first)
        let fields = try XCTUnwrap(entry["fields"] as? [String: Any])
        XCTAssertNotNil(fields["weird"])
        XCTAssertEqual(fields["nan"] as? String, "nan")
        XCTAssertEqual(fields["date"] as? String, "1970-01-01T00:00:00Z")
    }
}
