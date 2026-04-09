import ArgumentParser
import Foundation

struct ProjectGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Manage multi-shot video generation projects",
        discussion: """
        Projects organize video generation into scenes and shots with dependency
        management, parallel execution, and intelligent provider routing.

        WORKFLOW
          vortex project create --file spec.json
          vortex project run <project-id> --stream
          vortex project status <project-id> --detail
          vortex project export <project-id>
        """,
        subcommands: [
            ProjectCreate.self,
            ProjectRun.self,
            ProjectStatus.self,
            ProjectList.self,
            ProjectDelete.self,
            ProjectShot.self,
            ProjectExport.self,
        ]
    )
}
