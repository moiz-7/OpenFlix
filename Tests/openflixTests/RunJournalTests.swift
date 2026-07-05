import XCTest
@testable import openflix

final class RunJournalTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-journal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Inputs hash stability

    func testInputsHashIsStableAcrossKeyOrder() {
        let a: [String: Any] = ["prompt": "a cat", "model": "veo3", "fanout": 2]
        let b: [String: Any] = ["fanout": 2, "model": "veo3", "prompt": "a cat"]
        XCTAssertEqual(RunJournal.inputsHash(a), RunJournal.inputsHash(b))
    }

    func testInputsHashChangesWhenSpecChanges() {
        let base: [String: Any] = ["prompt": "a cat", "model": "veo3"]
        let changedPrompt: [String: Any] = ["prompt": "a dog", "model": "veo3"]
        let changedModel: [String: Any] = ["prompt": "a cat", "model": "veo2"]
        XCTAssertNotEqual(RunJournal.inputsHash(base), RunJournal.inputsHash(changedPrompt))
        XCTAssertNotEqual(RunJournal.inputsHash(base), RunJournal.inputsHash(changedModel))
    }

    func testInputsHashIsHexSHA256() {
        let hash = RunJournal.inputsHash(["prompt": "x"])
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: - Journal persistence

    func testCreateLoadAndUpsertNode() {
        let journal = RunJournal(directory: tempDir)
        let node = NodeRecord(nodeId: "stage1", inputsHash: "h1", status: "pending",
                              generationId: nil, outputPath: nil, costUSD: nil,
                              startedAt: nil, completedAt: nil)
        _ = journal.create(runId: "run-1", kind: "workflow", name: "test",
                           projectId: "p1", nodes: ["stage1": node])

        var loaded = journal.load(runId: "run-1")
        XCTAssertEqual(loaded?.nodes["stage1"]?.status, "pending")

        // Incremental upsert after node completion
        let done = NodeRecord(nodeId: "stage1", inputsHash: "h1", status: "succeeded",
                              generationId: "gen-9", outputPath: "/tmp/v.mp4",
                              costUSD: 0.42, startedAt: Date(), completedAt: Date())
        journal.upsertNode(runId: "run-1", done)
        loaded = journal.load(runId: "run-1")
        XCTAssertEqual(loaded?.nodes["stage1"]?.status, "succeeded")
        XCTAssertEqual(loaded?.nodes["stage1"]?.generationId, "gen-9")
        XCTAssertEqual(loaded?.nodes["stage1"]?.costUSD ?? 0, 0.42, accuracy: 0.0001)
    }

    func testLoadUnknownRunReturnsNil() {
        let journal = RunJournal(directory: tempDir)
        XCTAssertNil(journal.load(runId: "nope"))
    }

    // MARK: - Resume decisions

    func testResumeSkipsSucceededUnchangedNode() {
        let prior = NodeRecord(nodeId: "n", inputsHash: "abc", status: "succeeded",
                               generationId: "g", outputPath: nil, costUSD: nil,
                               startedAt: nil, completedAt: nil)
        XCTAssertTrue(ResumePolicy.shouldSkip(prior: prior, currentHash: "abc"))
    }

    func testResumeReExecutesChangedFailedPendingOrMissingNodes() {
        let succeeded = NodeRecord(nodeId: "n", inputsHash: "abc", status: "succeeded",
                                   generationId: "g", outputPath: nil, costUSD: nil,
                                   startedAt: nil, completedAt: nil)
        var failed = succeeded; failed.status = "failed"
        var pending = succeeded; pending.status = "pending"

        // Inputs changed → re-execute even though it succeeded
        XCTAssertFalse(ResumePolicy.shouldSkip(prior: succeeded, currentHash: "different"))
        // Failed → re-execute
        XCTAssertFalse(ResumePolicy.shouldSkip(prior: failed, currentHash: "abc"))
        // Pending → re-execute
        XCTAssertFalse(ResumePolicy.shouldSkip(prior: pending, currentHash: "abc"))
        // Never ran → execute
        XCTAssertFalse(ResumePolicy.shouldSkip(prior: nil, currentHash: "abc"))
    }

    func testShotInputsHashCoversWorkflowFields() {
        var shot = Shot(
            id: "s1", sceneId: "sc", name: "stage1", orderIndex: 0,
            prompt: "a cat", negativePrompt: nil, status: .pending,
            provider: "fal", model: "fal-ai/veo3", duration: 5, aspectRatio: nil,
            width: nil, height: nil, referenceImageURL: nil, referenceAssetId: nil,
            extraParams: [:], dependencies: [], generationIds: [],
            selectedGenerationId: nil, routingDecision: nil,
            estimatedCostUSD: nil, actualCostUSD: nil,
            maxRetries: nil, errorMessage: nil, qualityScore: nil,
            evaluationReasoning: nil, evaluationDimensions: nil,
            createdAt: Date(), startedAt: nil, completedAt: nil
        )
        let h1 = RunJournal.inputsHash(for: shot)
        shot.fanout = 4
        let h2 = RunJournal.inputsHash(for: shot)
        XCTAssertNotEqual(h1, h2, "fanout change must change the inputs hash")
        shot.judge = JudgeSpec(keep: 2, minScore: 70)
        let h3 = RunJournal.inputsHash(for: shot)
        XCTAssertNotEqual(h2, h3, "judge change must change the inputs hash")
        // Volatile execution state must NOT affect the hash
        shot.status = .succeeded
        shot.selectedGenerationId = "gen-1"
        shot.actualCostUSD = 1.0
        XCTAssertEqual(h3, RunJournal.inputsHash(for: shot))
    }
}
