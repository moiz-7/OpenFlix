import XCTest
@testable import openflix

/// `submit_vote` is the one MCP tool that writes into the **community** pool,
/// and that pool is read back by smart routing as human preference. An agent's
/// own opinion of two videos must never land there (machine judgments
/// never enter the human vote table), so the tool makes the agent say whose
/// choice it is relaying and refuses its own.
///
/// **Nothing here reaches the network.** Every refused case is stopped by
/// `VoteOrigin.requireShareable`, which runs before any store lookup, and the
/// one accepted case names generation ids that do not exist, so it stops at
/// the store with `not_found` — proving it got past the origin gate without
/// posting anything.
final class MCPVoteOriginTests: XCTestCase {

    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        server = MCPServer()
    }

    // MARK: - Parsing

    func testOwnerRelayedIsTheOnlyShareableOrigin() throws {
        XCTAssertEqual(try VoteOrigin.requireShareable("owner_relayed"), .ownerRelayed)
        XCTAssertThrowsError(try VoteOrigin.requireShareable("agent_judgment"))
        XCTAssertThrowsError(try VoteOrigin.requireShareable(nil), "a missing origin must not default to human")
        XCTAssertThrowsError(try VoteOrigin.requireShareable("human"))
        XCTAssertThrowsError(try VoteOrigin.requireShareable("OWNER_RELAYED"), "exact values only")
    }

    func testTheRefusalTellsTheAgentWhatToDoInstead() {
        XCTAssertThrowsError(try VoteOrigin.requireShareable("agent_judgment")) { error in
            guard case OpenFlixError.invalidInput(let message) = error else {
                return XCTFail("expected invalid_input, got \(error)")
            }
            XCTAssertTrue(message.contains("Ask the user"), message)
            XCTAssertTrue(message.contains("owner_relayed"), message)
        }
    }

    func testRelayedVotesAreSharedUnderTheirOwnContext() {
        XCTAssertEqual(VoteOrigin.ownerRelayed.registryContext, "mcp:owner_relayed",
                       "relayed votes must stay separable from ones cast at `openflix vote`")
    }

    // MARK: - The wire

    func testTheSchemaRequiresOriginAndEnumeratesIt() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.allTools.first { $0.name == "submit_vote" })
        let schema = tool.inputSchema
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(required.contains("origin"))
        let values = schema["properties"]?["origin"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(Set(values ?? []), ["owner_relayed", "agent_judgment"])
    }

    func testCompareProvidersPromptOnlyVotesOnTheUsersChoice() {
        guard case .success(let compare) = MCPPromptRenderer.render(
            name: "compare_providers",
            arguments: .dictionary(["prompt": .string("a fox at dusk")]),
            recipes: []),
              case .array(let messages)? = compare["messages"],
              let text = messages.first?["content"]?["text"]?.stringValue else {
            return XCTFail("compare_providers failed")
        }
        XCTAssertTrue(text.contains("owner_relayed"))
        XCTAssertTrue(text.contains("do not vote"))
    }

    // MARK: - tools/call

    private func callVote(_ arguments: [String: AnyCodableValue]) async throws -> (isError: Bool, body: [String: Any]) {
        let request = MCPRequest(jsonrpc: "2.0", id: .int(1), method: "tools/call", params: [
            "name": .string("submit_vote"),
            "arguments": .dictionary(arguments),
        ])
        let response = await server.handleRequest(request)
        let result = try XCTUnwrap(response?.result?.objectValue)
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return (result["isError"]?.boolValue ?? false, body)
    }

    private let missingIds: [String: AnyCodableValue] = [
        "winner_generation_id": .string("openflix-test-no-such-winner"),
        "loser_generation_id": .string("openflix-test-no-such-loser"),
    ]

    func testAnAgentJudgmentIsRefusedBeforeAnyLookup() async throws {
        var args = missingIds
        args["origin"] = .string("agent_judgment")
        let (isError, body) = try await callVote(args)
        XCTAssertTrue(isError)
        // Refused at the origin gate, not at the store: the ids do not exist,
        // so reaching the store would have said `not_found` instead.
        XCTAssertEqual(body["code"] as? String, "INPUT_INVALID")
        XCTAssertTrue((body["message"] as? String)?.contains("human preference") ?? false)
    }

    func testAVoteWithNoOriginIsRefused() async throws {
        let (isError, body) = try await callVote(missingIds)
        XCTAssertTrue(isError)
        XCTAssertEqual(body["code"] as? String, "INPUT_INVALID")
        // Stopped by schema validation (origin is required), and the refusal
        // still tells the agent what to pass.
        let message = body["message"] as? String ?? ""
        XCTAssertTrue(message.contains("'origin'"), message)
        XCTAssertTrue(message.contains("owner_relayed"), message)
    }

    func testAnOwnerRelayedVoteGetsPastTheGate() async throws {
        var args = missingIds
        args["origin"] = .string("owner_relayed")
        let (isError, body) = try await callVote(args)
        XCTAssertTrue(isError)
        XCTAssertEqual(body["code"] as? String, "GENERATION_NOT_FOUND",
                       "an owner-relayed vote must reach the store (and stop there, offline)")
    }
}
