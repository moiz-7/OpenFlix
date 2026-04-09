import ArgumentParser
import Foundation

struct ProjectExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export project output manifest",
        discussion: """
        Outputs an ordered JSON manifest of all succeeded shots with their
        video paths. Use --manifest to generate an ffmpeg concat demuxer file.

        EXAMPLES
          openflix project export <project-id>
          openflix project export <project-id> --manifest --output ./output
          openflix project export <project-id> --pretty
        """
    )

    @Argument(help: "Project ID")
    var projectId: String

    @Option(name: .long, help: "Output directory for manifest files")
    var output: String?

    @Flag(name: .long, help: "Generate ffmpeg concat demuxer file")
    var manifest: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let project = ProjectStore.shared.get(projectId) else {
            Output.failMessage("Project '\(projectId)' not found", code: "not_found")
        }

        // Collect succeeded shots in order
        let succeededShots = project.scenes
            .sorted { $0.orderIndex < $1.orderIndex }
            .flatMap { scene in
                scene.shots
                    .sorted { $0.orderIndex < $1.orderIndex }
                    .filter { $0.status == .succeeded }
            }

        // Build manifest entries
        var entries: [[String: Any]] = []
        for shot in succeededShots {
            var entry: [String: Any] = [
                "shot_id": shot.id,
                "shot_name": shot.name,
                "scene_id": shot.sceneId,
                "status": shot.status.rawValue,
            ]

            if let genId = shot.selectedGenerationId,
               let gen = GenerationStore.shared.get(genId) {
                entry["generation_id"] = genId
                if let path = gen.localPath { entry["local_path"] = path }
                if let url = gen.remoteVideoURL { entry["remote_video_url"] = url }
            }

            if let v = shot.qualityScore         { entry["quality_score"] = v }
            if let v = shot.evaluationReasoning   { entry["evaluation_reasoning"] = v }
            if let v = shot.evaluationDimensions  { entry["evaluation_dimensions"] = v }

            entries.append(entry)
        }

        // Generate ffmpeg concat file if requested
        if manifest {
            let outputDir: URL
            if let dir = output {
                outputDir = URL(fileURLWithPath: dir)
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser
                outputDir = home.appendingPathComponent(".openflix/projects/\(projectId)/exports")
            }
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            var concatLines: [String] = []
            for entry in entries {
                if let path = entry["local_path"] as? String {
                    concatLines.append("file '\(path)'")
                }
            }

            if !concatLines.isEmpty {
                let concatFile = outputDir.appendingPathComponent("concat.txt")
                let concatContent = concatLines.joined(separator: "\n") + "\n"
                try concatContent.write(to: concatFile, atomically: true, encoding: .utf8)

                Output.emitDict([
                    "project_id": projectId,
                    "project_name": project.name,
                    "total_shots": entries.count,
                    "concat_file": concatFile.path,
                    "ffmpeg_command": "ffmpeg -f concat -safe 0 -i \(concatFile.path) -c copy output.mp4",
                    "shots": entries,
                ])
            } else {
                Output.emitDict([
                    "project_id": projectId,
                    "project_name": project.name,
                    "total_shots": entries.count,
                    "warning": "No local paths available for concat file",
                    "shots": entries,
                ])
            }
        } else {
            Output.emitDict([
                "project_id": projectId,
                "project_name": project.name,
                "total_shots": entries.count,
                "shots": entries,
            ])
        }
    }
}
