import ArgumentParser
import Foundation

struct Vote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vote",
        abstract: "Record a pairwise preference vote to the community registry",
        discussion: """
        Votes are the fuel for smart routing: `--route smart` picks providers
        by community win rate, and this command is how those win rates are
        built. Vote for the generation you preferred out of two you've made
        (e.g. after a scatter run or `openflix compare`).

        Only the winner/loser provider+model, an optional category, and a
        random anonymous client id are sent — never the prompt or the video.
        Votes are deduplicated server-side, so retrying a failed submit is safe.

        For a private, local-only quality note that never leaves this machine,
        use `openflix feedback <gen-id> --score <0-100>` instead.

        EXAMPLES
          openflix vote <winner-gen-id> <loser-gen-id>
          openflix vote <winner-gen-id> <loser-gen-id> --category cinematic
        """
    )

    @Argument(help: "Generation ID you preferred")
    var winnerId: String

    @Argument(help: "Generation ID it beat")
    var loserId: String

    @Option(name: .long, help: "Category hint (e.g. cinematic, anime, product) — helps category-aware routing")
    var category: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let winner = GenerationStore.shared.get(winnerId)
        let loser = GenerationStore.shared.get(loserId)

        do {
            let result = try await PreferenceVoteClient.vote(
                winnerId: winnerId, loserId: loserId, category: category
            )
            var json: [String: Any] = [
                "winner": [
                    "generation_id": winnerId,
                    "provider": winner?.provider ?? "",
                    "model": winner?.model ?? "",
                ],
                "loser": [
                    "generation_id": loserId,
                    "provider": loser?.provider ?? "",
                    "model": loser?.model ?? "",
                ],
                "shared": true,
                "accepted": result.accepted,
                "registry": RegistryClient.baseURL,
            ]
            if result.duplicatesIgnored > 0 { json["duplicates_ignored"] = result.duplicatesIgnored }
            if let category { json["category"] = category }
            Output.emitDict(json)
        } catch let error as OpenFlixError {
            Output.failMessage(error.localizedDescription, code: error.code)
        } catch {
            // URLError etc. from a down registry must stay machine-readable
            // JSON, not ArgumentParser's plain-text "Error: …".
            Output.failMessage(
                "Could not reach the registry at \(RegistryClient.baseURL): \(error.localizedDescription)",
                code: "registry_unavailable"
            )
        }
    }
}
