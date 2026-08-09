import XCTest
@testable import openflix
@testable import OpenFlixKit

/// Coverage for the dual-era MCP protocol core and the depth features added
/// with it (C0-2 + C3-1).
///
/// The point of every test in the first half is one row of the 2026-07-28
/// compatibility matrix: a modern client must be served **without a handshake**,
/// a legacy client must keep working **unchanged**, and a client naming a
/// revision we do not serve must get `-32022` with the list to retry with rather
/// than the silence a legacy-only server answers with.
final class MCPDualEraTests: XCTestCase {

    // MARK: - Helpers

    private func request(_ method: String,
                         id: Int = 1,
                         params: [String: AnyCodableValue]? = nil) -> MCPRequest {
        MCPRequest(jsonrpc: "2.0", id: .int(id), method: method, params: params)
    }

    /// Params carrying the modern per-request `_meta`, which is the only thing
    /// that tells a stateless server who it is talking to.
    private func modernParams(version: String = MCPProtocolVersion.modern,
                              extra: [String: AnyCodableValue] = [:]) -> [String: AnyCodableValue] {
        var params = extra
        params["_meta"] = .dictionary([
            MCPRequestMetaKey.protocolVersion: .string(version),
            MCPRequestMetaKey.clientCapabilities: .dictionary([:]),
            MCPRequestMetaKey.clientInfo: .dictionary([
                "name": .string("dual-era-tests"),
                "version": .string("1"),
            ]),
        ])
        return params
    }

    private func toolWire(named name: String, in response: MCPResponse?) -> [String: AnyCodableValue]? {
        guard case .array(let tools)? = response?.result?["tools"] else { return nil }
        for tool in tools where tool["name"]?.stringValue == name {
            return tool.objectValue
        }
        return nil
    }

    private func encodes(_ response: MCPResponse) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func recipe(name: String = "Neon Alley",
                        prompt: String = "a {{subject}} in a neon alley, {{style}}",
                        args: [RecipeArg]?) -> CLIRecipe {
        var r = CLIRecipe(name: name, promptText: prompt, negativePromptText: "blurry",
                          provider: "runway", model: "gen4", aspectRatio: "16:9",
                          durationSeconds: 8)
        r.args = args
        return r
    }

    // MARK: - Revision list

    func testTheModernRevisionIsTheCurrentSpecRevision() {
        XCTAssertEqual(MCPProtocolVersion.modern, "2026-07-28")
    }

    func testSupportedRevisionsAreNewestFirst() {
        XCTAssertEqual(MCPProtocolVersion.supported,
                       ["2026-07-28", "2025-06-18", "2024-11-05"])
    }

    /// Claiming a revision whose behaviour was never read is how a client ends
    /// up with a subtly wrong answer instead of an honest `-32022`.
    func testUnverifiedRevisionsAreNotClaimed() {
        XCTAssertFalse(MCPProtocolVersion.isSupported("2025-11-25"))
        XCTAssertFalse(MCPProtocolVersion.isSupported("2025-03-26"))
        XCTAssertFalse(MCPProtocolVersion.isSupported("1900-01-01"))
    }

    func testTheRevisionTheCLIShippedWithIsStillServed() {
        XCTAssertTrue(MCPProtocolVersion.isSupported("2024-11-05"))
    }

    func testNegotiateLegacyEchoesAServedRevision() {
        XCTAssertEqual(MCPProtocolVersion.negotiateLegacy(requested: "2025-06-18"), "2025-06-18")
        XCTAssertEqual(MCPProtocolVersion.negotiateLegacy(requested: "2024-11-05"), "2024-11-05")
    }

    func testNegotiateLegacyFloorsAnUnknownOrAbsentRequest() {
        XCTAssertEqual(MCPProtocolVersion.negotiateLegacy(requested: "1999-01-01"), "2024-11-05")
        XCTAssertEqual(MCPProtocolVersion.negotiateLegacy(requested: nil), "2024-11-05")
    }

    /// The modern revision deleted the handshake, so a version reached *through*
    /// the handshake can never be it.
    func testNegotiateLegacyNeverEchoesTheModernRevision() {
        XCTAssertEqual(MCPProtocolVersion.negotiateLegacy(requested: MCPProtocolVersion.modern),
                       MCPProtocolVersion.legacy)
    }

    // MARK: - Per-request era classification

    func testARequestWithoutMetaIsLegacy() {
        let envelope = MCPRequestEnvelope.classify(request("tools/list"))
        XCTAssertEqual(envelope.era, .legacy)
        XCTAssertNil(envelope.protocolVersion)
        XCTAssertFalse(envelope.isUnsupportedVersion)
    }

    func testARequestCarryingAProtocolVersionIsModern() {
        let envelope = MCPRequestEnvelope.classify(request("tools/list", params: modernParams()))
        XCTAssertEqual(envelope.era, .modern)
        XCTAssertEqual(envelope.protocolVersion, MCPProtocolVersion.modern)
        XCTAssertEqual(envelope.clientName, "dual-era-tests")
        XCTAssertEqual(envelope.clientVersion, "1")
    }

    /// `server/discover` is the probe a dual-era client sends before anything
    /// else; a legacy client has no reason to send it, so it is modern by
    /// definition even with no `_meta` at all.
    func testDiscoverIsModernEvenWithoutMeta() {
        XCTAssertEqual(MCPRequestEnvelope.classify(request("server/discover")).era, .modern)
    }

    func testAModernRequestNamingAnUnservedRevisionIsFlagged() {
        let envelope = MCPRequestEnvelope.classify(
            request("tools/list", params: modernParams(version: "1900-01-01")))
        XCTAssertTrue(envelope.isUnsupportedVersion)
    }

    /// A legacy client has no `_meta`, so it can never trip the modern-era
    /// version check — that is what stops dual-era support breaking today's
    /// clients.
    func testALegacyRequestIsNeverFlaggedAsUnsupported() {
        let params: [String: AnyCodableValue] = ["protocolVersion": .string("1999-01-01")]
        let envelope = MCPRequestEnvelope.classify(request("initialize", params: params))
        XCTAssertEqual(envelope.era, .legacy)
        XCTAssertFalse(envelope.isUnsupportedVersion)
    }

    // MARK: - Modern path: no handshake

    func testDiscoverIsAnsweredWithNoHandshakeEverSent() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("server/discover", params: modernParams()))

        let handshook = await server.didHandshake
        XCTAssertFalse(handshook, "server/discover must not require or imply a handshake")
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.result?["serverInfo"]?["name"]?.stringValue, "openflix")
        XCTAssertEqual(response?.result?["serverInfo"]?["version"]?.stringValue, OpenFlixVersion.current)
    }

    func testDiscoverAdvertisesEveryServedRevision() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("server/discover"))
        guard case .array(let versions)? = response?.result?["supportedVersions"] else {
            return XCTFail("server/discover did not advertise supportedVersions")
        }
        XCTAssertEqual(versions.compactMap(\.stringValue), MCPProtocolVersion.supported)
    }

    func testDiscoverAdvertisesToolsResourcesPromptsAndCompletions() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("server/discover"))
        let capabilities = response?.result?["capabilities"]?.objectValue
        XCTAssertNotNil(capabilities?["tools"])
        XCTAssertNotNil(capabilities?["resources"])
        XCTAssertNotNil(capabilities?["prompts"])
        XCTAssertNotNil(capabilities?["completions"])
    }

    /// We send no list-changed notifications, so advertising `listChanged`
    /// would be a lie a client would then sit and wait on.
    func testListChangedIsNeverAdvertised() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("server/discover"))
        XCTAssertFalse(encodes(MCPResponse.success(id: nil, result: response?.result ?? .null))?
            .contains("listChanged") ?? true)
    }

    /// The row from the compatibility matrix that this whole workstream exists
    /// for: a modern client that never handshakes still gets its tools.
    func testToolsListIsServedOnPerRequestMetaAlone() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("tools/list", params: modernParams()))
        let handshook = await server.didHandshake
        XCTAssertFalse(handshook)
        XCTAssertNil(response?.error)
        XCTAssertNotNil(toolWire(named: "generate", in: response))
    }

    // MARK: - Legacy path: unchanged

    func testInitializeStillWorksExactlyAsBefore() async {
        let server = MCPServer()
        let params: [String: AnyCodableValue] = [
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .dictionary([:]),
            "clientInfo": .dictionary(["name": .string("test"), "version": .string("1.0")]),
        ]
        let response = await server.handleRequest(request("initialize", params: params))
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.result?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertEqual(response?.result?["serverInfo"]?["name"]?.stringValue, "openflix")
        let handshook = await server.didHandshake
        XCTAssertTrue(handshook)
    }

    func testInitializeEchoesANewerServedRevisionWhenAsked() async {
        let server = MCPServer()
        let response = await server.handleRequest(
            request("initialize", params: ["protocolVersion": .string("2025-06-18")]))
        XCTAssertEqual(response?.result?["protocolVersion"]?.stringValue, "2025-06-18")
    }

    func testInitializeFloorsAnUnservedRevisionRatherThanFailing() async {
        let server = MCPServer()
        let response = await server.handleRequest(
            request("initialize", params: ["protocolVersion": .string("1999-01-01")]))
        XCTAssertNil(response?.error, "a legacy handshake must never fail with -32022")
        XCTAssertEqual(response?.result?["protocolVersion"]?.stringValue, "2024-11-05")
    }

    func testALegacyClientCanHandshakeThenListToolsOnTheSameSession() async {
        let server = MCPServer()
        _ = await server.handleRequest(
            request("initialize", params: ["protocolVersion": .string("2024-11-05")]))
        let notification = await server.handleRequest(request("notifications/initialized"))
        XCTAssertNil(notification)
        let list = await server.handleRequest(request("tools/list", id: 2, params: [:]))
        XCTAssertNil(list?.error)
        XCTAssertNotNil(toolWire(named: "generate", in: list))
    }

    /// Both eras on one session, which is what "dual-era" has to mean on a
    /// single stdio pipe.
    func testBothErasAreServedOnOneSession() async {
        let server = MCPServer()
        let legacy = await server.handleRequest(
            request("initialize", params: ["protocolVersion": .string("2024-11-05")]))
        let modern = await server.handleRequest(
            request("tools/list", id: 2, params: modernParams()))
        XCTAssertEqual(legacy?.result?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertNil(modern?.error)
    }

    // MARK: - resultType and cache hints

    func testEveryResultCarriesResultTypeComplete() async {
        let server = MCPServer()
        for method in ["server/discover", "initialize", "ping", "shutdown",
                       "tools/list", "resources/list", "resources/templates/list",
                       "prompts/list"] {
            let response = await server.handleRequest(request(method, params: [:]))
            XCTAssertEqual(response?.result?["resultType"]?.stringValue, "complete",
                           "\(method) result is missing the 2026-07-28 discriminator")
        }
    }

    func testListResultsCarryTheCacheHints() async {
        let server = MCPServer()
        for method in ["tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
            let response = await server.handleRequest(request(method, params: [:]))
            XCTAssertEqual(response?.result?["cacheScope"]?.stringValue, "private",
                           "\(method) must not invite a shared cache of one person's data")
            if case .int(let ttl)? = response?.result?["ttlMs"] {
                XCTAssertGreaterThan(ttl, 0, "\(method) ttlMs")
            } else {
                XCTFail("\(method) is missing ttlMs")
            }
        }
    }

    // MARK: - UnsupportedProtocolVersionError

    func testAnUnservedRevisionFailsWithMinus32022AndTheRetryList() async {
        let server = MCPServer()
        let response = await server.handleRequest(
            request("tools/list", params: modernParams(version: "1900-01-01")))

        XCTAssertEqual(response?.error?.code, -32022)
        XCTAssertEqual(response?.error?.code, MCPModernErrorCode.unsupportedProtocolVersion)
        XCTAssertEqual(response?.error?.data?["requested"]?.stringValue, "1900-01-01")
        guard case .array(let supported)? = response?.error?.data?["supported"] else {
            return XCTFail("-32022 must carry the list to retry with")
        }
        XCTAssertEqual(supported.compactMap(\.stringValue), MCPProtocolVersion.supported)
    }

    /// The check runs before dispatch, so it is not something a client can slip
    /// past by picking a different method.
    func testTheVersionCheckAppliesToEveryMethod() async {
        let server = MCPServer()
        for method in ["server/discover", "tools/call", "resources/read", "prompts/get", "ping"] {
            let response = await server.handleRequest(
                request(method, params: modernParams(version: "1900-01-01")))
            XCTAssertEqual(response?.error?.code, -32022, "\(method) skipped the version gate")
        }
    }

    func testNotificationsAreAnsweredWithSilence() async {
        let server = MCPServer()
        let initialized = await server.handleRequest(request("notifications/initialized"))
        let cancelled = await server.handleRequest(request("notifications/cancelled"))
        XCTAssertNil(initialized)
        XCTAssertNil(cancelled)
    }

    func testAnUnknownMethodIsStillMethodNotFound() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("does/not/exist", params: modernParams()))
        XCTAssertEqual(response?.error?.code, MCPErrorCode.methodNotFound)
    }

    // MARK: - Tool annotations

    func testEveryToolNameIsLegalAtTheModelBoundary() {
        XCTAssertTrue(MCPToolRegistry.allToolNamesAreWellFormed)
        // A dot is legal in a record id and illegal in a tool name — the two
        // grammars are deliberately different.
        XCTAssertFalse(MCPToolName.isWellFormed("openflix.generate"))
        XCTAssertTrue(MCPIdentifier.isWellFormed("openflix.generate"))
    }

    func testTheToolCountIsUnchanged() {
        XCTAssertEqual(MCPToolRegistry.allTools.count, 15)
    }

    func testEveryToolArrivesAnnotatedOnTheWire() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("tools/list", params: modernParams()))
        for tool in MCPToolRegistry.allTools {
            let wire = toolWire(named: tool.name, in: response)
            XCTAssertNotNil(wire?["annotations"], "\(tool.name) is unannotated, so a client must assume it is destructive and open-world")
            XCTAssertNotNil(wire?["title"], "\(tool.name) has no display title")
        }
    }

    /// The safety claim this table exists to make. An unannotated tool is
    /// assumed destructive, so marking a tool that charges the user's provider
    /// `destructiveHint: false` would make it *less* guarded than it is today.
    func testEveryToolThatSpendsMoneyStaysMarkedDestructive() {
        for name in ["generate", "generate_submit", "retry_generation"] {
            guard let tool = MCPToolRegistry.allTools.first(where: { $0.name == name }) else {
                return XCTFail("missing tool \(name)")
            }
            XCTAssertFalse(tool.annotations.readOnlyHint, "\(name) spends money; it is not a read")
            XCTAssertTrue(tool.annotations.destructiveHint, "\(name) charges the user irreversibly")
            XCTAssertFalse(tool.annotations.idempotentHint, "\(name) bills again on every call")
            XCTAssertTrue(tool.annotations.openWorldHint, "\(name) calls a remote provider")
        }
    }

    func testCancelIsDestructiveAndNotIdempotent() {
        guard let tool = MCPToolRegistry.allTools.first(where: { $0.name == "cancel_generation" }) else {
            return XCTFail("missing cancel_generation")
        }
        XCTAssertFalse(tool.annotations.readOnlyHint)
        XCTAssertTrue(tool.annotations.destructiveHint)
        XCTAssertFalse(tool.annotations.idempotentHint)
    }

    func testLocalReadsAreAnnotatedReadOnlyAndClosedWorld() {
        let reads = ["list_generations", "get_generation", "list_providers",
                     "get_metrics", "budget_status", "health_check", "project_run"]
        for name in reads {
            guard let tool = MCPToolRegistry.allTools.first(where: { $0.name == name }) else {
                return XCTFail("missing tool \(name)")
            }
            XCTAssertTrue(tool.annotations.readOnlyHint, "\(name) should be a read")
            XCTAssertFalse(tool.annotations.openWorldHint, "\(name) makes no network call")
        }
    }

    /// `submit_feedback`'s whole promise is that the score never leaves the
    /// machine, and `submit_vote`'s whole promise is that it does. The wire now
    /// says which is which.
    func testTheLocalOnlyToolIsTheOnlyWriteThatIsClosedWorld() {
        let feedback = MCPToolRegistry.allTools.first { $0.name == "submit_feedback" }
        let vote = MCPToolRegistry.allTools.first { $0.name == "submit_vote" }
        XCTAssertEqual(feedback?.annotations.openWorldHint, false)
        XCTAssertEqual(vote?.annotations.openWorldHint, true)
        XCTAssertEqual(vote?.annotations.idempotentHint, true, "the registry dedupes, so retrying is safe")
    }

    /// The schema says `destructiveHint` and `idempotentHint` are meaningful
    /// only when `readOnlyHint` is false, so a read must not ship them.
    func testMeaninglessHintsAreOmittedForReadOnlyTools() {
        let wire = MCPToolAnnotations.localRead.toAnyCodable().objectValue
        XCTAssertEqual(wire?["readOnlyHint"]?.boolValue, true)
        XCTAssertEqual(wire?["openWorldHint"]?.boolValue, false)
        XCTAssertNil(wire?["destructiveHint"])
        XCTAssertNil(wire?["idempotentHint"])
    }

    func testAWriteShipsAllFourHints() {
        let wire = MCPToolAnnotations(readOnly: false, destructive: true,
                                      idempotent: false, openWorld: true)
            .toAnyCodable().objectValue
        XCTAssertEqual(wire?["destructiveHint"]?.boolValue, true)
        XCTAssertEqual(wire?["idempotentHint"]?.boolValue, false)
    }

    // MARK: - outputSchema and structuredContent

    func testGenerationReturningToolsDeclareTheSameOutputSchema() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("tools/list", params: modernParams()))
        for name in ["generate", "generate_submit", "generate_poll", "get_generation", "retry_generation"] {
            let schema = toolWire(named: name, in: response)?["outputSchema"]
            XCTAssertEqual(schema?["type"]?.stringValue, "object", "\(name) outputSchema")
            guard case .array(let required)? = schema?["required"] else {
                return XCTFail("\(name) outputSchema has no required keys")
            }
            XCTAssertEqual(Set(required.compactMap(\.stringValue)),
                           ["id", "status", "provider", "model", "prompt"])
        }
    }

    /// A tool that declares `outputSchema` must return `structuredContent`, and
    /// the text block stays for clients that never learned to read it.
    func testAToolCallReturnsBothTextAndStructuredContent() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("tools/call", params: modernParams(extra: [
            "name": .string("list_providers"),
            "arguments": .dictionary([:]),
        ])))

        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.result?["resultType"]?.stringValue, "complete")

        guard case .array(let content)? = response?.result?["content"],
              let text = content.first?["text"]?.stringValue else {
            return XCTFail("tools/call lost its text content block")
        }
        XCTAssertTrue(text.contains("providers"))

        let structured = response?.result?["structuredContent"]?.objectValue
        XCTAssertNotNil(structured?["providers"], "structuredContent must satisfy the declared outputSchema")
        XCTAssertNotNil(structured?["count"])
    }

    func testAToolErrorIsAResultNotAJSONRPCError() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("tools/call", params: modernParams(extra: [
            "name": .string("get_generation"),
            "arguments": .dictionary(["generation_id": .string("no-such-generation-id")]),
        ])))
        XCTAssertNil(response?.error, "MCP convention: a tool failure is a result with isError")
        XCTAssertEqual(response?.result?["isError"]?.boolValue, true)
        XCTAssertEqual(response?.result?["resultType"]?.stringValue, "complete")
    }

    // MARK: - Encoding safety

    /// A `Double.nan` used to degrade the text path to `"{}"`; through
    /// `structuredContent` it would have thrown at encode time, and a reply that
    /// never gets written is indistinguishable from a hang on a request/response
    /// pipe.
    func testNonFiniteNumbersBecomeNullRatherThanAnUnwritableReply() {
        let value = AnyCodableValue.sanitized([
            "score": Double.nan,
            "cost": Double.infinity,
            "ok": 1.5,
            "name": "x",
        ])
        XCTAssertEqual(value["score"]?.isNull, true)
        XCTAssertEqual(value["cost"]?.isNull, true)
        XCTAssertEqual(value["ok"]?.doubleValue, 1.5)
        XCTAssertEqual(value["name"]?.stringValue, "x")
        XCTAssertNotNil(encodes(MCPResponse.success(id: .int(1), result: value)))
    }

    func testSanitizerPreservesNestedStructureAndBooleans() {
        let value = AnyCodableValue.sanitized([
            "flag": true,
            "nested": ["list": [1, 2, 3]],
        ])
        XCTAssertEqual(value["flag"]?.boolValue, true)
        XCTAssertEqual(value["nested"]?["list"]?.arrayValue?.compactMap(\.intValue), [1, 2, 3])
    }

    // MARK: - Identifier grammar

    /// `GenerationStore` resolves an id straight into
    /// `~/.openflix/generations/<id>.json`, and an MCP argument is a string a
    /// model chose, possibly while reading someone else's text.
    func testTraversalAndSeparatorsAreRejectedAsIdentifiers() {
        for bad in ["../../etc/passwd", "a/b", "..", ".hidden", "", String(repeating: "a", count: 129)] {
            XCTAssertFalse(MCPIdentifier.isWellFormed(bad), "accepted \(bad)")
        }
    }

    func testRealIdentifiersAreAccepted() {
        XCTAssertTrue(MCPIdentifier.isWellFormed(UUID().uuidString))
        XCTAssertTrue(MCPIdentifier.isWellFormed("gen_2026-08-08.01"))
    }

    func testAToolRefusesATraversalIdentifierBeforeItReachesTheStore() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("tools/call", params: modernParams(extra: [
            "name": .string("get_generation"),
            "arguments": .dictionary(["generation_id": .string("../../../../etc/passwd")]),
        ])))
        XCTAssertEqual(response?.result?["isError"]?.boolValue, true)
        guard case .array(let content)? = response?.result?["content"],
              let text = content.first?["text"]?.stringValue else {
            return XCTFail("no error text")
        }
        XCTAssertTrue(text.contains("valid id"), "got: \(text)")
    }

    // MARK: - Resources

    func testResourceTemplatesCoverTheUnboundedSpace() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("resources/templates/list", params: modernParams()))
        guard case .array(let templates)? = response?.result?["resourceTemplates"] else {
            return XCTFail("no resource templates")
        }
        let uris = templates.compactMap { $0["uriTemplate"]?.stringValue }
        XCTAssertEqual(Set(uris), ["openflix://generation/{id}", "openflix://recipe/{id}"])
    }

    func testTheThreeStaticResourcesAreStillListed() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("resources/list", params: modernParams()))
        guard case .array(let resources)? = response?.result?["resources"] else {
            return XCTFail("no resources")
        }
        XCTAssertEqual(Set(resources.compactMap { $0["uri"]?.stringValue }),
                       ["openflix://providers", "openflix://metrics", "openflix://budget"])
    }

    func testAStaticResourceStillReads() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("resources/read", params: modernParams(extra: [
            "uri": .string("openflix://providers"),
        ])))
        XCTAssertNil(response?.error)
        guard case .array(let contents)? = response?.result?["contents"] else {
            return XCTFail("no contents")
        }
        XCTAssertEqual(contents.first?["uri"]?.stringValue, "openflix://providers")
        XCTAssertTrue(contents.first?["text"]?.stringValue?.contains("providers") ?? false)
    }

    func testAnUnknownResourceIsAnErrorCarryingTheURI() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("resources/read", params: modernParams(extra: [
            "uri": .string("openflix://nope"),
        ])))
        XCTAssertEqual(response?.error?.code, MCPErrorCode.invalidParams)
        XCTAssertEqual(response?.error?.data?["uri"]?.stringValue, "openflix://nope")
    }

    /// A templated URI whose id is not well-formed must fail as "unknown
    /// resource" rather than being handed to `appendingPathComponent`.
    func testATemplatedResourceReadRejectsTraversal() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("resources/read", params: modernParams(extra: [
            "uri": .string("openflix://generation/../../../../etc/passwd"),
        ])))
        XCTAssertEqual(response?.error?.code, MCPErrorCode.invalidParams)
        XCTAssertNil(response?.result)
    }

    // MARK: - Recipes as prompts

    func testARecipeBecomesAPromptCarryingItsDeclaredArguments() {
        let r = recipe(args: [
            RecipeArg(name: "subject", type: "string", description: "What is in the shot"),
            RecipeArg(name: "style", type: "enum", defaultValue: .string("noir"),
                      choices: ["noir", "anime", "documentary"]),
        ])
        let prompt = MCPToolRegistry.prompt(for: r)

        XCTAssertEqual(prompt.name, "recipe_\(r.id)")
        XCTAssertEqual(prompt.title, "Neon Alley")
        XCTAssertEqual(prompt.arguments.map(\.name), ["subject", "style"])
        XCTAssertTrue(prompt.description.contains("runway"))
    }

    /// The mapping that carries the most weight: no declared default means
    /// there is nothing to fall back to, which is exactly `required`.
    func testAnArgumentWithoutADefaultIsRequiredAndOneWithADefaultIsNot() {
        let r = recipe(args: [
            RecipeArg(name: "subject", type: "string"),
            RecipeArg(name: "style", type: "string", defaultValue: .string("noir")),
        ])
        let prompt = MCPToolRegistry.prompt(for: r)
        XCTAssertEqual(prompt.arguments.first { $0.name == "subject" }?.required, true)
        XCTAssertEqual(prompt.arguments.first { $0.name == "style" }?.required, false)
    }

    func testEnumChoicesSurviveOntoThePromptArgument() {
        let r = recipe(args: [
            RecipeArg(name: "style", type: "enum", defaultValue: .string("noir"),
                      choices: ["noir", "anime"]),
        ])
        XCTAssertEqual(MCPToolRegistry.prompt(for: r).arguments.first?.choices, ["noir", "anime"])
    }

    func testRenderingARecipeSubstitutesItsArguments() {
        let r = recipe(args: [
            RecipeArg(name: "subject", type: "string"),
            RecipeArg(name: "style", type: "string", defaultValue: .string("noir")),
        ])
        let result = MCPPromptRenderer.render(
            name: "recipe_\(r.id)",
            arguments: .dictionary(["subject": .string("a fox")]),
            recipes: [r])

        guard case .success(let payload) = result else { return XCTFail("render failed: \(result)") }
        guard case .array(let messages)? = payload["messages"],
              let text = messages.first?["content"]?["text"]?.stringValue else {
            return XCTFail("no message text")
        }
        XCTAssertTrue(text.contains("a fox in a neon alley, noir"), "got: \(text)")
        XCTAssertTrue(text.contains("Negative prompt: blurry"))
        XCTAssertTrue(text.contains("provider runway"))
        XCTAssertTrue(text.contains("duration 8s"))
    }

    /// The anti-injection property. The kit's `substitute` is single-pass, so a
    /// value containing `{{other}}` is never rescanned — and an agent is what
    /// supplies these values, so this is precisely the path that must not grow a
    /// second implementation.
    func testAnArgumentValueContainingAPlaceholderIsNotExpanded() {
        let r = recipe(prompt: "a {{subject}} in a {{place}}",
                       args: [
                        RecipeArg(name: "subject", type: "string"),
                        RecipeArg(name: "place", type: "string", defaultValue: .string("alley")),
                       ])
        let result = MCPPromptRenderer.render(
            name: "recipe_\(r.id)",
            arguments: .dictionary(["subject": .string("{{place}}")]),
            recipes: [r])

        guard case .success(let payload) = result,
              case .array(let messages)? = payload["messages"],
              let text = messages.first?["content"]?["text"]?.stringValue else {
            return XCTFail("render failed")
        }
        XCTAssertTrue(text.contains("a {{place}} in a alley"), "value was re-expanded: \(text)")
    }

    func testAMissingRequiredArgumentIsRefusedByName() {
        let r = recipe(args: [RecipeArg(name: "subject", type: "string")])
        let result = MCPPromptRenderer.render(name: "recipe_\(r.id)", arguments: nil, recipes: [r])
        guard case .failure(let failure) = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(failure, .missingArgument(prompt: "recipe_\(r.id)", argument: "subject"))
    }

    func testAnUndeclaredEnumChoiceIsRefused() {
        let r = recipe(args: [
            RecipeArg(name: "style", type: "enum", defaultValue: .string("noir"),
                      choices: ["noir", "anime"]),
        ])
        let result = MCPPromptRenderer.render(
            name: "recipe_\(r.id)",
            arguments: .dictionary(["style": .string("claymation")]),
            recipes: [r])
        guard case .failure(let failure) = result else { return XCTFail("expected refusal") }
        XCTAssertTrue(failure.message.contains("claymation"), failure.message)
    }

    /// An agent adding a key the recipe never declared should get a rendered
    /// prompt, not a hard failure it cannot act on.
    func testAStrayArgumentIsIgnoredRatherThanFatal() {
        let r = recipe(args: [RecipeArg(name: "subject", type: "string")])
        let result = MCPPromptRenderer.render(
            name: "recipe_\(r.id)",
            arguments: .dictionary(["subject": .string("a fox"), "nonsense": .string("x")]),
            recipes: [r])
        guard case .success = result else { return XCTFail("stray key should not be fatal") }
    }

    /// Rendering a prompt must never be a way to spend money — submission stays
    /// `tools/call generate`, which is the only path through
    /// `GenerationEngine.submit` and therefore the budget pre-flight.
    func testRenderingARecipeSaysPlainlyThatItSubmittedNothing() {
        let r = recipe(args: [RecipeArg(name: "subject", type: "string", defaultValue: .string("fox")),
                              RecipeArg(name: "style", type: "string", defaultValue: .string("noir"))])
        guard case .success(let payload) = MCPPromptRenderer.render(
            name: "recipe_\(r.id)", arguments: nil, recipes: [r]),
              case .array(let messages)? = payload["messages"],
              let text = messages.first?["content"]?["text"]?.stringValue else {
            return XCTFail("render failed")
        }
        XCTAssertTrue(text.contains("never submits"))
        XCTAssertTrue(text.contains("budget"))
    }

    func testAV2RecipeWithNoArgsStillRenders() {
        let r = recipe(prompt: "a static prompt with no placeholders", args: nil)
        guard case .success(let payload) = MCPPromptRenderer.render(
            name: "recipe_\(r.id)", arguments: nil, recipes: [r]),
              case .array(let messages)? = payload["messages"],
              let text = messages.first?["content"]?["text"]?.stringValue else {
            return XCTFail("render failed")
        }
        XCTAssertTrue(text.contains("a static prompt with no placeholders"))
    }

    func testAnUnknownPromptIsRefused() {
        guard case .failure(let failure) = MCPPromptRenderer.render(
            name: "recipe_does-not-exist", arguments: nil, recipes: []) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(failure, .unknownPrompt("recipe_does-not-exist"))
    }

    func testTheBuiltInPromptsRenderWithoutARecipeStore() {
        guard case .success(let compare) = MCPPromptRenderer.render(
            name: "compare_providers",
            arguments: .dictionary(["prompt": .string("a fox at dusk")]),
            recipes: []),
              case .array(let messages)? = compare["messages"],
              let text = messages.first?["content"]?["text"]?.stringValue else {
            return XCTFail("compare_providers failed")
        }
        XCTAssertTrue(text.contains("a fox at dusk"))
        XCTAssertTrue(text.contains("budget_status"), "the compare loop must cost-check before spending")
        XCTAssertTrue(text.contains("submit_vote"), "the point of comparing is feeding routing")

        guard case .success = MCPPromptRenderer.render(
            name: "budget_check", arguments: nil, recipes: []) else {
            return XCTFail("budget_check failed")
        }
    }

    func testPromptArgumentsAreStringifiedFromJSONTypes() {
        let values = MCPPromptRenderer.stringArguments(.dictionary([
            "a": .string("x"), "b": .int(3), "c": .double(2.0), "d": .bool(true),
            "bad": .double(.nan),
        ]))
        XCTAssertEqual(values["a"], "x")
        XCTAssertEqual(values["b"], "3")
        XCTAssertEqual(values["c"], "2")
        XCTAssertEqual(values["d"], "true")
        XCTAssertNil(values["bad"])
    }

    func testPromptsListServesTheBuiltInsThroughTheServer() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("prompts/list", params: modernParams()))
        guard case .array(let prompts)? = response?.result?["prompts"] else {
            return XCTFail("no prompts")
        }
        let names = prompts.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("compare_providers"))
        XCTAssertTrue(names.contains("budget_check"))
    }

    func testPromptsGetIsWiredThroughTheServer() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("prompts/get", params: modernParams(extra: [
            "name": .string("budget_check"),
        ])))
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.result?["resultType"]?.stringValue, "complete")
        XCTAssertNotNil(response?.result?["messages"])
    }

    func testPromptsGetOnAnUnknownNameIsInvalidParams() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("prompts/get", params: modernParams(extra: [
            "name": .string("no_such_prompt"),
        ])))
        XCTAssertEqual(response?.error?.code, MCPErrorCode.invalidParams)
    }

    // MARK: - Completions

    func testCompletionOffersARecipeEnumsDeclaredChoices() {
        let r = recipe(args: [
            RecipeArg(name: "style", type: "enum", defaultValue: .string("noir"),
                      choices: ["noir", "anime", "documentary"]),
        ])
        let payload = MCPCompletion.complete(
            ref: .dictionary(["type": .string("ref/prompt"), "name": .string("recipe_\(r.id)")]),
            argumentName: "style", value: "", recipes: [r])

        guard case .array(let values)? = payload["completion"]?["values"] else {
            return XCTFail("no completion values")
        }
        XCTAssertEqual(values.compactMap(\.stringValue), ["noir", "anime", "documentary"])
        XCTAssertEqual(payload["completion"]?["hasMore"]?.boolValue, false)
    }

    func testCompletionFiltersByPrefixCaseInsensitively() {
        let r = recipe(args: [
            RecipeArg(name: "style", type: "enum", defaultValue: .string("noir"),
                      choices: ["noir", "anime", "documentary"]),
        ])
        let payload = MCPCompletion.complete(
            ref: .dictionary(["type": .string("ref/prompt"), "name": .string("recipe_\(r.id)")]),
            argumentName: "style", value: "NO", recipes: [r])
        guard case .array(let values)? = payload["completion"]?["values"] else {
            return XCTFail("no completion values")
        }
        XCTAssertEqual(values.compactMap(\.stringValue), ["noir"])
    }

    func testCompletionOnAFreeTextOrUnknownReferenceIsEmptyRatherThanAnError() {
        let r = recipe(args: [RecipeArg(name: "subject", type: "string")])
        let ref = AnyCodableValue.dictionary(["type": .string("ref/prompt"),
                                              "name": .string("recipe_\(r.id)")])
        for (argument, reference) in [("subject", ref), ("style", ref),
                                      ("subject", .dictionary(["type": .string("ref/resource")]))] {
            let payload = MCPCompletion.complete(ref: reference, argumentName: argument,
                                                 value: "", recipes: [r])
            XCTAssertEqual(payload["completion"]?["total"]?.intValue, 0)
        }
    }

    func testCompletionIsWiredThroughTheServer() async {
        let server = MCPServer()
        let response = await server.handleRequest(request("completion/complete", params: modernParams(extra: [
            "ref": .dictionary(["type": .string("ref/prompt"), "name": .string("budget_check")]),
            "argument": .dictionary(["name": .string("anything"), "value": .string("")]),
        ])))
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.result?["completion"]?["total"]?.intValue, 0)
        XCTAssertEqual(response?.result?["resultType"]?.stringValue, "complete")
    }

    // MARK: - Recipe resource encoding

    func testARecipeResourceExposesItsArgumentContract() {
        let r = recipe(args: [
            RecipeArg(name: "subject", type: "string"),
            RecipeArg(name: "style", type: "enum", defaultValue: .string("noir"),
                      choices: ["noir", "anime"]),
        ])
        let json = MCPServer.recipeJSON(r)
        XCTAssertEqual(json["id"] as? String, r.id)
        XCTAssertEqual(json["prompt_name"] as? String, "recipe_\(r.id)")
        guard let args = json["args"] as? [[String: Any]] else { return XCTFail("no args") }
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args.first { $0["name"] as? String == "subject" }?["required"] as? Bool, true)
        XCTAssertEqual(args.first { $0["name"] as? String == "style" }?["required"] as? Bool, false)
    }
}
