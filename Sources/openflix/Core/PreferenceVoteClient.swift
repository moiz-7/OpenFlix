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
