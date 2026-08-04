import XCTest
@testable import openflix

final class PreferenceVoteClientTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-vote-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func generation(id: String, provider: String, model: String) -> CLIGeneration {
        CLIGeneration(
            id: id, status: .succeeded, provider: provider, model: model,
            prompt: "test prompt", negativePrompt: nil, aspectRatio: nil,
            widthPx: nil, heightPx: nil, durationSeconds: 4,
            remoteTaskId: nil, statusURL: nil, remoteVideoURL: nil, localPath: nil,
            estimatedCostUSD: nil, actualCostUSD: nil, errorMessage: nil,
            retryCount: 0, projectId: nil, shotId: nil,
            createdAt: Date(), submittedAt: nil, completedAt: nil
        )
    }

    // MARK: - Client ID

    func testClientIdIsStableAndAnonymous() {
        let first = PreferenceVoteClient.clientId(directory: tempDir)
        let second = PreferenceVoteClient.clientId(directory: tempDir)
        XCTAssertEqual(first, second, "client_id must be generated once and reused")
        XCTAssertNotNil(UUID(uuidString: first), "client_id must be a random UUID, nothing identity-tied")

        // A different directory (fresh install) gets a different id.
        let otherDir = tempDir.appendingPathComponent("other")
        try? FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        XCTAssertNotEqual(PreferenceVoteClient.clientId(directory: otherDir), first)
    }

    // MARK: - Event contract

    func testBuildEventMatchesRegistryContract() {
        let winner = generation(id: "w1", provider: "kling", model: "kling-v2.6-std")
        let loser = generation(id: "l1", provider: "fal", model: "fal-ai/veo3")

        let event = PreferenceVoteClient.buildEvent(
            winner: winner, loser: loser,
            category: "cinematic", context: "vote",
            clientId: "client-123", eventId: "event-456"
        )

        XCTAssertEqual(event["winner_model"] as? String, "kling-v2.6-std")
        XCTAssertEqual(event["loser_model"] as? String, "fal-ai/veo3")
        XCTAssertEqual(event["winner_provider"] as? String, "kling")
        XCTAssertEqual(event["loser_provider"] as? String, "fal")
        XCTAssertEqual(event["category"] as? String, "cinematic")
        XCTAssertEqual(event["source"] as? String, "cli")
        XCTAssertEqual(event["context"] as? String, "vote")
        XCTAssertEqual(event["client_id"] as? String, "client-123")
        XCTAssertEqual(event["event_id"] as? String, "event-456")
        XCTAssertEqual(event.keys.count, 9, "Exactly the contract fields — no prompt, no paths, nothing identifying")

        // Prompt text must never leak into the payload.
        XCTAssertFalse(event.values.contains { ($0 as? String)?.contains("test prompt") == true })
    }

    func testBuildEventOmitsEmptyCategory() {
        let winner = generation(id: "w1", provider: "kling", model: "m1")
        let loser = generation(id: "l1", provider: "fal", model: "m2")
        let event = PreferenceVoteClient.buildEvent(
            winner: winner, loser: loser, category: nil, context: "vote",
            clientId: "c", eventId: "e"
        )
        XCTAssertNil(event["category"])
        XCTAssertEqual(event.keys.count, 8)
    }

    func testEventIdsAreUniquePerCall() {
        let winner = generation(id: "w1", provider: "kling", model: "m1")
        let loser = generation(id: "l1", provider: "fal", model: "m2")
        let a = PreferenceVoteClient.buildEvent(winner: winner, loser: loser,
                                                category: nil, context: "vote", clientId: "c")
        let b = PreferenceVoteClient.buildEvent(winner: winner, loser: loser,
                                                category: nil, context: "vote", clientId: "c")
        XCTAssertNotEqual(a["event_id"] as? String, b["event_id"] as? String,
                          "Each vote must carry its own dedup key")
    }
}
