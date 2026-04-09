import ArgumentParser
import Foundation

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Purge old or failed generations from the store",
        discussion: """
        Removes generations matching the given filters. At least one filter
        (--older-than or --status) is required to prevent accidental data loss.

        EXAMPLES
          vortex purge --status failed
          vortex purge --older-than 30
          vortex purge --status failed --delete-files
          vortex purge --older-than 7 --status cancelled --delete-files
        """
    )

    @Option(name: .long, help: "Purge generations older than N days")
    var olderThan: Int?

    @Option(name: .long, help: "Purge generations with this status (failed, cancelled, succeeded, etc.)")
    var status: String?

    @Flag(name: .long, help: "Also delete downloaded video files")
    var deleteFiles: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard olderThan != nil || status != nil else {
            Output.failMessage("At least one filter required: --older-than or --status.", code: "invalid_input")
        }

        if let s = status {
            guard CLIGeneration.GenerationStatus(rawValue: s) != nil else {
                let valid = CLIGeneration.GenerationStatus.allCases.map { $0.rawValue }.joined(separator: ", ")
                Output.failMessage("Invalid status '\(s)'. Valid: \(valid)", code: "invalid_status")
            }
        }

        var gens = GenerationStore.shared.all()

        if let days = olderThan {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            gens = gens.filter { $0.createdAt < cutoff }
        }
        if let s = status, let statusEnum = CLIGeneration.GenerationStatus(rawValue: s) {
            gens = gens.filter { $0.status == statusEnum }
        }

        var deletedFiles = 0
        for gen in gens {
            if deleteFiles, let path = gen.localPath {
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                    deletedFiles += 1
                }
            }
            GenerationStore.shared.delete(gen.id)
        }

        Output.emitDict([
            "purged_count": gens.count,
            "deleted_files": deletedFiles,
        ])
    }
}
