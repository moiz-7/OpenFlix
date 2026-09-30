import Foundation

/// Builds and shares pairwise preference votes — the CLI's write half of the
/// preference flywheel. `openflix vote` and the MCP `submit_vote` tool both
/// route through here.
///
/// Privacy contract (mirrors the app's telemetry): only the winner/loser
/// provider+model, a category, and a random anonymous client id are sent.
/// Never the prompt, the video, or anything identifying.
enum PreferenceVoteClient {

    struct Result {
        let accepted: Int
        let duplicatesIgnored: Int
    }

    /// Stable anonymous id, generated once into ~/.openflix/client_id.
    /// Injectable directory for tests.
    static func clientId(directory: URL? = nil) -> String {
        let base = directory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openflix")
        let url = base.appendingPathComponent("client_id")
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    /// Build one registry preference event from two local generations.
    /// `eventId` is the registry's dedup key — a retried POST can never
    /// double-count.
    static func buildEvent(
        winner: CLIGeneration, loser: CLIGeneration,
        category: String?, context: String,
        clientId: String, eventId: String = UUID().uuidString
    ) -> [String: Any] {
        var event: [String: Any] = [
            "winner_model": winner.model,
            "loser_model": loser.model,
            "winner_provider": winner.provider,
            "loser_provider": loser.provider,
            "source": "cli",
            "context": context,
            "client_id": clientId,
            "event_id": eventId,
        ]
        if let category, !category.isEmpty { event["category"] = category }
        return event
    }

    /// Validate and share a single winner/loser vote. Throws with the CLI's
    /// machine-readable error codes on bad input or an unreachable registry.
    static func vote(
        winnerId: String, loserId: String,
        category: String?, context: String = "vote",
        store: GenerationStore = .shared
    ) async throws -> Result {
        guard winnerId != loserId else {
            throw OpenFlixError.invalidResponse("Winner and loser must be different generations")
        }
        guard let winner = store.get(winnerId) else {
            throw OpenFlixError.generationNotFound(winnerId)
        }
        guard let loser = store.get(loserId) else {
            throw OpenFlixError.generationNotFound(loserId)
        }
        // Same-model votes carry no routing signal and would self-inflate.
        guard winner.provider != loser.provider || winner.model != loser.model else {
            throw OpenFlixError.invalidResponse("Winner and loser use the same provider/model — a vote between them carries no signal")
        }

        let event = buildEvent(
            winner: winner, loser: loser,
            category: category, context: context,
            clientId: clientId()
        )
        let response = try await RegistryClient.postPreferenceEvents([event])
        return Result(accepted: response.accepted, duplicatesIgnored: response.duplicatesIgnored)
    }
}

/// Who made the choice a vote records, when the vote arrives from an agent.
///
/// The community pool is **human** preference: smart routing reads it back as
/// "what people chose", so a model's own opinion of two videos must never land
/// there: machine judgments never enter the human vote pool.
/// An agent can only tell us which case it is in, so the MCP tool makes it say
/// so rather than letting every agent vote count as a person's.
enum VoteOrigin: String, CaseIterable {
    /// The agent is passing on a choice the user made ("I like the left one").
    case ownerRelayed = "owner_relayed"
    /// The agent's own judgment. Never shared.
    case agentJudgment = "agent_judgment"

    /// The registry `context` this origin is shared under, so relayed votes
    /// stay separable from ones cast directly at `openflix vote`.
    var registryContext: String { "mcp:\(rawValue)" }

    /// Parses an agent's `origin` argument and refuses anything that is not the
    /// user's own choice. Runs before any lookup, so a refused vote touches
    /// nothing.
    static func requireShareable(_ raw: String?) throws -> VoteOrigin {
        guard let raw else {
            throw OpenFlixError.invalidInput(
                "origin is required: \"owner_relayed\" if the user chose the winner, \"agent_judgment\" if you did")
        }
        guard let origin = VoteOrigin(rawValue: raw) else {
            throw OpenFlixError.invalidInput(
                "origin must be \"owner_relayed\" or \"agent_judgment\", got \"\(raw)\"")
        }
        guard origin == .ownerRelayed else {
            throw OpenFlixError.invalidInput(
                "An agent's own judgment is not shared: the community pool records human preference only. Ask the user which one they prefer, then vote with origin \"owner_relayed\".")
        }
        return origin
    }
}
