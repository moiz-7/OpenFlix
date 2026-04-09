import ArgumentParser
import Foundation

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List generation history",
        discussion: """
        Lists all generations stored in ~/.vortex/store.json.

        EXAMPLES
          vortex list
          vortex list --status succeeded
          vortex list --provider fal --limit 10
          vortex list --pretty
        """
    )

    @Option(name: .long, help: "Filter by status: submitted, processing, succeeded, failed")
    var status: String?

    @Option(name: .long, help: "Filter by provider ID")
    var provider: String?

    @Option(name: .long, help: "Filter by prompt substring")
    var search: String?

    @Option(name: .long, help: "Maximum number of results (default: 50)")
    var limit: Int = 50

    @Flag(name: .long, help: "Show oldest results first")
    var oldest: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        var gens = GenerationStore.shared.all()

        if let statusFilter = status {
            guard CLIGeneration.GenerationStatus(rawValue: statusFilter) != nil else {
                let valid = CLIGeneration.GenerationStatus.allCases.map { $0.rawValue }.joined(separator: ", ")
                Output.failMessage("Invalid status '\(statusFilter)'. Valid: \(valid)", code: "invalid_status")
            }
            gens = gens.filter { $0.status.rawValue == statusFilter }
        }
        if let providerFilter = provider {
            gens = gens.filter { $0.provider == providerFilter }
        }
        if let term = search {
            gens = gens.filter { $0.prompt.lowercased().contains(term.lowercased()) }
        }

        // Sort: newest first by default, oldest first with --oldest
        gens.sort { oldest ? ($0.createdAt < $1.createdAt) : ($0.createdAt > $1.createdAt) }

        // Apply limit
        if limit > 0 && gens.count > limit {
            gens = Array(gens.prefix(limit))
        }

        let result = gens.map { $0.jsonRepresentation }
        Output.emitArray(result)
    }
}
