import XCTest
import OpenFlixKit
@testable import openflix

/// What OpenClaw, Hermes and any other agent get beyond Phase 2: playback in
/// OpenFlix instead of another player, recipes as actions, MCP over the
/// bridge with spending as two tool calls, and the skill both agents load.
///
/// **Nothing here opens an app, spends, or reaches a network.** Playback runs
/// through a recording `openURL`; the one execution path uses the keyless
/// `local` provider behind a vetoing `pre-generate` hook; grants live in a
/// temp directory. The test recipe is the only write to `~/.openflix`, and it
/// is deleted in tearDown.
final class AgentSuiteTests: XCTestCase {

    private var directory: URL!
    private var store: AgentGrantStore!
    private var savedHooks: URL!
    private var savedPlayback: PlaybackLauncher!
    private var opened: OpenedLinks!
    private var recipeIds: [String] = []

    final class OpenedLinks: @unchecked Sendable {
        private let lock = NSLock()
        private var links: [URL] = []
        func append(_ url: URL) { lock.lock(); links.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return links }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("openflix-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentGrantStore(directory: directory)

        savedHooks = HookRunner.hooksDirectory
        let hooks = directory.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let veto = hooks.appendingPathComponent("pre-generate")
        try "#!/bin/bash\necho 'vetoed by agent suite test' >&2\nexit 1\n".write(to: veto, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: veto.path)
        HookRunner.hooksDirectory = hooks

        savedPlayback = CLIActions.playback
        let opened = OpenedLinks()
        self.opened = opened
        // No relay: the deep-link route is the one under test.
        CLIActions.playback = PlaybackLauncher(openURL: { opened.append($0) }, relay: nil)
    }

    override func tearDownWithError() throws {
        HookRunner.hooksDirectory = savedHooks
        CLIActions.playback = savedPlayback
        for id in recipeIds { RecipeStore.shared.delete(id) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ name: String, _ arguments: [String: AnyCodableValue]) async throws -> [String: Any] {
        try await CLIActions.run(name, arguments: arguments, context: ActionContext(caller: .localAgent("test")))
    }

    // MARK: - Playback

    func testAFileOpensInOpenFlixThroughItsDeepLink() async throws {
        let file = directory.appendingPathComponent("a clip & more.mp4")
        try Data("x".utf8).write(to: file)
        let result = try await run("play_video", ["path": .string(file.path)])
        XCTAssertEqual(result["via"] as? String, "deep_link")
        let link = try XCTUnwrap(opened.all.first)
        XCTAssertEqual(link.scheme, "openflix")
        XCTAssertEqual(link.host, "open")
        let path = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        XCTAssertEqual(path, URL(fileURLWithPath: file.path).standardizedFileURL.path,
                       "the path survives spaces and & through percent-encoding")
    }

    func testStreamsAndGenerationsGetTheirOwnLinks() throws {
        XCTAssertEqual(PlaybackLauncher.deepLink(for: .stream(URL(string: "https://x.com/a.m3u8")!))?.host, "play")
        XCTAssertEqual(PlaybackLauncher.deepLink(for: .generation("gen-1"))?.absoluteString, "openflix://generation/gen-1")
    }

    func testPlaybackRefusesAmbiguousOrUnsafeTargets() {
        XCTAssertThrowsError(try PlaybackLauncher.target(path: nil, url: nil, generationId: nil))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: "/a", url: "https://b", generationId: nil))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: "relative/clip.mp4", url: nil, generationId: nil))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: "/no/such/file-\(UUID()).mp4", url: nil, generationId: nil))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: nil, url: "file:///etc/passwd", generationId: nil))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: nil, url: "javascript:alert(1)", generationId: nil))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: nil, url: nil, generationId: "../../etc"))
        XCTAssertThrowsError(try PlaybackLauncher.target(path: nil, url: nil, generationId: "openflix-test-no-such-gen"))
    }

    func testPauseAndResumeUseTheAppsOwnLinks() async throws {
        _ = try await run("control_playback", ["action": .string("pause")])
        _ = try await run("control_playback", ["action": .string("resume")])
        XCTAssertEqual(opened.all.map(\.absoluteString), ["openflix://pause", "openflix://play"])
    }

    func testAFinishedGenerationSaysHowToShowIt() {
        let hinted = CLIActions.withPlaybackHints(["id": "g1", "status": "succeeded", "local_path": "/v/g1.mp4"])
        let show = hinted["show_user"] as? [String: Any]
        XCTAssertEqual(show?["in_chat"] as? String, "MEDIA:/v/g1.mp4", "OpenClaw and Hermes attach media with this line")
        XCTAssertEqual((show?["on_this_mac"] as? [String: Any])?["tool"] as? String, "play_video")
        let pending = CLIActions.withPlaybackHints(["id": "g2", "status": "processing"])
        XCTAssertNotNil((pending["show_user"] as? [String: Any])?["when_ready"])
        XCTAssertNil(CLIActions.withPlaybackHints(["id": "g3", "status": "failed"])["show_user"])
    }

    func testThePlayCommandTellsATargetsKindFromItsShape() throws {
        XCTAssertEqual(try Play.resolve("https://x.com/v.mp4"), .stream(URL(string: "https://x.com/v.mp4")!))
        XCTAssertThrowsError(try Play.resolve("/no/such/\(UUID()).mp4"))
        XCTAssertThrowsError(try Play.resolve("openflix-test-unknown-generation"))
    }

    // MARK: - Recipes

    private func saveRecipe(provider: String = "local", model: String = "comfyui") -> CLIRecipe {
        var recipe = CLIRecipe(name: "openflix-test-agent-recipe", promptText: "a {{subject}} at dusk",
                               provider: provider, model: model, durationSeconds: 2)
        recipe.args = [RecipeArg(name: "subject", type: "string", defaultValue: nil, choices: nil, description: "What to show")]
        RecipeStore.shared.save(recipe)
        recipeIds.append(recipe.id)
        return recipe
    }

    func testRecipesAreListedWithTheirArguments() async throws {
        let recipe = saveRecipe()
        let result = try await run("list_recipes", ["search": .string("openflix-test-agent-recipe")])
        let listed = (result["recipes"] as? [[String: Any]])?.first { $0["id"] as? String == recipe.id }
        XCTAssertNotNil(listed)
        XCTAssertNotNil(listed?["args"])
    }

    /// Reaches the engine's gates with the substituted prompt — the hook
    /// vetoes it there, so nothing is submitted anywhere.
    func testRunningARecipeGoesThroughTheEnginesGates() async throws {
        let recipe = saveRecipe()
        do {
            _ = try await run("run_recipe", ["recipe_id": .string(recipe.id), "args": .dictionary(["subject": .string("fox")])])
            XCTFail("the veto hook must stop it")
        } catch let error as OpenFlixError {
            XCTAssertEqual(error.code, "hook_veto")
        }
    }

    func testARecipeMissingARequiredArgumentIsRefused() async throws {
        let recipe = saveRecipe()
        do {
            _ = try await run("run_recipe", ["recipe_id": .string(recipe.id)])
            XCTFail("subject has no default")
        } catch let error as OpenFlixError {
            XCTAssertEqual(error.code, "invalid_input")
        }
    }

    func testARecipeCanBeQuotedForTheBridge() async throws {
        let recipe = saveRecipe(provider: "runway", model: "gen4.5")
        let quote = try await CLIActions.quote("run_recipe", arguments: [
            "recipe_id": .string(recipe.id), "args": .dictionary(["subject": .string("fox")])])
        XCTAssertEqual(quote.provider, "runway")
        XCTAssertGreaterThan(quote.estimatedCostUSD, 0)
        XCTAssertTrue(quote.summary.hasPrefix("Run recipe:"))
    }

    // MARK: - MCP over the bridge

    private func grant(_ effects: [ActionEffect], cap: Double = 0) throws -> (AgentGrant, String) {
        let (g, token) = try store.grant(name: "harbor", effects: effects, dailyCapUSD: cap)
        return (g, token)
    }

    private func mcp(_ router: BridgeRouter, token: String?, _ body: String) async -> (Int, JSONValue) {
        var headers: [String: String] = ["content-type": "application/json"]
        if let token { headers["authorization"] = "Bearer \(token)" }
        let response = await router.handle(BridgeHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8)))
        return (response.status, (try? JSONDecoder().decode(JSONValue.self, from: response.body)) ?? .null)
    }

    private func toolResult(_ reply: JSONValue) -> (isError: Bool, body: JSONValue) {
        let result = reply["result"]
        let text = result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "null"
        return (result?["isError"]?.boolValue ?? false, (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null)
    }

    func testMCPAnswersPostsOnlyAndNeedsAToken() async throws {
        let router = BridgeRouter(grants: store, gate: BridgeGate(grants: store), relay: nil)
        let get = await router.handle(BridgeHTTPRequest(method: "GET", path: "/mcp", headers: [:], body: Data()))
        XCTAssertEqual(get.status, 405, "Hermes's HTTP preflight takes 405 to mean: POST your JSON-RPC")
        XCTAssertEqual(get.headers["Allow"], "POST")
        let (status, _) = await mcp(router, token: nil, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual(status, 401)
    }

    func testBothHandshakeErasWorkWithoutASession() async throws {
        let (_, token) = try grant([.read])
        let router = BridgeRouter(grants: store, gate: BridgeGate(grants: store), relay: nil)
        let (s1, legacy) = await mcp(router, token: token,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(s1, 200)
        XCTAssertNotNil(legacy["result"]?["serverInfo"])
        let (s2, _) = await mcp(router, token: token, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(s2, 202)
        let (s3, modern) = await mcp(router, token: token,
            #"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        XCTAssertEqual(s3, 200)
        XCTAssertTrue(modern["result"]?["instructions"]?.stringValue?.contains("request_spend") ?? false)
        let (s4, _) = await mcp(router, token: token, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(s4, 400, "batches are refused, not half-processed")
    }

    func testTheToolListFollowsTheGrantAndNeverOffersASpendDirectly() async throws {
        let router = BridgeRouter(grants: store, gate: BridgeGate(grants: store), relay: nil)
        let (_, reader) = try grant([.read])
        let (_, readList) = await mcp(router, token: reader, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let readNames = Set(readList["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        XCTAssertTrue(readNames.contains("list_recipes"))
        XCTAssertFalse(readNames.contains("play_video"), "control needs the control effect")
        XCTAssertFalse(readNames.contains("request_spend"))

        let (_, spender) = try store.grant(name: "spender", effects: [.read, .control, .spend], dailyCapUSD: 1)
        let (_, spendList) = await mcp(router, token: spender, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let spendNames = Set(spendList["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        XCTAssertTrue(spendNames.isSuperset(of: ["request_spend", "confirm_spend", "play_video"]))
        for direct in ["generate", "generate_submit", "run_recipe", "retry_generation", "project_run", "evaluate_quality"] {
            XCTAssertFalse(spendNames.contains(direct), direct)
        }
    }

    func testSpendingOverMCPIsQuoteThenConfirmThenReplay() async throws {
        let (_, token) = try store.grant(name: "spender", effects: [.read, .spend], dailyCapUSD: 1)
        let router = BridgeRouter(grants: store, gate: BridgeGate(grants: store), relay: nil)
        let call = { (name: String, args: String) in
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#
        }

        let (_, direct) = await mcp(router, token: token, call("generate_submit", #"{"prompt":"a fox"}"#))
        XCTAssertEqual(toolResult(direct).body["code"]?.stringValue, "USE_REQUEST_SPEND",
                       "a spend tool is not offered remotely; calling it by name points at request_spend")

        let args = #"{"prompt":"a fox","provider":"local","model":"comfyui","duration_seconds":2}"#
        let (_, quoteReply) = await mcp(router, token: token, call("request_spend", #"{"action":"generate_submit","arguments":\#(args)}"#))
        let quote = toolResult(quoteReply)
        XCTAssertFalse(quote.isError)
        let opHash = try XCTUnwrap(quote.body["op_hash"]?.stringValue)

        let (_, confirm) = await mcp(router, token: token, call("confirm_spend", #"{"op_hash":"\#(opHash)"}"#))
        let confirmed = toolResult(confirm)
        XCTAssertTrue(confirmed.isError)
        XCTAssertEqual(confirmed.body["code"]?.stringValue, "HOOK_VETO", "the quoted call reached the engine's gates")
        XCTAssertEqual(store.spentToday("spender"), 0, "a refused spend is not recorded")

        let (_, again) = await mcp(router, token: token, call("confirm_spend", #"{"op_hash":"\#(opHash)"}"#))
        XCTAssertEqual(toolResult(again).body["code"]?.stringValue, "HOOK_VETO",
                       "a retried confirmation replays the first answer — it never runs twice")
    }

    // MARK: - The skill and `integrate`

    func testTheEmbeddedSkillIsTheSkillFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/openflix/SKILL.md")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(EmbeddedSkill.markdown, onDisk.hasSuffix("\n") ? String(onDisk.dropLast()) : onDisk,
                       "run: bash scripts/embed_skill.sh")
    }

    func testTheSkillSatisfiesBothAgentsLoaders() throws {
        let skill = EmbeddedSkill.markdown
        let frontmatter = skill.components(separatedBy: "---")[1]
        XCTAssertTrue(frontmatter.contains("\nname: openflix\n"), "Hermes requires name == directory name")
        XCTAssertTrue(frontmatter.contains("\"openclaw\""))
        XCTAssertTrue(frontmatter.contains("\"bins\": [\"openflix\"]"))
        XCTAssertTrue(frontmatter.contains("\"hermes\""))
        let description = try XCTUnwrap(frontmatter.range(of: "description: \"").map {
            String(frontmatter[$0.upperBound...].prefix { $0 != "\"" })
        })
        XCTAssertLessThanOrEqual(description.count, 1024, "Hermes's description limit")
        let indexed = description.prefix(60).lowercased()
        XCTAssertTrue(indexed.contains("video") && indexed.contains("openflix"),
                      "Hermes's skill index shows 60 characters; they must route: \(indexed)")
        XCTAssertLessThan(skill.utf8.count, 100_000, "Hermes's content limit")
        XCTAssertTrue(skill.contains("never VLC"))
    }

    func testIntegrationShapes() {
        XCTAssertEqual(AgentIntegration.mcpURL(fromRemote: "https://mac.tail.ts.net"), "https://mac.tail.ts.net/mcp")
        XCTAssertEqual(AgentIntegration.mcpURL(fromRemote: "https://mac.tail.ts.net:8443/x?y=1"), "https://mac.tail.ts.net:8443/mcp")
        XCTAssertNil(AgentIntegration.mcpURL(fromRemote: "http://mac.tail.ts.net"), "a bearer token never goes over plain http")
        XCTAssertEqual(AgentIntegration.openclaw.skillRelativePath, ".openclaw/skills/openflix/SKILL.md")
        XCTAssertEqual(AgentIntegration.hermes.skillRelativePath, ".hermes/skills/media/openflix/SKILL.md")
        let remote = AgentIntegration.openclaw.remoteConfig(url: "https://h/mcp")
        let server = ((remote["mcp"] as? [String: Any])?["servers"] as? [String: Any])?["openflix"] as? [String: Any]
        XCTAssertEqual(server?["transport"] as? String, "streamable-http", "OpenClaw assumes SSE for a bare url")
        XCTAssertEqual(AgentIntegration.hermes.addCommand(openflixPath: "/x/openflix"),
                       ["hermes", "mcp", "add", "openflix", "--command", "/x/openflix", "--args", "mcp"])
    }
}
