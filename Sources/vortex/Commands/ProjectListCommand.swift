import ArgumentParser
import Foundation

struct ProjectList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all projects",
        discussion: """
        Lists all projects with summary info (id, name, status, shot counts, cost).

        EXAMPLES
          vortex project list
          vortex project list --status running
          vortex project list --pretty
        """
    )

    @Option(name: .long, help: "Filter by status (draft, running, succeeded, failed, etc.)")
    var status: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        var projects = ProjectStore.shared.list()

        if let statusFilter = status {
            guard let ps = Project.ProjectStatus(rawValue: statusFilter) else {
                Output.failMessage(
                    "Invalid status '\(statusFilter)'. Valid: \(Project.ProjectStatus.allCases.map { $0.rawValue }.joined(separator: ", "))",
                    code: "invalid_status"
                )
            }
            projects = projects.filter { $0.status == ps }
        }

        let summaries: [[String: Any]] = projects.map { p in
            let shots = p.allShots
            return [
                "id": p.id,
                "name": p.name,
                "status": p.status.rawValue,
                "total_shots": shots.count,
                "succeeded_shots": shots.filter { $0.status == .succeeded }.count,
                "failed_shots": shots.filter { $0.status == .failed }.count,
                "total_actual_cost_usd": p.totalActualCostUSD ?? shots.compactMap { $0.actualCostUSD }.reduce(0, +),
                "created_at": ISO8601DateFormatter().string(from: p.createdAt),
            ]
        }

        Output.emitArray(summaries)
    }
}
