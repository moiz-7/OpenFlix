import ArgumentParser
import Foundation

struct ProjectStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show project progress and status",
        discussion: """
        Outputs a JSON summary of project progress including shot counts,
        cost breakdown, and elapsed time.

        EXAMPLES
          vortex project status <project-id>
          vortex project status <project-id> --detail --pretty
        """
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Flag(name: .long, help: "Include per-shot status details")
    var detail: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let project = ProjectStore.shared.get(projectId) else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        let allShots = project.allShots
        let elapsed = project.completedAt.map { $0.timeIntervalSince(project.createdAt) }
            ?? Date().timeIntervalSince(project.createdAt)

        var d: [String: Any] = [
            "id": project.id,
            "name": project.name,
            "status": project.status.rawValue,
            "progress": project.progress,
            "cost": [
                "actual_usd": project.totalActualCostUSD ?? allShots.compactMap { $0.actualCostUSD }.reduce(0, +),
                "estimated_usd": project.totalEstimatedCostUSD ?? allShots.compactMap { $0.estimatedCostUSD }.reduce(0, +),
                "budget_usd": project.costBudgetUSD as Any,
            ],
            "elapsed_seconds": Int(elapsed),
        ]

        if detail {
            d["shots"] = allShots
                .sorted { $0.orderIndex < $1.orderIndex }
                .map { $0.jsonRepresentation }
        }

        Output.emitDict(d)
    }
}
