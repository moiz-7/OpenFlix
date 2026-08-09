import XCTest
@testable import openflix

/// `ScatterGatherExecutor` is the fan-out that turns one shot into N billed
/// generations. Its historic defect class is *empty input into a windowed
/// index*: `scatter([])` computed `window = max(1, min(8, 0)) = 1` and then
/// read `targets[0]` on an empty array, aborting the whole run.
///
/// Every test here uses either an empty target list (returns before any
/// submission) or pure selection helpers, so nothing reaches a provider.
final class ScatterGatherTests: XCTestCase {

    private func shot(duration: Double? = nil, referenceImageURL: String? = nil) -> Shot {
        var s = ProjectFixtures.shot(id: "s", duration: duration)
        s.referenceImageURL = referenceImageURL
        return s
    }

    private func result(
        id: String, status: String, cost: Double? = nil, score: Double? = nil
    ) -> ScatterResult {
        ScatterResult(generationId: id, provider: "p", model: "m", status: status,
                      videoURL: nil, costUSD: cost, durationMs: nil,
                      errorMessage: status == "failed" ? "boom" : nil,
                      qualityScore: score, evaluationResult: nil)
    }

    private var noopOptions: GenerationEngine.Options {
        GenerationEngine.Options(pollInterval: 1, timeout: 1, outputURL: nil,
                                 stream: false, skipDownload: true, maxRetries: 0)
    }

    // MARK: - The empty-target abort

    func testScatterWithNoTargetsReturnsEmptyInsteadOfIndexingPastTheEnd() async {
        // Regression guard for the `targets[0]` abort. `ProviderRouter
        // .scatterTargets` legitimately returns [] when no keys are configured
        // or the capability filter empties the list, and the pinned scatter
        // path reaches here without the guard the routed path gets.
        let results = await ScatterGatherExecutor.scatter(
            shot: shot(), targets: [], apiKey: nil, options: noopOptions
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testScatterWindowIsAtLeastOneSoThePrimingLoopAlwaysTerminates() {
        // `window = max(1, min(maxConcurrentScatter, targets.count))` only
        // bounds correctly while the cap is positive; a zero or negative cap
        // would make the priming loop dispatch nothing and the refill loop
        // never run.
        XCTAssertGreaterThan(ScatterGatherExecutor.maxConcurrentScatter, 0)
    }

    func testRouterReturnsNoTargetsWhenNoProvidersAreConfigured() {
        // This is the input that used to reach `targets[0]`.
        let targets = ProviderRouter.scatterTargets(
            shot: shot(), count: 4, availableProviders: []
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testRouterReturnsNoTargetsWhenTheDurationFilterEmptiesTheCandidateList() {
        // No model advertises a 10-hour max duration, so the filter empties.
        let targets = ProviderRouter.scatterTargets(
            shot: shot(duration: 36_000), count: 4,
            availableProviders: ProviderRegistry.shared.allModels.map(\.providerId)
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testRouterIsBoundedAndNeverTrapsOnDegenerateCounts() {
        let available = ProviderRegistry.shared.allModels.map(\.providerId)
        for count in [-100, -1, 0, 1] {
            let targets = ProviderRouter.scatterTargets(
                shot: shot(), count: count, availableProviders: available
            )
            XCTAssertLessThanOrEqual(targets.count, max(1, count),
                                     "count \(count) produced \(targets.count) targets")
        }
    }

    func testRouterNeverExceedsTheRequestedCount() {
        let available = ProviderRegistry.shared.allModels.map(\.providerId)
        for count in [2, 3, 5, 8] {
            let targets = ProviderRouter.scatterTargets(
                shot: shot(), count: count, availableProviders: available
            )
            XCTAssertLessThanOrEqual(targets.count, count)
        }
    }

    func testRouterPrefersProviderDiversityBeforeRepeatingAProvider() throws {
        let available = ProviderRegistry.shared.allModels.map(\.providerId)
        guard Set(available).count >= 2 else {
            throw XCTSkip("registry has fewer than two providers")
        }
        let targets = ProviderRouter.scatterTargets(
            shot: shot(), count: 2, availableProviders: available
        )
        XCTAssertEqual(Set(targets.map(\.provider)).count, targets.count,
                       "the first pass must emit one model per provider")
    }

    // MARK: - Selection

    func testSelectBestOnEmptyResultsIsNil() {
        XCTAssertNil(ScatterGatherExecutor.selectBest([]))
    }

    func testSelectBestSkipsFailedResults() {
        let picked = ScatterGatherExecutor.selectBest([
            result(id: "", status: "failed"),
            result(id: "g2", status: "succeeded"),
        ])
        XCTAssertEqual(picked?.generationId, "g2")
    }

    func testSelectBestIsNilWhenEveryTargetFailed() {
        let picked = ScatterGatherExecutor.selectBest([
            result(id: "", status: "failed"),
            result(id: "", status: "failed"),
        ])
        XCTAssertNil(picked)
    }

    func testQualityAwareSelectBestOnEmptyResultsIsNil() async {
        let picked = await ScatterGatherExecutor.selectBest([], qualityConfig: QualityConfig())
        XCTAssertNil(picked)
    }

    func testQualityAwareSelectBestIsNilWhenEveryTargetFailed() async {
        let picked = await ScatterGatherExecutor.selectBest(
            [result(id: "", status: "failed")], qualityConfig: QualityConfig()
        )
        XCTAssertNil(picked)
    }

    func testQualityAwareSelectBestFallsBackToTheFirstSucceededWhenNothingScored() async {
        // Generation ids that are not in the store cannot be evaluated, so no
        // candidate gets a score — the fallback must still return a video
        // rather than discarding paid work.
        let picked = await ScatterGatherExecutor.selectBest([
            result(id: "openflix-test-absent-1", status: "succeeded"),
            result(id: "openflix-test-absent-2", status: "succeeded"),
        ], qualityConfig: QualityConfig())
        XCTAssertEqual(picked?.generationId, "openflix-test-absent-1")
    }

    // MARK: - Judge selection (the fanout keep/drop rule)

    func testJudgeKeepsHighestScoreFirst() {
        let kept = JudgeSelector.selectTopK([
            .init(id: "low", score: 10),
            .init(id: "high", score: 90),
            .init(id: "mid", score: 50),
        ], keep: 2, minScore: nil)
        XCTAssertEqual(kept.map(\.id), ["high", "mid"])
    }

    func testJudgeWithZeroOrNegativeKeepReturnsNothingRatherThanIndexing() {
        // `keep` comes from user-authored JSON. A `prefix(negative)` traps.
        XCTAssertTrue(JudgeSelector.selectTopK([.init(id: "a", score: 1)], keep: 0, minScore: nil).isEmpty)
        XCTAssertTrue(JudgeSelector.selectTopK([.init(id: "a", score: 1)], keep: -5, minScore: nil).isEmpty)
    }

    func testJudgeOnEmptyCandidateListIsEmpty() {
        XCTAssertTrue(JudgeSelector.selectTopK([], keep: 3, minScore: 50).isEmpty)
    }

    func testJudgeDropsEverythingBelowMinScore() {
        let kept = JudgeSelector.selectTopK([
            .init(id: "a", score: 10),
            .init(id: "b", score: 20),
        ], keep: 2, minScore: 50)
        XCTAssertTrue(kept.isEmpty, "a min_score nobody met must reject, not silently keep")
    }

    func testJudgeFallsBackToUnscoredCandidatesOnlyWhenNothingWasScored() {
        // Evaluator unavailable: keeping the first K unfiltered is better than
        // discarding N billed generations.
        let kept = JudgeSelector.selectTopK([
            .init(id: "a", score: nil),
            .init(id: "b", score: nil),
        ], keep: 1, minScore: 99)
        XCTAssertEqual(kept.map(\.id), ["a"])
    }

    func testJudgeIgnoresUnscoredCandidatesWhenAtLeastOneWasScored() {
        let kept = JudgeSelector.selectTopK([
            .init(id: "unscored", score: nil),
            .init(id: "scored", score: 70),
        ], keep: 2, minScore: nil)
        XCTAssertEqual(kept.map(\.id), ["scored"])
    }

    func testFanoutCeilingIsPositiveAndBounded() {
        // `executeFanoutShot` clamps a project shot's arbitrary `fanout` with
        // `max(1, min(raw, maxFanout))` before `Array(repeating:count:)` — one
        // eager allocation and one billed generation per element.
        XCTAssertGreaterThan(WorkflowSpec.maxFanout, 0)
        XCTAssertLessThanOrEqual(WorkflowSpec.maxFanout, 64)
        for raw in [Int.min, -1, 0, 1, 5, WorkflowSpec.maxFanout, Int.max] {
            let clamped = max(1, min(raw, WorkflowSpec.maxFanout))
            XCTAssertGreaterThanOrEqual(clamped, 1)
            XCTAssertLessThanOrEqual(clamped, WorkflowSpec.maxFanout)
        }
    }
}
