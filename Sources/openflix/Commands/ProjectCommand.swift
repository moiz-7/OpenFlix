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
          openflix project create --file spec.json
          openflix project run <project-id> --stream
          openflix project status <project-id> --detail
          openflix project export <project-id>
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
