import XCTest
@testable import openflix

final class PreferenceRouterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-pref-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture

    /// Canned registry summary matching the /api/preferences/summary contract.
    private let fixtureJSON = """
    {
      "models": [
        {
          "model": "fal-ai/veo3", "provider": "fal",
          "wins": 40, "losses": 10, "win_rate": 0.7885,
          "categories": {
            "cinematic": {"wins": 20, "losses": 2},
            "anime": {"wins": 1, "losses": 1}
          }
        },
        {
          "model": "gen4", "provider": "runway",
          "wins": 30, "losses": 20, "win_rate": 0.5962,
          "categories": {
            "cinematic": {"wins": 3, "losses": 15},
            "anime": {"wins": 9, "losses": 0}
          }
        },
        {
          "model": "video-01", "provider": "minimax",
          "wins": 5, "losses": 45, "win_rate": 0.1154,
          "categories": {}
        }
      ],
      "pairs": [],
      "total_events": 150,
      "generated_at": "2026-07-01T00:00:00Z"
    }
    """

    private func fixtureSummary() throws -> PreferenceSummary {
        try JSONDecoder().decode(PreferenceSummary.self, from: Data(fixtureJSON.utf8))
    }

    // MARK: - Decoding

    func testDecodesContractIgnoringUnknownKeys() throws {
        let summary = try fixtureSummary()
        XCTAssertEqual(summary.models.count, 3)
        XCTAssertEqual(summary.totalEvents, 150)
        XCTAssertEqual(summary.models[0].winRate, 0.7885, accuracy: 0.0001)
        XCTAssertEqual(summary.models[0].categories?["cinematic"]?.wins, 20)
    }

    // MARK: - Selection math

    func testPicksHighestOverallWinRateAmongAvailable() throws {
        let summary = try fixtureSummary()
        let choice = PreferenceRouter.select(
            candidates: [("runway", "gen4"), ("minimax", "video-01")],
            summary: summary,
            category: nil
        )
        // fal has the best rate but is not a candidate (no key) — runway wins.
        XCTAssertEqual(choice?.provider, "runway")
        XCTAssertEqual(choice?.model, "gen4")
        XCTAssertEqual(choice?.winRate ?? 0, 0.5962, accuracy: 0.0001)
        XCTAssertEqual(choice?.usedCategoryStats, false)
    }

    func testCategoryStatsOverrideWhenEnoughEvents() throws {
        let summary = try fixtureSummary()
        // cinematic: fal has 22 events at (20+1)/(22+2)=0.875,
        // runway has 18 events at (3+1)/(18+2)=0.2 — category flips nothing here,
        // but verify the category rate is used, not the overall one.
        let choice = PreferenceRouter.select(
            candidates: [("fal", "fal-ai/veo3"), ("runway", "gen4")],
            summary: summary,
            category: "cinematic"
        )
        XCTAssertEqual(choice?.provider, "fal")
        XCTAssertEqual(choice?.winRate ?? 0, 21.0 / 24.0, accuracy: 0.0001)
        XCTAssertEqual(choice?.usedCategoryStats, true)
        XCTAssertEqual(choice?.categoryEvents, 22)
    }

    func testCategoryFlipsWinnerVersusOverall() throws {
        let summary = try fixtureSummary()
        // anime: runway has 9 events at (9+1)/(9+2)=0.909 — beats fal, whose
        // anime bucket has only 2 events (<5) so fal falls back to 0.7885.
        let choice = PreferenceRouter.select(
            candidates: [("fal", "fal-ai/veo3"), ("runway", "gen4")],
            summary: summary,
            category: "anime"
        )
        XCTAssertEqual(choice?.provider, "runway")
        XCTAssertEqual(choice?.winRate ?? 0, 10.0 / 11.0, accuracy: 0.0001)
        XCTAssertEqual(choice?.usedCategoryStats, true)
    }

    func testCategoryUnderFiveEventsFallsBackToOverall() throws {
        let summary = try fixtureSummary()
        // fal's anime bucket has 2 events (<5): overall win_rate must be used.
        let choice = PreferenceRouter.select(
            candidates: [("fal", "fal-ai/veo3")],
            summary: summary,
            category: "anime"
        )
        XCTAssertEqual(choice?.provider, "fal")
        XCTAssertEqual(choice?.winRate ?? 0, 0.7885, accuracy: 0.0001)
        XCTAssertEqual(choice?.usedCategoryStats, false)
        XCTAssertEqual(choice?.categoryEvents, 2)
    }

    func testUnknownCandidatesAreSkippedAndNilWhenNoneMatch() throws {
        let summary = try fixtureSummary()
        let choice = PreferenceRouter.select(
            candidates: [("luma", "ray-2"), ("kling", "kling-v2")],
            summary: summary,
            category: nil
        )
        XCTAssertNil(choice, "candidates absent from the summary must not be selected")
    }

    // MARK: - Cache TTL

    private func writeCache(_ cache: PreferenceSummaryCache, ageSeconds: TimeInterval) throws {
        cache.save(Data(fixtureJSON.utf8))
        let mtime = Date().addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: cache.cacheURL.path)
    }

    func testFreshCacheWithin24Hours() throws {
        let cache = PreferenceSummaryCache(directory: tempDir)
        try writeCache(cache, ageSeconds: 60 * 60) // 1h old
        XCTAssertTrue(cache.isFresh())
        XCTAssertEqual(cache.load()?.models.count, 3)
    }

    func testStaleCacheAfter24Hours() throws {
        let cache = PreferenceSummaryCache(directory: tempDir)
        try writeCache(cache, ageSeconds: 25 * 60 * 60) // 25h old
        XCTAssertFalse(cache.isFresh())
        // Stale cache must still load — offline fallback depends on it.
        XCTAssertEqual(cache.load()?.models.count, 3)
    }

    func testMissingCacheIsNotFreshAndLoadsNil() {
        let cache = PreferenceSummaryCache(directory: tempDir)
        XCTAssertFalse(cache.isFresh())
        XCTAssertNil(cache.load())
    }

    // MARK: - Offline fallback path (loadSummary, no network reachable)

    func testLoadSummaryFallsBackToStaleCacheWhenRegistryDown() async throws {
        // Point the registry at a closed local port so the fetch fails fast.
        setenv("OPENFLIX_REGISTRY_URL", "http://127.0.0.1:1", 1)
        defer { unsetenv("OPENFLIX_REGISTRY_URL") }

        let cache = PreferenceSummaryCache(directory: tempDir)
        try writeCache(cache, ageSeconds: 48 * 60 * 60) // stale, 48h old

        let (summary, source) = await PreferenceRouter.loadSummary(cache: cache)
        XCTAssertNotNil(summary, "stale cache must be used when the registry is down")
        XCTAssertEqual(source, .staleCache)
        XCTAssertEqual(summary?.models.count, 3)
    }

    func testLoadSummaryReturnsNoneWhenRegistryDownAndNoCache() async {
        setenv("OPENFLIX_REGISTRY_URL", "http://127.0.0.1:1", 1)
        defer { unsetenv("OPENFLIX_REGISTRY_URL") }

        let cache = PreferenceSummaryCache(directory: tempDir)
        let (summary, source) = await PreferenceRouter.loadSummary(cache: cache)
        XCTAssertNil(summary)
        XCTAssertEqual(source, .none)
    }

    func testLoadSummaryUsesFreshCacheWithoutNetwork() async throws {
        // Registry unreachable, but the fresh cache means it is never contacted.
        setenv("OPENFLIX_REGISTRY_URL", "http://127.0.0.1:1", 1)
        defer { unsetenv("OPENFLIX_REGISTRY_URL") }

        let cache = PreferenceSummaryCache(directory: tempDir)
        try writeCache(cache, ageSeconds: 10)

        let (summary, source) = await PreferenceRouter.loadSummary(cache: cache)
        XCTAssertEqual(source, .cache)
        XCTAssertEqual(summary?.totalEvents, 150)
    }
}
