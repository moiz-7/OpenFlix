import XCTest
@testable import openflix

final class HookRunnerTests: XCTestCase {

    private var tempDir: URL!
    private var savedHooksDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-hooks-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedHooksDir = HookRunner.hooksDirectory
        HookRunner.hooksDirectory = tempDir
    }

    override func tearDownWithError() throws {
        HookRunner.hooksDirectory = savedHooksDir
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeHook(_ name: String, script: String) throws {
        let url = tempDir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Pre-generate

    func testMissingPreHookIsNoOp() {
        XCTAssertNoThrow(try HookRunner.runPreGenerate(spec: ["prompt": "x"]))
    }

    func testNonExecutablePreHookIsIgnored() throws {
        let url = tempDir.appendingPathComponent("pre-generate")
        try "exit 1".write(to: url, atomically: true, encoding: .utf8)  // not chmod +x
        XCTAssertNoThrow(try HookRunner.runPreGenerate(spec: ["prompt": "x"]))
    }

    func testPreHookExitZeroPasses() throws {
        try writeHook("pre-generate", script: "cat > /dev/null; exit 0")
        XCTAssertNoThrow(try HookRunner.runPreGenerate(spec: ["prompt": "x"]))
    }

    func testPreHookNonzeroExitVetoesWithStderrDetail() throws {
        try writeHook("pre-generate", script: "cat > /dev/null; echo 'prompt too spicy' >&2; exit 1")
        XCTAssertThrowsError(try HookRunner.runPreGenerate(spec: ["prompt": "x"])) { error in
            guard let e = error as? OpenFlixError else { return XCTFail("wrong error type") }
            XCTAssertEqual(e.code, "hook_veto")
            XCTAssertTrue((e.errorDescription ?? "").contains("prompt too spicy"),
                          "hook stderr must appear in the veto detail (got: \(e.errorDescription ?? ""))")
        }
    }

    func testPreHookReceivesSpecJSONOnStdin() throws {
        let marker = tempDir.appendingPathComponent("received.json")
        try writeHook("pre-generate", script: "cat > '\(marker.path)'; exit 0")
        try HookRunner.runPreGenerate(spec: ["prompt": "hello hook", "provider": "fal"])
        let received = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(received.contains("hello hook"))
        XCTAssertTrue(received.contains("fal"))
    }

    // MARK: - Post-generate

    func testPostHookNonzeroExitNeverThrows() throws {
        try writeHook("post-generate", script: "cat > /dev/null; exit 7")
        // Must not throw or crash — exit code is only logged.
        HookRunner.runPostGenerate(result: ["id": "g1", "status": "succeeded"])
    }

    func testMissingPostHookIsNoOp() {
        HookRunner.runPostGenerate(result: ["id": "g1"])
    }
}
