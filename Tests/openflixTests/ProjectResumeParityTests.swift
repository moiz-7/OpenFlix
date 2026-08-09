import XCTest
@testable import openflix

/// `openflix project run --resume` and the MCP `project_run` tool must repair
/// the *same* set of shots.
///
/// They did not. `ProjectRunCommand` carried a hand-rolled copy of
/// `DAGExecutor.resetStaleShots` that had drifted from it: it reset
/// `.dispatched`, `.processing` and `.failed`, but not `.evaluating`, and not
/// the `.skipped` shots the executor's drain marks with
/// `blockedByUpstreamMessage` when an upstream shot fails.
///
/// The consequence was silent and expensive: shot 3 of 7 fails, the drain skips
/// 4–7, `--resume` retries shot 3 alone, and the run reports **success** with
/// four shots that were never made. These tests pin the repair set so the two
/// entry points cannot drift again.
final class ProjectResumeParityTests: XCTestCase {

    private var projectId: String!

    override func setUp() {
        super.setUp()
        projectId = "test-resume-\(UUID().uuidString)"
    }

    override func tearDown() {
        ProjectStore.shared.delete(projectId)
        super.tearDown()
    }

    private func statuses() -> [String: Shot.ShotStatus] {
        var out: [String: Shot.ShotStatus] = [:]
        for scene in ProjectStore.shared.get(projectId)?.scenes ?? [] {
            for shot in scene.shots { out[shot.id] = shot.status }
        }
        return out
    }

    /// The exact shape of the bug: an upstream failure, a drained downstream,
    /// and a resume that used to leave the downstream dead.
    func testResumeRepairsShotsSkippedByTheUpstreamDrain() {
        var blocked = ProjectFixtures.shot(id: "b", deps: ["a"], order: 1, status: .skipped)
        blocked.errorMessage = DAGExecutor.blockedByUpstreamMessage
        let project = ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", order: 0, status: .failed),
            blocked,
        ])
        ProjectStore.shared.save(project)

        let reset = DAGExecutor.resetStaleShots(projectId: projectId)

        XCTAssertEqual(reset, 2, "both the failed shot and the shot it blocked must come back")
        XCTAssertEqual(statuses()["a"], .pending)
        XCTAssertEqual(statuses()["b"], .pending,
                       """
                       A shot skipped only because its upstream failed was left dead by resume, \
                       and the run then reported success without it.
                       """)
    }

    func testResumeRepairsEveryInFlightStatus() {
        let project = ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "dispatched", order: 0, status: .dispatched),
            ProjectFixtures.shot(id: "processing", order: 1, status: .processing),
            ProjectFixtures.shot(id: "evaluating", order: 2, status: .evaluating),
            ProjectFixtures.shot(id: "failed", order: 3, status: .failed),
        ])
        ProjectStore.shared.save(project)

        XCTAssertEqual(DAGExecutor.resetStaleShots(projectId: projectId), 4)
        for id in ["dispatched", "processing", "evaluating", "failed"] {
            XCTAssertEqual(statuses()[id], .pending, "\(id) was left behind by resume")
        }
    }

    /// Resume must not undo finished work — re-running a completed shot bills
    /// for it a second time.
    func testResumeLeavesCompletedAndPendingShotsAlone() {
        let project = ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "done", order: 0, status: .succeeded),
            ProjectFixtures.shot(id: "waiting", order: 1, status: .pending),
        ])
        ProjectStore.shared.save(project)

        XCTAssertEqual(DAGExecutor.resetStaleShots(projectId: projectId), 0)
        XCTAssertEqual(statuses()["done"], .succeeded, "resume re-ran a completed shot, billing it twice")
        XCTAssertEqual(statuses()["waiting"], .pending)
    }

    /// A shot the *user* skipped is not a shot the drain skipped. Only the
    /// drain's marker means "blocked, retry me".
    func testADeliberatelySkippedShotIsNotResurrected() {
        var userSkipped = ProjectFixtures.shot(id: "s", order: 0, status: .skipped)
        userSkipped.errorMessage = nil
        ProjectStore.shared.save(ProjectFixtures.project(id: projectId, shots: [userSkipped]))

        XCTAssertEqual(DAGExecutor.resetStaleShots(projectId: projectId), 0)
        XCTAssertEqual(statuses()["s"], .skipped,
                       "a shot skipped for its own reasons was resurrected by resume")
    }

    /// Looking up a project that does not exist must not create anything.
    /// `withFileLock` used to `mkdir` + `O_CREAT` before checking, so every bad
    /// id left `~/.openflix/projects/<id>/project.lock` behind — one directory
    /// per guess, and `project_run` is now a tool an agent can call in a loop.
    func testLookingUpAMissingProjectLeavesNoDirectoryBehind() {
        let ghost = "test-ghost-\(UUID().uuidString)"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix/projects/\(ghost)")

        XCTAssertNil(ProjectStore.shared.get(ghost))

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "a failed lookup created \(dir.path)")
    }
}
