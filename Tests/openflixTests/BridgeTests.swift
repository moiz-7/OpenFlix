import XCTest
import OpenFlixKit
@testable import openflix

/// The HTTP bridge: request parsing, agent grants, the spend handshake, and
/// the router that ties them together.
///
/// **Nothing here can spend money or reach a network.** Grants live in a temp
/// directory, never `~/.openflix`. Paid providers are only ever *quoted*.
/// The one path that executes a spend uses the keyless `local` provider with a
/// pre-generate hook that vetoes, so `GenerationEngine.submit` refuses before
/// anything is sent anywhere.
final class BridgeTests: XCTestCase {

    private var directory: URL!
    private var store: AgentGrantStore!
    private var savedHooks: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentGrantStore(directory: directory)

        // Veto every generation this test class could possibly start.
        savedHooks = HookRunner.hooksDirectory
        let hooks = directory.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let veto = hooks.appendingPathComponent("pre-generate")
        try "#!/bin/bash\necho 'vetoed by bridge test' >&2\nexit 1\n".write(to: veto, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: veto.path)
        HookRunner.hooksDirectory = hooks
    }

    override func tearDownWithError() throws {
        HookRunner.hooksDirectory = savedHooks
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - HTTP parsing

    private func raw(_ text: String) -> Data { Data(text.utf8) }

    func testACompleteRequestParses() {
        let body = #"{"limit":2}"#
        let result = BridgeHTTPParser.parse(raw(
            "POST /v1/actions/list_generations?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer t\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"))
        guard case .complete(let request) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/actions/list_generations", "the query string is not part of the path")
        XCTAssertEqual(request.header("AUTHORIZATION"), "Bearer t")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testAPartialRequestAsksForMore() {
        XCTAssertEqual(BridgeHTTPParser.parse(raw("GET /v1/health HTTP/1.1\r\nHost: a\r\n")), .incomplete)
        XCTAssertEqual(BridgeHTTPParser.parse(raw("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"")), .incomplete)
    }

    func testFramingThatInvitesSmugglingIsRefused() {
        func status(_ text: String) -> Int? {
            if case .invalid(let status, _) = BridgeHTTPParser.parse(raw(text)) { return status }
            return nil
        }
        XCTAssertEqual(status("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 501)
        XCTAssertEqual(status("POST /x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /x HTTP/1.1\r\n\r\n"), 411)
        XCTAssertEqual(status("POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /x HTTP/1.1\r\nContent-Length: \(BridgeHTTPParser.maxBodyBytes + 1)\r\n\r\n"), 413)
        XCTAssertEqual(status("GARBAGE\r\n\r\n"), 400)
        XCTAssertEqual(status("GET http://evil/x HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(status("GET /x HTTP/1.1\r\n" + String(repeating: "X-A: b\r\n", count: 3_000)), 431)
    }

    func testResponsesCloseAndAreNeverCached() {
        let text = String(data: BridgeHTTPResponse.json(200, .object(["ok": .bool(true)])).serialized(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
    }

    // MARK: - Grants

    func testATokenIsShownOnceAndOnlyItsHashIsStored() throws {
        let (grant, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        XCTAssertTrue(token.hasPrefix("ofx_"))
        XCTAssertGreaterThan(token.count, 40)
        let file = try String(contentsOf: directory.appendingPathComponent("agents.json"), encoding: .utf8)
        XCTAssertFalse(file.contains(token), "the token itself must never be written")
        XCTAssertTrue(file.contains(grant.tokenHash))
        let mode = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("agents.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testOnlyTheRightTokenAuthenticates() throws {
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        XCTAssertEqual(store.authenticate(token: token)?.name, "harbor")
        XCTAssertNil(store.authenticate(token: token + "x"))
        XCTAssertNil(store.authenticate(token: ""))
    }

    func testRegrantingOrRevokingKillsTheOldToken() throws {
        let (_, first) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        let (_, second) = try store.grant(name: "harbor", effects: [.read, .control], dailyCapUSD: 0)
        XCTAssertNil(store.authenticate(token: first))
        XCTAssertEqual(store.authenticate(token: second)?.effects, [.control, .read])
        XCTAssertEqual(store.all().count, 1)
        XCTAssertTrue(try store.revoke(name: "harbor"))
        XCTAssertNil(store.authenticate(token: second))
        XCTAssertFalse(try store.revoke(name: "harbor"))
    }

    func testAnExpiredGrantDoesNotAuthenticate() throws {
        let now = Date()
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0,
                                         expiresAt: now.addingTimeInterval(60), now: now)
        XCTAssertNotNil(store.authenticate(token: token, now: now))
        XCTAssertNil(store.authenticate(token: token, now: now.addingTimeInterval(61)))
    }

    func testSpendingNeedsACap() {
        XCTAssertThrowsError(try store.grant(name: "harbor", effects: [.spend], dailyCapUSD: 0))
        XCTAssertThrowsError(try store.grant(name: "harbor", effects: [.read], dailyCapUSD: .nan))
        XCTAssertThrowsError(try store.grant(name: "../etc", effects: [.read], dailyCapUSD: 0))
    }

    func testTheLedgerCountsPerAgentPerDay() throws {
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.recordSpend("harbor", amountUSD: 0.25, now: day1)
        try store.recordSpend("harbor", amountUSD: 0.5, now: day1)
        try store.recordSpend("other", amountUSD: 1, now: day1)
        try store.recordSpend("harbor", amountUSD: .nan, now: day1)
        try store.recordSpend("harbor", amountUSD: -3, now: day1)
        XCTAssertEqual(store.spentToday("harbor", now: day1), 0.75, accuracy: 1e-9)
        XCTAssertEqual(store.spentToday("harbor", now: day1.addingTimeInterval(86_400 * 2)), 0)
    }

    func testConstantTimeComparisonIsStillAComparison() {
        XCTAssertTrue(AgentGrantStore.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(AgentGrantStore.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(AgentGrantStore.constantTimeEqual("abc", "ab"))
    }

    // MARK: - Authorization by effect

    private func grant(_ effects: [ActionEffect], cap: Double = 0) -> AgentGrant {
        AgentGrant(name: "harbor", tokenHash: "", effects: effects, dailyCapUSD: cap,
                   createdAt: Date(), expiresAt: nil)
    }

    private func descriptor(_ name: String) -> ActionDescriptor { CLIActionCatalog.descriptor(named: name)! }

    func testAGrantOnlyAllowsTheEffectsItNames() {
        let reader = grant([.read])
        XCTAssertNil(BridgeGate.refusal(for: descriptor("list_generations"), grant: reader))
        XCTAssertEqual(BridgeGate.refusal(for: descriptor("generate_poll"), grant: reader)?.code, "GRANT_DENIED")
        XCTAssertEqual(BridgeGate.refusal(for: descriptor("submit_vote"), grant: reader)?.code, "GRANT_DENIED")
        XCTAssertEqual(BridgeGate.refusal(for: descriptor("generate_submit"), grant: reader)?.code, "GRANT_DENIED")
    }

    func testSpendingNeedsBothTheEffectAndACap() {
        XCTAssertEqual(BridgeGate.refusal(for: descriptor("generate_submit"), grant: grant([.spend], cap: 0))?.code,
                       "GRANT_DENIED")
        XCTAssertNil(BridgeGate.refusal(for: descriptor("generate_submit"), grant: grant([.spend], cap: 5)))
    }

    /// Spends the bridge cannot put one price on stay off the bridge.
    func testUnquotableSpendsAreNotAvailableRemotely() {
        let spender = grant([.spend], cap: 5)
        for name in ["generate", "project_run", "evaluate_quality"] {
            XCTAssertEqual(BridgeGate.refusal(for: descriptor(name), grant: spender)?.code,
                           "NOT_AVAILABLE_REMOTELY", name)
        }
    }

    // MARK: - The spend handshake

    private let paid: [String: AnyCodableValue] = [
        "prompt": .string("a fox"), "provider": .string("runway"),
        "model": .string("gen4_turbo"), "duration_seconds": .int(5),
    ]

    private func opHash(_ quote: JSONValue) -> String? { quote["data"]?["op_hash"]?.stringValue }

    func testAQuoteNamesTheCostAndTheCapLeft() async throws {
        let gate = BridgeGate(grants: store)
        let quote = try await gate.quote(action: "generate_submit", arguments: paid, grant: grant([.spend], cap: 1))
        XCTAssertEqual(quote["status"]?.stringValue, "quote")
        XCTAssertEqual(quote["data"]?["estimated_cost_usd"]?.doubleValue ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(quote["data"]?["cap_remaining_usd"]?.doubleValue ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(quote["data"]?["provider"]?.stringValue, "runway")
        XCTAssertNotNil(opHash(quote))
    }

    func testAQuoteOverTheCapIsRefused() async {
        let gate = BridgeGate(grants: store)
        var long = paid
        long["duration_seconds"] = .int(30)
        do {
            _ = try await gate.quote(action: "generate_submit", arguments: long, grant: grant([.spend], cap: 1))
            XCTFail("over the cap")
        } catch let failure as ActionFailure {
            XCTAssertEqual(failure.code, "AGENT_CAP_EXCEEDED")
        } catch { XCTFail("\(error)") }
    }

    func testAnUnpricedPaidModelCannotBeQuoted() async {
        let gate = BridgeGate(grants: store)
        var unpriced = paid
        unpriced["model"] = .string("openflix-test-no-such-model")
        do {
            _ = try await gate.quote(action: "generate_submit", arguments: unpriced, grant: grant([.spend], cap: 100))
            XCTFail("a model with no price cannot be bounded by a cap")
        } catch let error as OpenFlixError {
            XCTAssertEqual(error.code, "budget_exceeded")
        } catch { XCTFail("\(error)") }
    }

    func testAQuoteIsSingleUseAndBoundToItsArguments() async throws {
        let gate = BridgeGate(grants: store)
        let spender = grant([.spend], cap: 1)
        let quote = try await gate.quote(action: "generate_submit", arguments: paid, grant: spender)
        let hash = try XCTUnwrap(opHash(quote))

        var different = paid
        different["prompt"] = .string("a wolf")
        let mismatch = await claimFailure(gate, hash, different, spender)
        XCTAssertEqual(mismatch?.code, "QUOTE_MISMATCH")
        // A mismatch does not burn the quote; the approved call still works once.
        let claimed = try await gate.claim(opHash: hash, action: "generate_submit", arguments: paid, grant: spender)
        XCTAssertEqual(claimed.estimate, 0.25, accuracy: 1e-9)
        let refused = await claimFailure(gate, hash, paid, spender)
        XCTAssertEqual(refused?.code, "QUOTE_STALE")
    }

    func testAQuoteBelongsToTheAgentItWasIssuedTo() async throws {
        let gate = BridgeGate(grants: store)
        let quote = try await gate.quote(action: "generate_submit", arguments: paid, grant: grant([.spend], cap: 1))
        let hash = try XCTUnwrap(opHash(quote))
        var other = grant([.spend], cap: 1)
        other.name = "someone-else"
        let refused = await claimFailure(gate, hash, paid, other)
        XCTAssertEqual(refused?.code, "QUOTE_STALE")
    }

    func testAQuoteExpires() async throws {
        let clock = MutableClock()
        let gate = BridgeGate(grants: store, now: { clock.now })
        let spender = grant([.spend], cap: 1)
        let quote = try await gate.quote(action: "generate_submit", arguments: paid, grant: spender)
        let hash = try XCTUnwrap(opHash(quote))
        clock.now = clock.now.addingTimeInterval(BridgeGate.quoteTTL + 1)
        let refused = await claimFailure(gate, hash, paid, spender)
        XCTAssertEqual(refused?.code, "QUOTE_STALE")
    }

    /// Spending that landed after the quote counts: the cap is checked again
    /// at execution.
    func testTheCapIsCheckedAgainWhenTheQuoteIsUsed() async throws {
        let gate = BridgeGate(grants: store)
        let spender = grant([.spend], cap: 1)
        let quote = try await gate.quote(action: "generate_submit", arguments: paid, grant: spender)
        let hash = try XCTUnwrap(opHash(quote))
        try store.recordSpend("harbor", amountUSD: 0.9)
        let refused = await claimFailure(gate, hash, paid, spender)
        XCTAssertEqual(refused?.code, "AGENT_CAP_EXCEEDED")
    }

    func testClaimingWithoutAQuoteAsksForOne() async {
        let gate = BridgeGate(grants: store)
        let refused = await claimFailure(gate, nil, paid, grant([.spend], cap: 1))
        XCTAssertEqual(refused?.errorClass, .approvalRequired)
    }

    // MARK: - Idempotency

    func testAKeyReplaysItsFirstAnswerAndCannotBeReusedForAnotherRequest() async throws {
        let gate = BridgeGate(grants: store)
        let agent = grant([.spend], cap: 1)
        guard case .proceed = try await gate.begin(key: "k", grant: agent, requestDigest: "d1") else {
            return XCTFail("first use proceeds")
        }
        do {
            _ = try await gate.begin(key: "k", grant: agent, requestDigest: "d1")
            XCTFail("still running")
        } catch let failure as ActionFailure { XCTAssertEqual(failure.code, "IN_PROGRESS") }

        let answer = JSONValue.object(["status": .string("ok")])
        await gate.finish(key: "k", grant: agent, requestDigest: "d1", response: answer)
        guard case .replay(let replayed) = try await gate.begin(key: "k", grant: agent, requestDigest: "d1") else {
            return XCTFail("a finished key replays")
        }
        XCTAssertEqual(replayed, answer)
        do {
            _ = try await gate.begin(key: "k", grant: agent, requestDigest: "d2")
            XCTFail("same key, different request")
        } catch let failure as ActionFailure { XCTAssertEqual(failure.code, "IDEMPOTENCY_KEY_REUSED") }
    }

    // MARK: - Router

    private func router(relay: AppRelay? = nil) -> BridgeRouter {
        BridgeRouter(grants: store, gate: BridgeGate(grants: store), relay: relay)
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: String = "",
                         headers: [String: String] = [:]) -> BridgeHTTPRequest {
        var all = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        if let token { all["authorization"] = "Bearer \(token)" }
        return BridgeHTTPRequest(method: method, path: path, headers: all, body: Data(body.utf8))
    }

    private func json(_ response: BridgeHTTPResponse) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: response.body)) ?? .null
    }

    func testHealthNeedsNoTokenAndEverythingElseDoes() async {
        let r = router()
        let health = await r.handle(request("GET", "/v1/health"))
        XCTAssertEqual(health.status, 200)
        let manifest = await r.handle(request("GET", "/v1/manifest"))
        XCTAssertEqual(manifest.status, 401)
        XCTAssertEqual(manifest.headers["WWW-Authenticate"], "Bearer")
        let action = await r.handle(request("POST", "/v1/actions/list_providers", token: "ofx_wrong"))
        XCTAssertEqual(action.status, 401)
    }

    func testBrowserRequestsAreRefusedEvenWithAToken() async throws {
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        let response = await router().handle(request("GET", "/v1/manifest", token: token,
                                                     headers: ["Origin": "https://example.com"]))
        XCTAssertEqual(response.status, 403)
    }

    func testTheManifestOnlyListsWhatTheGrantAllows() async throws {
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        let manifest = json(await router().handle(request("GET", "/v1/manifest", token: token)))
        let names = Set(manifest["actions"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        XCTAssertTrue(names.contains("list_generations"))
        XCTAssertFalse(names.contains("generate_submit"))
        XCTAssertFalse(names.contains("submit_vote"))
        XCTAssertEqual(manifest["app"]?["available"]?.boolValue, false)
        XCTAssertTrue(manifest["actions"]?.arrayValue?.allSatisfy { $0["host"]?.stringValue == "openflix-cli" } ?? false)
    }

    func testARunGoesThroughTheSameValidationAsEveryOtherSurface() async throws {
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        let r = router()
        let ok = await r.handle(request("POST", "/v1/actions/list_providers", token: token, body: "{}"))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(json(ok)["status"]?.stringValue, "ok")

        let bad = await r.handle(request("POST", "/v1/actions/list_generations", token: token, body: #"{"limit":-1}"#))
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(json(bad)["error"]?["details"]?["argument"]?.stringValue, "limit")

        let notObject = await r.handle(request("POST", "/v1/actions/list_providers", token: token, body: "[1]"))
        XCTAssertEqual(notObject.status, 400)

        let denied = await r.handle(request("POST", "/v1/actions/submit_vote", token: token, body: "{}"))
        XCTAssertEqual(denied.status, 403)

        let missing = await r.handle(request("POST", "/v1/actions/rm_rf", token: token, body: "{}"))
        XCTAssertEqual(missing.status, 404)

        let wrongMethod = await r.handle(request("GET", "/v1/actions/list_providers", token: token))
        XCTAssertEqual(wrongMethod.status, 405)
    }

    /// The whole handshake over the router, ending in an execution that the
    /// pre-generate hook vetoes — so it proves the quoted arguments reached
    /// `GenerationEngine.submit` without anything leaving this machine.
    func testTheSpendHandshakeEndToEnd() async throws {
        let (_, token) = try store.grant(name: "harbor", effects: [.spend], dailyCapUSD: 1)
        let r = router()
        let args = #"{"prompt":"a fox","provider":"local","model":"comfyui","duration_seconds":2}"#

        let noKey = await r.handle(request("POST", "/v1/actions/generate_submit", token: token, body: args))
        XCTAssertEqual(noKey.status, 400)

        let noQuote = await r.handle(request("POST", "/v1/actions/generate_submit", token: token, body: args,
                                             headers: ["Idempotency-Key": "k1"]))
        XCTAssertEqual(noQuote.status, 428)

        let quote = json(await r.handle(request("POST", "/v1/actions/generate_submit:preflight", token: token, body: args)))
        let hash = try XCTUnwrap(opHash(quote))

        let run = await r.handle(request("POST", "/v1/actions/generate_submit", token: token, body: args,
                                         headers: ["Idempotency-Key": "k2", "OpenFlix-Quote": hash]))
        XCTAssertEqual(json(run)["error"]?["code"]?.stringValue, "HOOK_VETO",
                       "the quoted call reached the engine's gates, and the hook stopped it there")
        XCTAssertEqual(store.spentToday("harbor"), 0, "a refused generation is not recorded as spend")

        let replay = await r.handle(request("POST", "/v1/actions/generate_submit", token: token, body: args,
                                            headers: ["Idempotency-Key": "k2", "OpenFlix-Quote": hash]))
        XCTAssertEqual(replay.headers["Idempotent-Replayed"], "true")
        XCTAssertEqual(replay.status, run.status)

        let reused = await r.handle(request("POST", "/v1/actions/generate_submit", token: token, body: args,
                                            headers: ["Idempotency-Key": "k3", "OpenFlix-Quote": hash]))
        XCTAssertEqual(json(reused)["error"]?["code"]?.stringValue, "QUOTE_STALE")
    }

    func testAnAppActionWhileTheAppIsClosedIsUnavailable() async throws {
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        let relay = AppRelay(socketPath: directory.appendingPathComponent("no.sock").path)
        let response = await router(relay: relay).handle(request("POST", "/v1/actions/player_state", token: token, body: "{}"))
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(json(response)["error"]?["code"]?.stringValue, "APP_UNAVAILABLE")
    }

    // MARK: - App relay (against a fake app socket)

    /// A stand-in for the app's MCP socket: answers one JSON-RPC line per
    /// connection, shaped like the real app's replies.
    private final class FakeAppSocket: @unchecked Sendable {
        let path: String
        private let fd: Int32
        private(set) var calls: [String] = []
        private let lock = NSLock()

        init(directory: URL) throws {
            // sun_path holds 104 bytes; the per-test directory is too deep for
            // it, so the socket sits directly in the temp directory.
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("ofx-\(UUID().uuidString.prefix(8)).sock").path
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw NSError(domain: "fake-socket", code: 2)
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw NSError(domain: "fake-socket", code: 1) }
            Thread.detachNewThread { [self] in self.serve() }
        }

        func close() {
            Darwin.close(fd)
            unlink(path)
        }

        private func serve() {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let n = recv(client, &buffer, buffer.count, 0)
                guard n > 0,
                      let request = try? JSONDecoder().decode(JSONValue.self, from: Data(buffer[0..<n].prefix { $0 != 0x0A })) else {
                    Darwin.close(client); continue
                }
                let method = request["method"]?.stringValue ?? ""
                lock.lock(); calls.append(method + ":" + (request["params"]?["name"]?.stringValue ?? "")); lock.unlock()
                let result: JSONValue
                if method == "tools/list" {
                    result = .object(["tools": .array([
                        .object(["name": .string("library_search"), "description": .string("Search the library"),
                                 "inputSchema": JSONSchema.object(required: ["query"], properties: ["query": JSONSchema.string("What to find")]),
                                 "annotations": .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)])]),
                        .object(["name": .string("player_control"), "description": .string("Drive the player"),
                                 "inputSchema": JSONSchema.object(properties: ["action": JSONSchema.string("play or pause")]),
                                 "annotations": .object(["readOnlyHint": .bool(false), "destructiveHint": .bool(false),
                                                         "openWorldHint": .bool(false)])]),
                    ])])
                } else {
                    result = .object(["structuredContent": .object(["hits": .int(1)]),
                                      "content": .array([.object(["type": .string("text"), "text": .string(#"{"hits":1}"#)])])])
                }
                let reply = JSONValue.object(["jsonrpc": .string("2.0"), "id": .int(1), "result": result]).jsonString() + "\n"
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                Darwin.close(client)
            }
        }
    }

    func testTheAppsToolsAreRelayedWithEffectsFromTheirOwnAnnotations() async throws {
        let app = try FakeAppSocket(directory: directory)
        defer { app.close() }
        let descriptors = try await AppRelay(socketPath: app.path).descriptors()
        XCTAssertEqual(descriptors.first { $0.name == "library_search" }?.effect, .read)
        XCTAssertEqual(descriptors.first { $0.name == "player_control" }?.effect, .control)
        XCTAssertTrue(descriptors.allSatisfy(\.returnsUntrustedText), "media text is never trusted")
    }

    func testAReadGrantCanSearchTheLibraryButNotDriveThePlayer() async throws {
        let app = try FakeAppSocket(directory: directory)
        defer { app.close() }
        let (_, token) = try store.grant(name: "harbor", effects: [.read], dailyCapUSD: 0)
        let r = router(relay: AppRelay(socketPath: app.path))

        let manifest = json(await r.handle(request("GET", "/v1/manifest", token: token)))
        XCTAssertEqual(manifest["app"]?["available"]?.boolValue, true)
        let appActions = manifest["actions"]?.arrayValue?.filter { $0["host"]?.stringValue == AppRelay.host }
            .compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(appActions, ["library_search"])

        let search = await r.handle(request("POST", "/v1/actions/library_search", token: token, body: #"{"query":"beach"}"#))
        XCTAssertEqual(search.status, 200)
        XCTAssertEqual(json(search)["data"]?["hits"]?.intValue, 1)

        let missingQuery = await r.handle(request("POST", "/v1/actions/library_search", token: token, body: "{}"))
        XCTAssertEqual(missingQuery.status, 400, "the bridge validates app arguments too")

        let control = await r.handle(request("POST", "/v1/actions/player_control", token: token, body: #"{"action":"play"}"#))
        XCTAssertEqual(control.status, 403)
        XCTAssertFalse(app.calls.contains("tools/call:player_control"), "a denied call never reaches the app")
    }

    // MARK: - Helpers

    /// The refusal a claim produces, or nil if it succeeded.
    private func claimFailure(_ gate: BridgeGate, _ hash: String?, _ args: [String: AnyCodableValue],
                              _ agent: AgentGrant) async -> ActionFailure? {
        do {
            _ = try await gate.claim(opHash: hash, action: "generate_submit", arguments: args, grant: agent)
            return nil
        } catch {
            return error as? ActionFailure
        }
    }

    private final class MutableClock: @unchecked Sendable {
        var now = Date()
    }
}
