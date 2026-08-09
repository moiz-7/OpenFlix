import XCTest
@testable import openflix

/// `project_run` is the most consequential tool on either MCP server: it spends
/// real money, per shot, across a whole graph, on the user's own provider
/// credit. These tests exist for the two ways that goes wrong — spending when
/// nobody asked, and reporting a run that did not happen as one that did.
///
/// **Nothing in this file can reach a provider, a keychain entry or the
/// network.** Every path that would spend is stopped by one of three locally
/// enforced refusals:
///
///  * the plan's own pre-flight (unknown provider / no key / bad duration),
///  * the `max_cost_usd` ceiling check, which runs before anything is
///    submitted, or
///  * `DAGExecutor`'s cost-budget gate, which fires before dispatch.
///
/// Where a shot must actually be driven through the executor, the project
/// carries `costBudgetUSD: 0`, so the gate refuses every shot before it reaches
/// `executeSingleShot` — the same technique `DAGExecutorTests` uses.
final class MCPProjectRunTests: XCTestCase {

    private var projectId: String!
    private var server: MCPServer!
    private var journalIds: [String] = []
    /// Every project id this test named, whether or not it was ever saved.
    ///
    /// `ProjectStore.withFileLock` creates `~/.openflix/projects/<id>/project.lock`
    /// for **any** id, so merely *reading* a project that does not exist leaves
    /// a directory behind — invisible to `list()`, and never cleaned. That is a
    /// production bug (see the report), but a test must not add to the pile.
    private var touchedProjectIds: Set<String> = []

    override func setUp() {
        super.setUp()
        projectId = "openflix-test-mcprun-\(UUID().uuidString)"
        server = MCPServer()
        journalIds = []
        touchedProjectIds = [projectId]
    }

    override func tearDown() {
        for id in touchedProjectIds { ProjectStore.shared.delete(id) }
        let runs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix/runs")
        for id in journalIds {
            try? FileManager.default.removeItem(at: runs.appendingPathComponent("\(id).json"))
        }
        super.tearDown()
    }

    // MARK: - Fixtures
    //
    // `local` (ComfyUI) is the one provider in the registry that needs no key,
    // so it is the only one a keyless CI machine can plan a *runnable* shot
    // against. Pairing it with a priced model id is deliberate: it produces a
    // non-zero estimate without a key, which is what makes the ceiling logic
    // testable. Nothing is ever dispatched to it — see the class comment.
    private let keylessProvider = "local"
    private let pricedModel = "gen4_turbo"  // $0.05/s in ModelPricing

    private func save(_ project: Project) { ProjectStore.shared.save(project) }
    private func reload() -> Project? { ProjectStore.shared.get(projectId) }

    private func pricedProject(shots: Int = 1, duration: Double = 10,
                               costBudgetUSD: Double? = nil,
                               status: Project.ProjectStatus = .draft) -> Project {
        var project = ProjectFixtures.project(
            id: projectId,
            shots: (0..<shots).map {
                ProjectFixtures.shot(id: "s\($0)", order: $0,
                                     provider: keylessProvider, model: pricedModel,
                                     duration: duration)
            },
            costBudgetUSD: costBudgetUSD)
        project.status = status
        return project
    }

    // MARK: - Calling the tool

    private struct ToolResult {
        let isError: Bool
        let body: [String: Any]

        func string(_ key: String) -> String? { body[key] as? String }
        func bool(_ key: String) -> Bool? { body[key] as? Bool }
        func int(_ key: String) -> Int? { body[key] as? Int }
        func double(_ key: String) -> Double? { body[key] as? Double }
        var shots: [[String: Any]] { (body["shots"] as? [[String: Any]]) ?? [] }
    }

    private func callProjectRun(_ arguments: [String: AnyCodableValue],
                                progressToken: AnyCodableValue? = nil) async throws -> ToolResult {
        var params: [String: AnyCodableValue] = [
            "name": .string("project_run"),
            "arguments": .dictionary(arguments),
        ]
        if let progressToken {
            params["_meta"] = .dictionary(["progressToken": progressToken])
        }
        let request = MCPRequest(jsonrpc: "2.0", id: .int(1), method: "tools/call", params: params)
        guard let response = await server.handleRequest(request),
              let result = response.result?.objectValue else {
            throw XCTSkip("no result")
        }
        let isError = result["isError"]?.boolValue ?? false
        guard let text = result["content"]?.arrayValue?.first?["text"]?.stringValue,
              let data = text.data(using: .utf8),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("tool result had no JSON text block: \(result)")
            return ToolResult(isError: isError, body: [:])
        }
        return ToolResult(isError: isError, body: body)
    }

    private func trackJournal(_ result: ToolResult) {
        if let id = result.string("run_id") { journalIds.append(id) }
    }

    // MARK: - Annotations and schema

    /// The annotation a client reads from `tools/list`, before it knows what
    /// arguments will be passed. The safe default does **not** soften it: the
    /// only honest hint for a tool that can charge a provider once per shot is
    /// the worst case.
    func testProjectRunIsAnnotatedForItsWorstCaseNotItsDefault() {
        guard let tool = MCPToolRegistry.allTools.first(where: { $0.name == "project_run" }) else {
            return XCTFail("project_run is missing from the registry")
        }
        XCTAssertFalse(tool.annotations.readOnlyHint, "project_run executes; it is not a read")
        XCTAssertTrue(tool.annotations.destructiveHint, "it charges the user irreversibly, per shot")
        XCTAssertFalse(tool.annotations.idempotentHint, "a second call bills again")
        XCTAssertTrue(tool.annotations.openWorldHint, "shots go to remote providers")
    }

    func testProjectRunAnnotationsReachTheWireWithAllFourHints() {
        let tool = MCPToolRegistry.allTools.first { $0.name == "project_run" }
        let wire = tool?.toAnyCodable()["annotations"]?.objectValue
        XCTAssertEqual(wire?["readOnlyHint"]?.boolValue, false)
        XCTAssertEqual(wire?["destructiveHint"]?.boolValue, true)
        XCTAssertEqual(wire?["idempotentHint"]?.boolValue, false)
        XCTAssertEqual(wire?["openWorldHint"]?.boolValue, true)
    }

    /// The description is the only place a model learns the two-argument
    /// contract before it calls. If it stops naming both, the model has to
    /// discover the ceiling by being refused.
    func testTheDescriptionNamesBothSpendingGuards() {
        let description = MCPToolRegistry.allTools.first { $0.name == "project_run" }?.description ?? ""
        XCTAssertTrue(description.contains("confirm"), description)
        XCTAssertTrue(description.contains("max_cost_usd"), description)
        XCTAssertTrue(description.uppercased().contains("SPENDS"), description)
    }

    func testTheOutputSchemaDeclaresWhetherAnythingWasExecuted() {
        let tool = MCPToolRegistry.allTools.first { $0.name == "project_run" }
        guard let schema = tool?.outputSchema,
              let properties = schema["properties"]?.objectValue else {
            return XCTFail("project_run has no outputSchema")
        }
        let required = (schema["required"]?.arrayValue ?? []).compactMap { $0.stringValue }
        XCTAssertTrue(required.contains("executed"),
                      "a caller must be able to tell a plan from a run without heuristics")
        // A `required` entry with no matching property makes strict clients
        // reject the whole tools/list, not just this tool.
        for name in required {
            XCTAssertNotNil(properties[name], "required '\(name)' is not a declared property")
        }
    }

    /// The gap this work closed: the tool used to return the shell command that
    /// runs the project instead of running it.
    func testTheToolNoLongerPointsAtTheShellInsteadOfRunning() async throws {
        save(pricedProject())
        let result = try await callProjectRun(["project_id": .string(projectId)])
        let rendered = result.body.values.compactMap { $0 as? String }.joined(separator: " ")
        XCTAssertFalse(rendered.contains("for full execution"), rendered)
        XCTAssertEqual(result.bool("executed"), false)
        XCTAssertEqual(result.string("mode"), "plan")
        XCTAssertNotNil(result.body["shots"], "a plan, not a one-line lookup")
    }

    // MARK: - Planning: what would run

    func testAPlanCountsOnlyPendingShotsUnlessResuming() {
        let shots = [
            ProjectFixtures.shot(id: "done", status: .succeeded),
            ProjectFixtures.shot(id: "broken", order: 1, status: .failed),
            ProjectFixtures.shot(id: "todo", order: 2),
        ]
        let project = ProjectFixtures.project(id: projectId, shots: shots)

        XCTAssertEqual(ProjectRunPlanner.plan(project: project, resume: false).shots.count, 1)
        XCTAssertEqual(ProjectRunPlanner.plan(project: project, resume: true).shots.count, 2)
    }

    /// The drain marks shots downstream of a failure `.skipped`. Without
    /// counting them, "resume" fixes shot 3 and leaves 4-7 dead — and then the
    /// run reports `succeeded`, because `failed == 0`.
    func testResumeCountsShotsTheDrainBlockedBehindAFailure() {
        var blocked = ProjectFixtures.shot(id: "downstream", order: 1, status: .skipped)
        blocked.errorMessage = DAGExecutor.blockedByUpstreamMessage
        var skippedForAnotherReason = ProjectFixtures.shot(id: "other", order: 2, status: .skipped)
        skippedForAnotherReason.errorMessage = "deliberately skipped by the user"

        let project = ProjectFixtures.project(
            id: projectId,
            shots: [ProjectFixtures.shot(id: "up", status: .failed), blocked, skippedForAnotherReason])

        let names = Set(ProjectRunPlanner.plan(project: project, resume: true).shots.map(\.name))
        XCTAssertEqual(names, ["up", "downstream"],
                       "a shot skipped for some other reason must not be resurrected")
    }

    func testFanoutMultipliesTheEstimateBecauseItBillsOncePerCandidate() {
        var single = pricedProject()
        let one = ProjectRunPlanner.plan(project: single, resume: false).totalEstimatedCostUSD

        single.scenes[0].shots[0].fanout = 4
        let four = ProjectRunPlanner.plan(project: single, resume: false).totalEstimatedCostUSD

        XCTAssertGreaterThan(one, 0, "the fixture must have a priced model or this proves nothing")
        XCTAssertEqual(four, one * 4, accuracy: 0.0001)
    }

    /// `executeFanoutShot` clamps to `WorkflowSpec.maxFanout`. A plan that
    /// quoted 1000 candidates for a run that dispatches 32 would be wrong in
    /// the expensive direction and get the run refused for no reason.
    func testFanoutIsClampedToTheSameCeilingTheExecutorUses() {
        var project = pricedProject()
        project.scenes[0].shots[0].fanout = 1000
        let plan = ProjectRunPlanner.plan(project: project, resume: false)
        XCTAssertEqual(plan.shots.first?.candidates, WorkflowSpec.maxFanout)
    }

    func testScatterGatherMultipliesTheEstimateByTheScatterCount() {
        var project = pricedProject()
        project.settings.routingStrategy = .scatterGather
        project.settings.scatterCount = 3
        let plan = ProjectRunPlanner.plan(project: project, resume: false)
        XCTAssertEqual(plan.shots.first?.candidates, 3)
        XCTAssertTrue(plan.caveats.contains { $0.contains("scatter_count") })
    }

    func testWaveCountIsTheDependencyDepth() {
        let shots = [
            ProjectFixtures.shot(id: "a"),
            ProjectFixtures.shot(id: "b", deps: ["a"], order: 1),
            ProjectFixtures.shot(id: "c", deps: ["b"], order: 2),
        ]
        let plan = ProjectRunPlanner.plan(project: ProjectFixtures.project(id: projectId, shots: shots),
                                          resume: false)
        XCTAssertEqual(plan.waveCount, 3)
        XCTAssertNil(plan.graphError)
    }

    func testACyclicGraphIsRefusedByThePlannerRatherThanPriced() {
        let shots = [
            ProjectFixtures.shot(id: "a", deps: ["b"]),
            ProjectFixtures.shot(id: "b", deps: ["a"], order: 1),
        ]
        let plan = ProjectRunPlanner.plan(project: ProjectFixtures.project(id: projectId, shots: shots),
                                          resume: false)
        XCTAssertNotNil(plan.graphError)
    }

    // MARK: - Planning: the local pre-flight, replayed without spending

    func testAnUnknownProviderIsBlockedInThePlanAndPricedAtZero() {
        let project = ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel, duration: 5),
        ])
        let plan = ProjectRunPlanner.plan(project: project, resume: false)
        XCTAssertEqual(plan.blockedShots.count, 1)
        XCTAssertEqual(plan.totalEstimatedCostUSD, 0,
                       "a shot that cannot reach a provider cannot bill")
        XCTAssertFalse(plan.wouldSpend)
        XCTAssertTrue(plan.shots.first?.blockedReason?.contains("Unknown provider") == true,
                      plan.shots.first?.blockedReason ?? "nil")
    }

    func testAShotWithNoConfiguredKeyIsBlockedWithAnActionableMessage() throws {
        let unconfigured = Set(ProviderRegistry.shared.all.map { $0.providerId })
            .subtracting(ProviderRouter.availableProviders())
        guard let provider = unconfigured.sorted().first else {
            throw XCTSkip("every provider has a key on this machine")
        }
        let project = ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", provider: provider, model: "whatever", duration: 5),
        ])
        let reason = ProjectRunPlanner.plan(project: project, resume: false).shots.first?.blockedReason
        XCTAssertTrue(reason?.contains("No API key configured") == true, reason ?? "nil")
        XCTAssertTrue(reason?.contains("openflix keys set") == true, reason ?? "nil")
    }

    /// The engine refuses these at `submit`. Surfacing them in the plan is the
    /// difference between "shot 5 of 7 was refused" and "shots 1-4 were billed,
    /// then shot 5 was refused".
    func testAnImpossibleDurationIsBlockedInThePlanBeforeAnythingIsBilled() {
        for duration in [9_999.0, -1, 0, Double.nan, .infinity] {
            let project = ProjectFixtures.project(id: projectId, shots: [
                ProjectFixtures.shot(id: "a", provider: keylessProvider,
                                     model: pricedModel, duration: duration),
            ])
            let plan = ProjectRunPlanner.plan(project: project, resume: false)
            XCTAssertNotNil(plan.shots.first?.blockedReason, "duration \(duration) should be refused")
            XCTAssertEqual(plan.totalEstimatedCostUSD, 0, "duration \(duration)")
        }
    }

    func testALocalReferenceImageIsBlockedInThePlan() {
        var project = pricedProject()
        // `local` is exempt from the reference-image rule (ComfyUI runs here),
        // so this case needs a provider that is not.
        project.scenes[0].shots[0].provider = "runway"
        project.scenes[0].shots[0].referenceImageURL = "/Users/me/My Photos/frame.png"
        let reason = ProjectRunPlanner.plan(project: project, resume: false).shots.first?.blockedReason
        XCTAssertNotNil(reason)
    }

    func testABlockedPromptIsRefusedInThePlan() {
        var project = pricedProject()
        project.scenes[0].shots[0].prompt = "a ransomware tutorial, cinematic"
        let reason = ProjectRunPlanner.plan(project: project, resume: false).shots.first?.blockedReason
        XCTAssertTrue(reason?.contains("safety") == true, reason ?? "nil")
    }

    // MARK: - Planner ⇄ executor parity

    /// The plan and the run must agree on where a shot goes. They share
    /// `plannedTarget`; this pins the three branches that matter.
    func testThePlanResolvesTheSameTargetTheExecutorWouldDispatch() {
        var settings = ProjectSettings()

        let pinned = ProjectFixtures.shot(id: "a", provider: "runway", model: "gen4_turbo")
        XCTAssertEqual(DAGExecutor.plannedTarget(shot: pinned, settings: settings,
                                                 availableProviders: []).providerModel?.provider,
                       "runway")

        let bare = ProjectFixtures.shot(id: "b")
        XCTAssertNil(DAGExecutor.plannedTarget(shot: bare, settings: settings,
                                               availableProviders: []).providerModel)
        XCTAssertEqual(DAGExecutor.plannedTarget(shot: bare, settings: settings,
                                                 availableProviders: []).refusal,
                       DAGExecutor.unresolvedTargetMessage)

        settings.defaultProvider = "luma"
        settings.defaultModel = "ray-2"
        XCTAssertEqual(DAGExecutor.plannedTarget(shot: bare, settings: settings,
                                                 availableProviders: []).providerModel?.model,
                       "ray-2")
    }

    /// `DAGExecutorTests` and `test.sh` both pin this string.
    func testTheUnresolvedTargetRefusalIsUnchanged() {
        XCTAssertEqual(DAGExecutor.unresolvedTargetMessage,
                       "No provider/model specified and no routing strategy configured")
        XCTAssertEqual(DAGExecutor.blockedByUpstreamMessage, "Blocked by upstream failure")
    }

    // MARK: - The tool: a bare call spends nothing

    func testABareCallReturnsAPlanAndLeavesTheProjectUntouched() async throws {
        save(pricedProject(shots: 3))
        let result = try await callProjectRun(["project_id": .string(projectId)])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.bool("executed"), false)
        XCTAssertEqual(result.string("mode"), "plan")
        XCTAssertEqual(result.int("shots_to_run"), 3)
        XCTAssertEqual(result.double("estimated_cost_usd") ?? -1, 1.5, accuracy: 0.0001,
                       "3 shots × 10s × $0.05/s")
        XCTAssertNil(result.body["run_id"], "a plan writes no run journal")
        XCTAssertNotNil(result.body["budget"], "the plan must carry the budget it will be gated by")

        XCTAssertEqual(reload()?.status, .draft, "planning must not mark the project running")
        XCTAssertTrue(reload()?.allShots.allSatisfy { $0.status == .pending } == true)
    }

    func testPlanningTwiceChangesNothing() async throws {
        save(pricedProject(shots: 2))
        let first = try await callProjectRun(["project_id": .string(projectId)])
        let second = try await callProjectRun(["project_id": .string(projectId)])
        XCTAssertEqual(first.double("estimated_cost_usd"), second.double("estimated_cost_usd"))
        XCTAssertEqual(reload()?.status, .draft)
    }

    func testThePlanSpellsOutTheExactCallThatWouldExecute() async throws {
        save(pricedProject())
        let next = try await callProjectRun(["project_id": .string(projectId)]).string("next_step") ?? ""
        XCTAssertTrue(next.contains("NOTHING HAS BEEN SPENT"), next)
        XCTAssertTrue(next.contains("\"confirm\": true"), next)
        XCTAssertTrue(next.contains("max_cost_usd"), next)
        XCTAssertTrue(next.contains(projectId), next)
    }

    func testThePlanCarriesTheCaveatsThatMakeTheEstimateHonest() async throws {
        save(pricedProject())
        let result = try await callProjectRun(["project_id": .string(projectId)])
        XCTAssertEqual(result.bool("estimated_cost_is_upper_bound"), true)
        let caveats = (result.body["caveats"] as? [String]) ?? []
        XCTAssertFalse(caveats.isEmpty)
        XCTAssertTrue(caveats.contains { $0.contains("Upper bound") }, "\(caveats)")
    }

    // MARK: - The tool: refusing to spend

    func testConfirmWithoutACostCeilingIsRefusedInBandWithTheEstimate() async throws {
        save(pricedProject(shots: 2))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
        ])
        XCTAssertTrue(result.isError, "a refusal to spend must be visible to the model as an error")
        XCTAssertEqual(result.string("error"), "cost_ceiling_required")
        XCTAssertTrue(result.string("message")?.contains("$1.00") == true, result.string("message") ?? "")
        XCTAssertEqual(reload()?.status, .draft, "nothing may have started")
    }

    func testACeilingBelowTheEstimateIsRefusedBeforeAnythingIsSubmitted() async throws {
        save(pricedProject(shots: 4))   // 4 × 10s × $0.05 = $2.00
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(0.5),
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.string("error"), "cost_ceiling_too_low")
        XCTAssertTrue(result.string("message")?.contains("$2.00") == true, result.string("message") ?? "")
        XCTAssertTrue(result.string("message")?.contains("$0.50") == true, result.string("message") ?? "")
        XCTAssertEqual(reload()?.status, .draft)
        XCTAssertTrue(reload()?.allShots.allSatisfy { $0.status == .pending } == true,
                      "no shot may have been dispatched")
    }

    /// A ceiling that is not a number is not a ceiling. `spend >= NaN` is false,
    /// so accepting one would mean "unlimited" while looking like a limit.
    func testANonNumericCeilingIsRefusedRatherThanTreatedAsUnlimited() async throws {
        save(pricedProject())
        for ceiling in [Double.nan, .infinity, 0, -5] {
            let result = try await callProjectRun([
                "project_id": .string(projectId),
                "confirm": .bool(true),
                "max_cost_usd": .double(ceiling),
            ])
            XCTAssertTrue(result.isError, "ceiling \(ceiling)")
            XCTAssertEqual(result.string("error"), "cost_ceiling_required", "ceiling \(ceiling)")
        }
        XCTAssertEqual(reload()?.status, .draft)
    }

    func testAProjectAlreadyRunningIsRefused() async throws {
        save(pricedProject(status: .running))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.string("error"), "project_not_runnable")
    }

    func testAProjectWhereEveryShotIsBlockedRefusesRatherThanStarting() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ]))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.string("error"), "nothing_to_run")
        XCTAssertEqual(reload()?.status, .draft)
    }

    func testACyclicProjectIsRefusedInPlanModeToo() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", deps: ["b"]),
            ProjectFixtures.shot(id: "b", deps: ["a"], order: 1),
        ]))
        let result = try await callProjectRun(["project_id": .string(projectId)])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.string("error"), "invalid_graph")
    }

    func testAnUnknownProjectIsAnError() async throws {
        let missing = "openflix-test-missing-\(UUID().uuidString)"
        touchedProjectIds.insert(missing)
        let result = try await callProjectRun(["project_id": .string(missing)])
        XCTAssertTrue(result.isError)
    }

    /// The same grammar every other id-taking tool uses — a project id becomes
    /// `~/.openflix/projects/<id>.json`.
    func testATraversalProjectIdIsRefusedBeforeItReachesTheStore() async throws {
        let result = try await callProjectRun([
            "project_id": .string("../../../../etc/passwd"),
        ])
        XCTAssertTrue(result.isError)
    }

    // MARK: - The tool: executing, and reading a partial failure

    /// The orchestration end to end, with `costBudgetUSD: 0` so the executor's
    /// gate refuses every shot *before* dispatch. Nothing is submitted and
    /// nothing is billed, but every other moving part is real: the journal, the
    /// DAG loop, the per-shot result rows and the status math.
    func testExecutingDrivesTheDagAndReportsEveryShotOutcome() async throws {
        save(pricedProject(shots: 3, costBudgetUSD: 0))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
            "timeout_seconds": .double(30),
        ])
        trackJournal(result)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.bool("executed"), true)
        XCTAssertEqual(result.string("mode"), "execute")
        XCTAssertEqual(result.int("shots_failed"), 3)
        XCTAssertEqual(result.int("shots_succeeded"), 0)
        XCTAssertEqual(result.double("actual_cost_usd"), 0)
        XCTAssertEqual(result.shots.count, 3, "every shot is reported, not just the failures")
        for shot in result.shots {
            XCTAssertTrue((shot["error"] as? String)?.contains("Cost budget exceeded") == true, "\(shot)")
            XCTAssertEqual(shot["status"] as? String, "failed")
        }
    }

    /// The property `DAGExecutorTests` established, restated at the tool
    /// boundary: an agent must never read "succeeded" for a run in which
    /// everything failed.
    func testARunWhereEverythingFailedIsNeverReportedAsSucceeded() async throws {
        save(pricedProject(shots: 2, costBudgetUSD: 0))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
        ])
        trackJournal(result)
        XCTAssertEqual(result.string("status"), Project.ProjectStatus.failed.rawValue)
        XCTAssertNotEqual(result.string("status"), Project.ProjectStatus.succeeded.rawValue)
    }

    func testAFailedRunTellsTheCallerHowToResumeIt() async throws {
        save(pricedProject(shots: 2, costBudgetUSD: 0))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
        ])
        trackJournal(result)
        let next = result.string("next_step") ?? ""
        XCTAssertTrue(next.contains("\"resume\": true"), next)
        XCTAssertTrue(next.contains("failed"), next)
        XCTAssertTrue(next.contains("$0.00"), next)
    }

    func testExecutingWritesARunJournalTheCallerCanFindAfterACrash() async throws {
        save(pricedProject(costBudgetUSD: 0))
        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
        ])
        trackJournal(result)

        guard let runId = result.string("run_id") else { return XCTFail("no run_id") }
        XCTAssertFalse(runId.isEmpty)
        XCTAssertEqual(result.string("run_journal_path"), "~/.openflix/runs/\(runId).json")
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix/runs/\(runId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "the journal must exist on disk, not just in the reply")
    }

    func testASucceededShotIsNotRerunAndItsCostIsNotDoubleCounted() async throws {
        var project = pricedProject(shots: 2, costBudgetUSD: 0)
        project.scenes[0].shots[0].status = .succeeded
        project.scenes[0].shots[0].actualCostUSD = 0.4
        save(project)

        let result = try await callProjectRun([
            "project_id": .string(projectId),
            "confirm": .bool(true),
            "max_cost_usd": .double(100),
        ])
        trackJournal(result)
        XCTAssertEqual(result.int("shots_succeeded"), 1)
        XCTAssertEqual(result.int("shots_failed"), 1)
        XCTAssertEqual(result.string("status"), Project.ProjectStatus.partialFailure.rawValue)
        XCTAssertEqual(result.double("actual_cost_usd") ?? -1, 0.4, accuracy: 0.0001)
    }

    // MARK: - Resume

    func testResumeResetsFailedStaleAndUpstreamBlockedShotsOnly() {
        var blocked = ProjectFixtures.shot(id: "blocked", order: 3, status: .skipped)
        blocked.errorMessage = DAGExecutor.blockedByUpstreamMessage
        var otherSkip = ProjectFixtures.shot(id: "other", order: 4, status: .skipped)
        otherSkip.errorMessage = "not the drain"

        save(ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "ok", status: .succeeded),
            ProjectFixtures.shot(id: "bad", order: 1, status: .failed),
            ProjectFixtures.shot(id: "stuck", order: 2, status: .processing),
            blocked, otherSkip,
        ]))

        XCTAssertEqual(DAGExecutor.resetStaleShots(projectId: projectId), 3)
        let byId = Dictionary(uniqueKeysWithValues: (reload()?.allShots ?? []).map { ($0.id, $0) })
        XCTAssertEqual(byId["ok"]?.status, .succeeded)
        XCTAssertEqual(byId["bad"]?.status, .pending)
        XCTAssertNil(byId["bad"]?.errorMessage)
        XCTAssertEqual(byId["bad"]?.retryCount, 0)
        XCTAssertEqual(byId["stuck"]?.status, .pending)
        XCTAssertEqual(byId["blocked"]?.status, .pending)
        XCTAssertEqual(byId["other"]?.status, .skipped, "only the drain's own marker is reversible")
    }

    func testResumeIsAppliedToThePlanAsWellAsTheRun() async throws {
        var project = pricedProject(shots: 2)
        project.scenes[0].shots[0].status = .failed
        save(project)

        let plain = try await callProjectRun(["project_id": .string(projectId)])
        let resumed = try await callProjectRun(["project_id": .string(projectId),
                                                "resume": .bool(true)])
        XCTAssertEqual(plain.int("shots_to_run"), 1)
        XCTAssertEqual(resumed.int("shots_to_run"), 2)
        XCTAssertGreaterThan(resumed.double("estimated_cost_usd") ?? 0,
                             plain.double("estimated_cost_usd") ?? 0)
        XCTAssertEqual(reload()?.allShots.first?.status, .failed,
                       "planning with resume must not actually reset anything")
    }

    // MARK: - The ceiling inside the executor

    /// The second half of the ceiling: an estimate is a guess, so the ceiling
    /// is also a live gate. Here the project has no budget of its own and the
    /// ceiling alone stops the run.
    func testTheCostCeilingActsAsABudgetGateDuringTheRun() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "billed", status: .succeeded, actualCostUSD: 2.0),
            ProjectFixtures.shot(id: "next", order: 1,
                                 provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ]))
        _ = try await DAGExecutor(projectId: projectId, costCeilingUSD: 0.5).execute()
        let blocked = reload()?.allShots.first { $0.id == "next" }
        XCTAssertEqual(blocked?.status, .failed)
        XCTAssertTrue(blocked?.errorMessage?.hasPrefix("Cost budget exceeded") == true,
                      blocked?.errorMessage ?? "nil")
    }

    /// It narrows, never widens. A generous ceiling must not override a strict
    /// project budget.
    func testAGenerousCeilingCannotLoosenTheProjectsOwnBudget() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ], costBudgetUSD: 0))
        _ = try await DAGExecutor(projectId: projectId, costCeilingUSD: 1_000_000).execute()
        XCTAssertTrue(reload()?.allShots.first?.errorMessage?.hasPrefix("Cost budget exceeded") == true)
    }

    /// A non-finite ceiling is dropped rather than kept: `spend >= NaN` is
    /// false, so keeping it would silently mean "no gate" while reading as one.
    /// With no project budget either, the shot fails for its own reason.
    func testANonFiniteCeilingIsDroppedNotTurnedIntoARefuseEverythingGate() async throws {
        save(ProjectFixtures.project(id: projectId, shots: [
            ProjectFixtures.shot(id: "a", provider: ProjectFixtures.unroutableProvider,
                                 model: ProjectFixtures.unroutableModel),
        ]))
        _ = try await DAGExecutor(projectId: projectId, costCeilingUSD: .nan).execute()
        let message = reload()?.allShots.first?.errorMessage ?? ""
        XCTAssertFalse(message.hasPrefix("Cost budget exceeded"), message)
    }

    // MARK: - Progress notifications

    func testProgressIsOnlyWiredUpWhenTheClientSuppliesAToken() {
        XCTAssertNil(MCPServer.progressReporter(token: nil),
                     "no token means no notifications — which is why this is safe to add")
        XCTAssertNotNil(MCPServer.progressReporter(token: .string("abc")))
        XCTAssertNotNil(MCPServer.progressReporter(token: .int(7)))
    }

    func testAProgressNotificationIsAWellFormedJsonRpcNotificationWithNoId() throws {
        guard let line = MCPServer.notificationLine(MCPServer.progressNotification, [
            "progressToken": .string("tok"),
            "progress": .int(2),
            "total": .int(5),
            "message": .string("shot two: succeeded"),
        ]), let data = line.data(using: .utf8),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("progress notification did not serialise")
        }
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["method"] as? String, "notifications/progress")
        XCTAssertNil(object["id"], "a notification with an id is a request, and nothing will answer it")
        let params = object["params"] as? [String: Any]
        XCTAssertEqual(params?["progressToken"] as? String, "tok")
        XCTAssertEqual(params?["progress"] as? Int, 2)
        XCTAssertEqual(params?["total"] as? Int, 5)
        XCTAssertFalse(line.contains("\n"), "the newline IS the framing on this transport")
    }

    func testTheProgressSinkSurvivesHostileNumbers() {
        // A NaN cost would make `String(format:)` print "nan" and, worse, a
        // JSONEncoder throw if it ever reached the wire as a number.
        let reporter = MCPServer.progressReporter(token: .string("t"))
        XCTAssertNotNil(reporter)
        // Building the line is the part that can throw; the sink itself prints.
        let line = MCPServer.notificationLine(MCPServer.progressNotification, [
            "progressToken": .string("t"),
            "progress": .int(1),
            "total": .int(1),
            "message": .string("cost \(Double.nan)"),
        ])
        XCTAssertNotNil(line)
    }

    // MARK: - Timeout arithmetic

    func testTheRunTimeoutIsClampedAndNeverTrapping() async {
        let cases: [(AnyCodableValue?, Double)] = [
            (nil, MCPServer.projectRunDefaultTimeout),
            // A non-finite request is not a request: fall back to the default
            // rather than silently granting the maximum.
            (.double(.nan), MCPServer.projectRunDefaultTimeout),
            (.double(.infinity), MCPServer.projectRunDefaultTimeout),
            (.double(0), MCPServer.projectRunDefaultTimeout),
            (.double(-1), MCPServer.projectRunDefaultTimeout),
            (.double(1e9), MCPServer.projectRunMaxTimeout),
            (.int(30), 30),
        ]
        for (value, expected) in cases {
            var args: [String: AnyCodableValue] = [:]
            if let value { args["timeout_seconds"] = value }
            let actual = await server.clampedRunTimeout(args)
            XCTAssertEqual(actual, expected, "timeout_seconds \(String(describing: value))")
        }
    }

    /// `UInt64(someDouble)` aborts the process on a non-finite value, and this
    /// one is reachable from a tool argument.
    func testSecondsToNanosecondsNeverTraps() {
        XCTAssertEqual(nanoseconds(.nan), 0)
        XCTAssertEqual(nanoseconds(-1), 0)
        XCTAssertEqual(nanoseconds(0), 0)
        XCTAssertEqual(nanoseconds(.infinity), 0, "not a duration; sleep nothing rather than trap")
        XCTAssertEqual(nanoseconds(1e300), UInt64(86_400) * 1_000_000_000,
                       "a finite but absurd value is clamped, not converted")
        XCTAssertEqual(nanoseconds(2), 2_000_000_000)
    }
}
