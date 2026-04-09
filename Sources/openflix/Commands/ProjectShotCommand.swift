import ArgumentParser
import Foundation

struct ProjectShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shot",
        abstract: "Manage individual shots within a project",
        subcommands: [
            ShotAdd.self,
            ShotRetry.self,
            ShotSkip.self,
            ShotUpdate.self,
            ShotRemove.self,
        ]
    )
}

// MARK: - Shot Add

struct ShotAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a shot to an existing project scene"
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Argument(help: "Scene ID")
    var sceneId: String

    @Option(name: .long, help: "Shot name")
    var name: String

    @Option(name: .long, help: "Prompt text")
    var prompt: String

    @Option(name: .long, help: "Provider ID")
    var provider: String?

    @Option(name: .long, help: "Model ID")
    var model: String?

    @Option(name: .long, help: "Duration in seconds")
    var duration: Double?

    @Option(name: .long, help: "Aspect ratio (e.g. 16:9)")
    var aspectRatio: String?

    @Option(name: .long, help: "Dependency shot IDs (comma-separated)")
    var dependencies: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard ProjectStore.shared.get(projectId) != nil else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Output.failMessage("Prompt cannot be empty", code: "invalid_input")
        }

        let deps = dependencies?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
        let shot = Shot(
            id: UUID().uuidString,
            sceneId: sceneId,
            name: name,
            orderIndex: 0, // Will be set based on existing shots
            prompt: prompt,
            negativePrompt: nil,
            status: .pending,
            provider: provider,
            model: model,
            duration: duration,
            aspectRatio: aspectRatio,
            width: nil,
            height: nil,
            referenceImageURL: nil,
            referenceAssetId: nil,
            extraParams: [:],
            dependencies: deps,
            generationIds: [],
            selectedGenerationId: nil,
            routingDecision: nil,
            estimatedCostUSD: nil,
            actualCostUSD: nil,
            retryCount: 0,
            maxRetries: nil,
            errorMessage: nil,
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil
        )

        ProjectStore.shared.update(id: projectId) { p in
            for si in p.scenes.indices {
                if p.scenes[si].id == sceneId {
                    var s = shot
                    s.orderIndex = p.scenes[si].shots.count
                    p.scenes[si].shots.append(s)
                    return
                }
            }
        }

        Output.emitDict(shot.jsonRepresentation)
    }
}

// MARK: - Shot Retry

struct ShotRetry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retry",
        abstract: "Reset a failed shot to pending for re-execution"
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Argument(help: "Shot ID")
    var shotId: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let project = ProjectStore.shared.get(projectId) else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        guard let shot = project.allShots.first(where: { $0.id == shotId }) else {
            Output.failMessage("Shot '\(shotId)' not found in project", code: "not_found")
        }

        guard shot.status == .failed || shot.status == .cancelled else {
            Output.failMessage(
                "Shot '\(shotId)' has status '\(shot.status.rawValue)' — only failed or cancelled shots can be retried",
                code: "invalid_status"
            )
        }

        ProjectStore.shared.updateShot(projectId: projectId, shotId: shotId) { s in
            s.status = .pending
            s.errorMessage = nil
            s.retryCount += 1
            s.startedAt = nil
            s.completedAt = nil
        }

        Output.emitDict([
            "retried": true,
            "project_id": projectId,
            "shot_id": shotId,
            "new_status": "pending",
        ])
    }
}

// MARK: - Shot Skip

struct ShotSkip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Mark a shot as skipped"
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Argument(help: "Shot ID")
    var shotId: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard ProjectStore.shared.get(projectId) != nil else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        ProjectStore.shared.updateShot(projectId: projectId, shotId: shotId) { s in
            s.status = .skipped
            s.completedAt = Date()
        }

        Output.emitDict([
            "skipped": true,
            "project_id": projectId,
            "shot_id": shotId,
        ])
    }
}

// MARK: - Shot Update

struct ShotUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update shot properties (prompt, provider, model, status, etc.)"
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Argument(help: "Shot ID")
    var shotId: String

    @Option(name: .long, help: "New prompt")
    var prompt: String?

    @Option(name: .long, help: "New provider")
    var provider: String?

    @Option(name: .long, help: "New model")
    var model: String?

    @Option(name: .long, help: "Link a generation ID to this shot")
    var generationId: String?

    @Option(name: .long, help: "Set status (succeeded, failed, skipped)")
    var status: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard ProjectStore.shared.get(projectId) != nil else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        ProjectStore.shared.updateShot(projectId: projectId, shotId: shotId) { s in
            if let v = prompt    { s.prompt = v }
            if let v = provider  { s.provider = v }
            if let v = model     { s.model = v }
            if let v = generationId {
                s.generationIds.append(v)
                s.selectedGenerationId = v
            }
            if let v = status, let st = Shot.ShotStatus(rawValue: v) {
                s.status = st
                if st == .succeeded || st == .failed || st == .skipped {
                    s.completedAt = Date()
                }
            }
        }

        if let updated = ProjectStore.shared.get(projectId)?
            .allShots.first(where: { $0.id == shotId }) {
            Output.emitDict(updated.jsonRepresentation)
        } else {
            Output.emitDict(["updated": true, "shot_id": shotId])
        }
    }
}

// MARK: - Shot Remove

struct ShotRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a shot from a project"
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Argument(help: "Shot ID")
    var shotId: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard ProjectStore.shared.get(projectId) != nil else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        ProjectStore.shared.update(id: projectId) { p in
            for si in p.scenes.indices {
                p.scenes[si].shots.removeAll { $0.id == shotId }
            }
        }

        Output.emitDict([
            "removed": true,
            "project_id": projectId,
            "shot_id": shotId,
        ])
    }
}
