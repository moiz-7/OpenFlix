import ArgumentParser
import Foundation

struct ProjectDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a project and its data",
        discussion: """
        Removes the project directory and all associated data.
        Optionally also removes linked generations from the generation store.

        EXAMPLES
          vortex project delete <project-id>
          vortex project delete <project-id> --delete-generations
        """
    )

    @Argument(help: "Project ID to delete")
    var projectId: String

    @Flag(name: .long, help: "Also delete associated generations from store")
    var deleteGenerations: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let project = ProjectStore.shared.get(projectId) else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        // Optionally clean up generations
        if deleteGenerations {
            let genIds = project.allShots.flatMap { $0.generationIds }
            for genId in genIds {
                GenerationStore.shared.delete(genId)
            }
        }

        ProjectStore.shared.delete(projectId)

        Output.emitDict([
            "deleted": true,
            "project_id": projectId,
            "name": project.name,
        ])
    }
}
