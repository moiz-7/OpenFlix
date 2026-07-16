import XCTest
@testable import openflix

final class DAGResolverTests: XCTestCase {

    private func makeShot(id: String, deps: [String] = [], order: Int = 0,
                          status: Shot.ShotStatus = .pending) -> Shot {
        Shot(id: id, sceneId: "scene-1", name: id, orderIndex: order, prompt: "p",
             negativePrompt: nil, status: status, provider: nil, model: nil,
             duration: nil, aspectRatio: nil, width: nil, height: nil,
             referenceImageURL: nil, referenceAssetId: nil, extraParams: [:],
             dependencies: deps, generationIds: [], selectedGenerationId: nil,
             routingDecision: nil, estimatedCostUSD: nil, actualCostUSD: nil,
             maxRetries: nil, errorMessage: nil, qualityScore: nil,
             evaluationReasoning: nil, evaluationDimensions: nil,
             createdAt: Date(), startedAt: nil, completedAt: nil)
    }

    func testLinearChainProducesOneWavePerShot() throws {
        let shots = [
            makeShot(id: "a"),
            makeShot(id: "b", deps: ["a"], order: 1),
            makeShot(id: "c", deps: ["b"], order: 2),
        ]
        let waves = try DAGResolver.resolve(shots: shots)
        XCTAssertEqual(waves.count, 3)
        XCTAssertEqual(waves.map { $0.map(\.id) }, [["a"], ["b"], ["c"]])
    }

    func testDiamondDependencyGroupsParallelWaves() throws {
        // a -> (b, c) -> d
        let shots = [
            makeShot(id: "a"),
            makeShot(id: "b", deps: ["a"], order: 1),
            makeShot(id: "c", deps: ["a"], order: 2),
            makeShot(id: "d", deps: ["b", "c"], order: 3),
        ]
        let waves = try DAGResolver.resolve(shots: shots)
        XCTAssertEqual(waves.count, 3)
        XCTAssertEqual(waves[0].map(\.id), ["a"])
        XCTAssertEqual(Set(waves[1].map(\.id)), ["b", "c"])
        XCTAssertEqual(waves[2].map(\.id), ["d"])
    }

    func testCycleDetectionThrows() {
        let shots = [
            makeShot(id: "a", deps: ["c"]),
            makeShot(id: "b", deps: ["a"], order: 1),
            makeShot(id: "c", deps: ["b"], order: 2),
        ]
        XCTAssertThrowsError(try DAGResolver.resolve(shots: shots))
        XCTAssertThrowsError(try DAGResolver.validateNoCycles(shots: shots))
    }

    func testSelfCycleThrows() {
        let shots = [makeShot(id: "a", deps: ["a"])]
        XCTAssertThrowsError(try DAGResolver.resolve(shots: shots))
    }

    func testDuplicateShotIdsDoNotCrash() throws {
        // Malformed input with duplicate ids must surface as a structured error
        // upstream, never trap the process in Dictionary(uniqueKeysWithValues:).
        let shots = [makeShot(id: "a"), makeShot(id: "a", order: 1)]
        XCTAssertNoThrow(try DAGResolver.resolve(shots: shots))
    }

    func testFirstWaveSortedByOrderIndex() throws {
        // Root shots (no deps) must dispatch in orderIndex order, like every
        // later wave — previously the first wave used raw input order.
        let shots = [
            makeShot(id: "c", order: 2),
            makeShot(id: "a", order: 0),
            makeShot(id: "b", order: 1),
        ]
        let waves = try DAGResolver.resolve(shots: shots)
        XCTAssertEqual(waves.first?.map(\.id), ["a", "b", "c"])
    }

    func testReadyShotsOnlyIncludesPendingWithSatisfiedDeps() {
        let shots = [
            makeShot(id: "a", status: .succeeded),
            makeShot(id: "b", deps: ["a"], order: 1),            // ready
            makeShot(id: "c", deps: ["b"], order: 2),            // blocked
            makeShot(id: "d", deps: ["a"], order: 3, status: .processing), // running
            makeShot(id: "e", status: .skipped),
            makeShot(id: "f", deps: ["e"], order: 4),            // ready (skipped counts)
        ]
        let ready = DAGResolver.readyShots(allShots: shots)
        XCTAssertEqual(Set(ready.map(\.id)), ["b", "f"])
    }
}
