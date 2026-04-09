import ArgumentParser
import Foundation

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a generation from local history",
        discussion: """
        Removes a generation record from ~/.vortex/store.json.
        This does not cancel remote jobs or delete downloaded files.

        EXAMPLES
          vortex delete <generation-id>
        """
    )

    @Argument(help: "Generation ID to delete")
    var id: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let gen = GenerationStore.shared.get(id) else {
            Output.failMessage("Generation '\(id)' not found.", code: "not_found")
        }

        GenerationStore.shared.delete(id)
        Output.emitDict(["id": id, "deleted": true, "status": gen.status.rawValue])
    }
}
