import XCTest
import OpenFlixKit
@testable import openflix

/// The CLI's action catalog is the single description of every action; the
/// MCP tool list and `openflix action list` are both derived from it, and
/// `CLIActions.run` is the one door every surface calls through.
///
/// **Nothing here reaches a provider or the network.** Every call below is
/// refused by argument validation before its handler runs, or is a local read.
final class CLIActionCatalogTests: XCTestCase {

    // MARK: - The catalog itself

    func testEveryActionIsWellFormed() {
        for descriptor in CLIActionCatalog.all {
            XCTAssertEqual(descriptor.problems, [], descriptor.name)
        }
    }

    func testNamesAreUnique() {
        let names = CLIActionCatalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// A catalog entry with no handler would be advertised and then fail; a
    /// handler with no entry would run unvalidated. Neither may exist.
    func testEveryActionHasExactlyOneHandler() {
        XCTAssertEqual(Set(CLIActionCatalog.all.map(\.name)), Set(CLIActions.handlers.keys))
    }

    func testTheMCPToolListIsTheCatalog() {
        XCTAssertEqual(MCPToolRegistry.allTools.map(\.name), CLIActionCatalog.all.map(\.name))
    }

    /// The wire claims every tool makes, pinned. These are derived from each
    /// action's effect now, so this is the table that would catch an effect
    /// declared wrongly.
    ///
    /// One row changed deliberately when the catalog replaced hand-written
    /// annotations: `evaluate_quality` is now destructive. Its llm-vision
    /// evaluator bills the user's model account, and — like `project_run` — a
    /// client reads annotations before it knows which evaluator a call will
    /// ask for, so only the worst case is honest.
    func testEveryToolsAnnotationsArePinned() {
        // (readOnly, destructive, idempotent, openWorld); nil = omitted for a read.
        let expected: [String: (Bool, Bool?, Bool?, Bool)] = [
            "generate":          (false, true,  false, true),
            "generate_submit":   (false, true,  false, true),
            "retry_generation":  (false, true,  false, true),
            "project_run":       (false, true,  false, true),
            "evaluate_quality":  (false, true,  false, true),
            "cancel_generation": (false, true,  false, true),
            "generate_poll":     (false, false, true,  true),
            "submit_vote":       (false, false, true,  true),
            "submit_feedback":   (false, false, false, false),
            "list_generations":  (true,  nil,   nil,   false),
            "get_generation":    (true,  nil,   nil,   false),
            "list_providers":    (true,  nil,   nil,   false),
            "get_metrics":       (true,  nil,   nil,   false),
            "budget_status":     (true,  nil,   nil,   false),
            "health_check":      (true,  nil,   nil,   false),
        ]
        XCTAssertEqual(Set(expected.keys), Set(CLIActionCatalog.all.map(\.name)))
        for descriptor in CLIActionCatalog.all {
            guard let want = expected[descriptor.name] else { continue }
            let got = descriptor.annotations
            XCTAssertEqual(got.readOnlyHint, want.0, descriptor.name)
            XCTAssertEqual(got.destructiveHint, want.1, descriptor.name)
            XCTAssertEqual(got.idempotentHint, want.2, descriptor.name)
            XCTAssertEqual(got.openWorldHint, want.3, descriptor.name)
        }
    }

    /// Anything that spends is destructive on the wire — the rule the old
    /// hand-written table relied on people to remember.
    func testEverythingThatSpendsLooksDestructiveOverMCP() {
        for tool in MCPToolRegistry.allTools
        where CLIActionCatalog.descriptor(named: tool.name)?.effect == .spend {
            XCTAssertFalse(tool.annotations.readOnlyHint, tool.name)
            XCTAssertTrue(tool.annotations.destructiveHint, tool.name)
            XCTAssertTrue(tool.annotations.openWorldHint, tool.name)
        }
    }

    func testTheManifestListsEveryAction() {
        let manifest = CLIActionCatalog.manifest
        XCTAssertEqual(manifest["contract"]?.stringValue, ActionManifest.contract)
        XCTAssertEqual(manifest["host"]?.stringValue, "openflix-cli")
        XCTAssertEqual(manifest["actions"]?.arrayValue?.count, CLIActionCatalog.all.count)
    }

    // MARK: - The one door

    private func refusal(_ name: String, _ arguments: [String: AnyCodableValue]) async -> ActionInputError? {
        do {
            _ = try await CLIActions.run(name, arguments: arguments,
                                         context: ActionContext(caller: .localAgent("test")))
            return nil
        } catch let input as ActionInputError {
            return input
        } catch {
            return nil
        }
    }

    /// `Array.prefix(-1)` traps. Before validation, this one argument aborted
    /// the whole MCP server process.
    func testANegativeLimitIsRefusedInsteadOfCrashingTheServer() async {
        let error = await refusal("list_generations", ["limit": .int(-1)])
        XCTAssertEqual(error?.argument, "limit")
    }

    /// The paid-call case the closed schemas exist for: `duration` is not an
    /// argument, and ignoring it would bill the default duration instead.
    func testAMisspelledArgumentOnAPaidCallIsRefusedBeforeAnythingIsSubmitted() async {
        let error = await refusal("generate", ["prompt": .string("a fox"), "duration": .int(5)])
        XCTAssertEqual(error?.argument, "duration")
        XCTAssertTrue(error?.message.contains("duration_seconds") == true, error?.message ?? "")
    }

    func testRetriesAreBounded() async {
        let error = await refusal("generate", ["prompt": .string("a fox"), "max_retries": .int(1_000)])
        XCTAssertEqual(error?.argument, "max_retries")
    }

    func testAnUnknownActionIsRefused() async {
        do {
            _ = try await CLIActions.run("rm_rf", arguments: [:], context: ActionContext(caller: .cli))
            XCTFail("an unknown action must not run")
        } catch let error as OpenFlixError {
            XCTAssertTrue(error.errorDescription?.contains("Unknown tool") == true)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAValidLocalReadRunsThroughTheSameDoor() async throws {
        let result = try await CLIActions.run("list_providers", arguments: [:],
                                              context: ActionContext(caller: .localAgent("test")))
        XCTAssertNotNil(result["count"] as? Int)
    }

    // MARK: - Error classes

    func testFailuresMapToClassesAnAgentCanBranchOn() {
        XCTAssertEqual(CLIActions.failure(from: OpenFlixError.budgetExceeded("over")).errorClass, .policy)
        XCTAssertEqual(CLIActions.failure(from: OpenFlixError.generationNotFound("x")).errorClass, .notFound)
        XCTAssertEqual(CLIActions.failure(from: OpenFlixError.hookVeto("no")).errorClass, .policy)
        XCTAssertEqual(CLIActions.failure(from: OpenFlixError.rateLimited("fal", retryAfter: 3)).errorClass, .rateLimited)
        XCTAssertEqual(CLIActions.failure(from: ActionInputError(argument: "a", message: "m")).errorClass, .invalidInput)
        let refusal = MCPToolRefusal(code: "cost_ceiling_required", message: "m", details: ["x": 1])
        let mapped = CLIActions.failure(from: refusal)
        XCTAssertEqual(mapped.code, "cost_ceiling_required")
        XCTAssertTrue(mapped.errorClass.isRefusal, "a tool's refusal happened before anything was spent")
    }

    // MARK: - `openflix action run`

    private func execute(_ name: String, _ input: String?, stdin: String = "") async -> JSONValue {
        await ActionRun.execute(name: name, rawInput: input,
                                readStdin: { Data(stdin.utf8) }, progress: nil)
    }

    func testRunPrintsTheSuccessEnvelope() async {
        let envelope = await execute("list_providers", nil)
        XCTAssertEqual(envelope["contract"]?.stringValue, ActionResult.contract)
        XCTAssertEqual(envelope["status"]?.stringValue, "ok")
        XCTAssertNotNil(envelope["data"]?["count"]?.intValue)
    }

    func testRunReadsArgumentsFromStdin() async {
        let envelope = await execute("list_generations", "-", stdin: #"{"limit": -1}"#)
        XCTAssertEqual(envelope["status"]?.stringValue, "refused")
        XCTAssertEqual(envelope["error"]?["class"]?.stringValue, "invalid_input")
        XCTAssertEqual(envelope["error"]?["details"]?["argument"]?.stringValue, "limit")
    }

    func testRunRefusesInputThatIsNotAnObject() async {
        for input in ["[1,2]", "prompt=fox", "{"] {
            let envelope = await execute("list_generations", input)
            XCTAssertEqual(envelope["status"]?.stringValue, "refused", input)
            XCTAssertEqual(envelope["error"]?["code"]?.stringValue, "INPUT_INVALID", input)
        }
    }

    func testEmptyInputMeansNoArguments() async {
        let envelope = await execute("list_providers", "-", stdin: "  \n")
        XCTAssertEqual(envelope["status"]?.stringValue, "ok")
    }
}
