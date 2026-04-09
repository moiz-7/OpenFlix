import ArgumentParser
import Foundation

struct ProjectCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a project from a JSON spec file",
        discussion: """
        Parses a project specification, assigns IDs, resolves shot name
        references in dependencies, validates the DAG, and saves to disk.

        EXAMPLES
          vortex project create --file spec.json
          cat spec.json | vortex project create
        """
    )

    @Option(name: .long, help: "JSON spec file path")
    var file: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // Read input
        let data: Data
        if let filePath = file {
            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Output.failMessage("File not found: \(filePath)", code: "file_not_found")
            }
            do { data = try Data(contentsOf: url) }
            catch { Output.failMessage("Cannot read file: \(error.localizedDescription)", code: "file_error") }
        } else {
            var stdinData = Data()
            while let line = readLine(strippingNewline: false) {
                stdinData.append(Data(line.utf8))
            }
            guard !stdinData.isEmpty else {
                Output.failMessage("No input provided. Use --file or pipe JSON to stdin.", code: "no_input")
            }
            data = stdinData
        }

        // Parse spec
        let decoder = JSONDecoder()
        let spec: ProjectSpec
        do {
            spec = try decoder.decode(ProjectSpec.self, from: data)
        } catch {
            Output.failMessage("Invalid project spec: \(error.localizedDescription)", code: "invalid_json")
        }

        // Validate
        guard !spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Output.failMessage("Project name is required", code: "invalid_input")
        }
        guard !spec.scenes.isEmpty else {
            Output.failMessage("Project must have at least one scene", code: "invalid_input")
        }

        // Create project from spec
        do {
            let project = try ProjectStore.createFromSpec(spec)
            ProjectStore.shared.save(project)
            Output.emitDict(project.jsonRepresentation)
        } catch let error as ProjectSpecError {
            Output.failMessage(error.errorDescription ?? error.localizedDescription, code: error.code)
        } catch {
            Output.failMessage(error.localizedDescription, code: "create_failed")
        }
    }
}
