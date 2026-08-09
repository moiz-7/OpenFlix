import XCTest
@testable import openflix

/// `DAGExecutor` is the biggest untested file in the CLI and the one that
/// orchestrates spend across a whole workflow graph. Every test here stops
/// short of `executeSingleShot`, so **nothing in this file can reach a
/// provider, a keychain entry or the network** — the assertions are about the
/// order in which the money gates run, the status math, and the loop's
/// termination guarantees.
///
/// Where a shot has to reach a terminal state, it does so through a path that
/// refuses locally: "no provider/model configured" (manual routing, no
/// defaults) or "cost budget exceeded". Both return before dispatch.
final class DAGExecutorTests: XCTestCase {

    private var projectId: String!

    override func setUp() {
        super.setUp()
        projectId = "openflix-test-dag-\(UUID().uuidString)"
    }

    override func tearDown() {
        ProjectStore.shared.delete(projectId)
        super.tearDown()
    }

    // MARK: - Helpers

    private struct TimedOut: Error {}

    /// Race `body` against a deadline. A DAG dispatch loop that fails to make
    /// progress sleeps for 1s and retries forever, so a regression in the
    /// termination guards would otherwise hang the whole suite instead of
    /// failing one test.
    private func withDeadline<T: Sendable>(
        _ seconds: Double, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func save(_ project: Project) {
        ProjectStore.shared.save(project)
    }

    private func reload() -> Project? {
        ProjectStore.shared.get(projectId)
    }

    private func shotNamed(_ id: String) -> Shot? {
        reload()?.allShots.first { $0.id == id }
    }

    // MARK: - Preconditions

    func testExecuteThrowsWhenProjectDoesNotExist() async {
        let executor = DAGExecutor(projectId: "openflix-test-missing-\(UUID().uuidString)")
        do {
            _ = try await executor.execute()
            XCTFail("expected generationNotFound for a project id that was never saved")
        } catch let error as OpenFlixError {
            guard case .generationNotFound = error else {
                return XCTFail("expected .generationNotFound, got \(error)")
            }
        } catch {
            XCTFail("expected OpenFlixError, got \(error)")
        }
    }

    func testCyclicGraphThrowsBeforeAnyShotIsDispatched() async throws {
        let shots = [
            ProjectFixtures.shot(id: "a", deps: ["b"]),
            ProjectFixtures.shot(id: "b", deps: ["a"], order: 1),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let executor = DAGExecutor(projectId: projectId)
        do {
            _ = try await executor.execute()
            XCTFail("expected the cycle to be refused")
        } catch {
            // Validation happens before the project is even marked running, so
            // no shot may have left .pending.
            let statuses = Set((reload()?.allShots ?? []).map(\.status))
            XCTAssertEqual(statuses, [.pending])
        }
    }

    // MARK: - Status math

    func testEmptyProjectCompletesImmediatelyAsSucceeded() async throws {
        save(ProjectFixtures.project(id: projectId, shots: []))
        let result = try await withDeadline(10) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.totalActualCostUSD ?? -1, 0, accuracy: 0.0001)
        XCTAssertNotNil(result.completedAt)
    }

    func testAllShotsFailingReportsFailedNotSucceeded() async throws {
        // Regression guard: the old catch-all `else -> .succeeded` reported a
        // run in which every shot failed as a success.
        let shots = [
            ProjectFixtures.shot(id: "a"),
            ProjectFixtures.shot(id: "b", order: 1),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let result = try await withDeadline(15) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.allShots.filter { $0.status == .failed }.count, 2)
    }

    func testMixedOutcomeReportsPartialFailure() async throws {
        let shots = [
            ProjectFixtures.shot(id: "done", status: .succeeded, actualCostUSD: 0.25),
            ProjectFixtures.shot(id: "doomed", order: 1),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let result = try await withDeadline(15) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(result.status, .partialFailure)
    }

    func testAlreadyTerminalProjectReportsSucceededAndSumsBilledCost() async throws {
        let shots = [
            ProjectFixtures.shot(id: "a", status: .succeeded, actualCostUSD: 0.30),
            ProjectFixtures.shot(id: "b", order: 1, status: .succeeded, actualCostUSD: 0.12),
            ProjectFixtures.shot(id: "c", order: 2, status: .skipped),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let result = try await withDeadline(10) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.totalActualCostUSD ?? -1, 0.42, accuracy: 0.0001)
    }

    // MARK: - Refusal messages (the local, unbilled failure paths)

    func testManualRoutingWithoutProviderFailsTheShotWithAnActionableMessage() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [ProjectFixtures.shot(id: "a")]))

        _ = try await withDeadline(10) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        let shot = shotNamed("a")
        XCTAssertEqual(shot?.status, .failed)
        XCTAssertEqual(shot?.errorMessage,
                       "No provider/model specified and no routing strategy configured")
        XCTAssertNotNil(shot?.completedAt)
    }

    // MARK: - Budget gate ordering (the money path)

    func testBudgetGateRefusesDispatchWhenBilledSpendAlreadyExceedsBudget() async throws {
        // One shot already billed above the budget; the pending one must never
        // be dispatched.
        let shots = [
            ProjectFixtures.shot(id: "billed", status: .succeeded, actualCostUSD: 5.0),
            ProjectFixtures.shot(id: "next", order: 1,
                                 provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots, costBudgetUSD: 1.0))

        _ = try await withDeadline(15) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        let blocked = shotNamed("next")
        XCTAssertEqual(blocked?.status, .failed)
        XCTAssertTrue(blocked?.errorMessage?.hasPrefix("Cost budget exceeded") == true,
                      "got: \(blocked?.errorMessage ?? "nil")")
    }

    func testBudgetGateRunsBeforeTheCostReservationIsWritten() async throws {
        // Ordering matters: the reservation (`estimatedCostUSD`) is written
        // immediately before dispatch. A shot refused by the budget gate must
        // therefore carry no reservation at all — if it does, the gate moved
        // below the reservation and a refused shot is inflating the next
        // shot's in-flight total.
        let shots = [
            ProjectFixtures.shot(id: "billed", status: .succeeded, actualCostUSD: 2.0),
            ProjectFixtures.shot(id: "next", order: 1,
                                 provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots, costBudgetUSD: 0.5))

        _ = try await withDeadline(15) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertNil(shotNamed("next")?.estimatedCostUSD)
    }

    func testZeroBudgetRefusesEveryShot() async throws {
        // `costBudgetUSD = 0` is non-nil, so the gate applies: 0 >= 0.
        // A zero budget must mean "spend nothing", not "no budget configured".
        let shots = [
            ProjectFixtures.shot(id: "a",
                                 provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots, costBudgetUSD: 0))

        let result = try await withDeadline(10) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(shotNamed("a")?.errorMessage?.contains("Cost budget exceeded") == true)
    }

    // MARK: - Orphan drain

    func testShotBlockedByUpstreamFailureReachesATerminalState() async throws {
        // `readyShots` only counts succeeded/skipped dependencies, so a shot
        // downstream of a failure can never become ready. Without the drain it
        // sits .pending forever and is miscounted as "not failed".
        let shots = [
            ProjectFixtures.shot(id: "a"),
            ProjectFixtures.shot(id: "b", deps: ["a"], order: 1),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let result = try await withDeadline(15) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(shotNamed("a")?.status, .failed)
        XCTAssertEqual(shotNamed("b")?.status, .skipped)
        XCTAssertEqual(shotNamed("b")?.errorMessage, "Blocked by upstream failure")
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.allShots.contains { $0.status == .pending },
                       "every shot must reach a terminal state")
    }

    func testDrainDoesNotTouchShotsWhoseDependenciesAllSucceeded() async throws {
        let shots = [
            ProjectFixtures.shot(id: "a", status: .succeeded),
            ProjectFixtures.shot(id: "b", deps: ["a"], order: 1, status: .succeeded),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let result = try await withDeadline(10) { [projectId] in
            try await DAGExecutor(projectId: projectId!).execute()
        }
        XCTAssertEqual(result.allShots.filter { $0.status == .skipped }.count, 0)
        XCTAssertEqual(result.status, .succeeded)
    }

    // MARK: - Cancellation / pause

    func testCancelBeforeExecuteSkipsDispatchAndReportsCancelled() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [ProjectFixtures.shot(id: "a")]))
        let executor = DAGExecutor(projectId: projectId)
        await executor.cancel()

        let result = try await withDeadline(10) { try await executor.execute() }
        XCTAssertEqual(result.status, .cancelled)
        // Cancelled means "stop", not "rewrite history": pending shots stay
        // pending rather than being drained to .skipped.
        XCTAssertEqual(shotNamed("a")?.status, .pending)
    }

    func testPauseReportsPausedRatherThanCancelled() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [ProjectFixtures.shot(id: "a")]))
        let executor = DAGExecutor(projectId: projectId)
        await executor.pause()

        let result = try await withDeadline(10) { try await executor.execute() }
        XCTAssertEqual(result.status, .paused)
    }

    // MARK: - Termination guarantees

    func testZeroMaxConcurrencyIsClampedInsteadOfHangingTheDispatchLoop() async throws {
        // maxConcurrency 0 => slotsAvailable = max(0, 0 - 0) = 0 => nothing is
        // ever dispatched and the loop sleeps forever. A spec or flag value of
        // 0 is a config-driven hang, so the initialiser clamps to >= 1.
        let shots = [
            ProjectFixtures.shot(id: "a"),
            ProjectFixtures.shot(id: "b", order: 1),
        ]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        let result = try await withDeadline(20) { [projectId] in
            try await DAGExecutor(projectId: projectId!, maxConcurrency: 0).execute()
        }
        XCTAssertEqual(result.allShots.filter { $0.status == .failed }.count, 2)
    }

    func testNegativeMaxConcurrencyIsAlsoClamped() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [ProjectFixtures.shot(id: "a")]))
        let result = try await withDeadline(20) { [projectId] in
            try await DAGExecutor(projectId: projectId!, maxConcurrency: -8).execute()
        }
        XCTAssertEqual(result.status, .failed)
    }

    func testGraphWithAnUnknownDependencyIdTerminatesRatherThanSpinning() async throws {
        // A dependency naming a shot that does not exist can never be
        // satisfied. Resolution treats it as a cycle (nothing reaches
        // in-degree 0), which is a loud refusal rather than a silent hang.
        let shots = [ProjectFixtures.shot(id: "a", deps: ["ghost"])]
        save(ProjectFixtures.project(id: projectId, shots: shots))

        do {
            _ = try await withDeadline(10) { [projectId] in
                try await DAGExecutor(projectId: projectId!).execute()
            }
            XCTFail("expected an unsatisfiable dependency to be refused")
        } catch is TimedOut {
            XCTFail("unsatisfiable dependency caused the dispatch loop to spin")
        } catch {
            // Structured refusal — acceptable.
        }
    }
}
