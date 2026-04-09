import ArgumentParser
import Foundation

struct ProjectRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Execute a project's DAG of shots",
        discussion: """
        Runs all shots in dependency order with configurable concurrency.
        Use --resume to restart stale dispatched/processing shots.

        EXAMPLES
          vortex project run <project-id> --stream
          vortex project run <project-id> --concurrency 6 --resume
        """
    )

    @Argument(help: "Project ID to execute")
    var projectId: String

    @Option(name: .long, help: "Max parallel shots (default: 4)")
    var concurrency: Int?

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events")
    var stream: Bool = false

    @Flag(name: .long, help: "Resume: reset stale dispatched/processing shots to pending")
    var resume: Bool = false

    @Flag(name: .long, help: "Skip downloading videos after generation")
    var skipDownload: Bool = false

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Enable quality evaluation after each generation")
    var evaluate: Bool = false

    @Option(name: .long, help: "Quality threshold 0-100 (implies --evaluate)")
    var qualityThreshold: Double?

    @Option(name: .long, help: "Evaluator type: heuristic or llm-vision")
    var evaluator: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let project = ProjectStore.shared.get(projectId) else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        let allowedStatuses: Set<Project.ProjectStatus> = [.draft, .paused, .partialFailure, .failed]
        guard allowedStatuses.contains(project.status) else {
            Output.failMessage(
                "Project '\(projectId)' has status '\(project.status.rawValue)' — can only run draft, paused, partially failed, or failed projects.",
                code: "invalid_status"
            )
        }

        // Resume: reset stale shots
        if resume {
            ProjectStore.shared.update(id: projectId) { p in
                for si in p.scenes.indices {
                    for shi in p.scenes[si].shots.indices {
                        let status = p.scenes[si].shots[shi].status
                        if status == .dispatched || status == .processing {
                            p.scenes[si].shots[shi].status = .pending
                            p.scenes[si].shots[shi].startedAt = nil
                            p.scenes[si].shots[shi].errorMessage = nil
                        }
                        // Also reset failed shots on resume
                        if status == .failed {
                            p.scenes[si].shots[shi].status = .pending
                            p.scenes[si].shots[shi].errorMessage = nil
                            p.scenes[si].shots[shi].retryCount = 0
                        }
                    }
                }
            }
        }

        let maxConc = concurrency ?? project.settings.maxConcurrency

        // Build quality config from flags and project settings
        var qConfig = project.settings.qualityConfig
        if evaluate || qualityThreshold != nil {
            qConfig.enabled = true
        }
        if let t = qualityThreshold { qConfig.threshold = t }
        if let e = evaluator, let evalType = QualityConfig.EvaluatorType(rawValue: e) {
            qConfig.evaluator = evalType
        }

        let executor = DAGExecutor(
            projectId: projectId,
            maxConcurrency: maxConc,
            stream: stream,
            apiKey: apiKey,
            skipDownload: skipDownload,
            timeout: project.settings.timeoutPerShot,
            maxRetriesPerShot: project.settings.maxRetriesPerShot,
            qualityConfig: qConfig
        )

        do {
            let result = try await executor.execute()
            Output.emitDict(result.jsonRepresentation)
        } catch let error as VortexError {
            Output.fail(error)
        } catch let error as ProjectSpecError {
            Output.failMessage(error.errorDescription ?? error.localizedDescription, code: error.code)
        } catch {
            Output.failMessage(error.localizedDescription, code: "run_failed")
        }
    }
}
