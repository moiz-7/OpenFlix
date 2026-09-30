import ArgumentParser
import Foundation
import OpenFlixKit

/// The machine surface: every action the MCP server offers, callable from a
/// shell with JSON in and one JSON document out. For agents that wrap CLIs
/// instead of speaking MCP, and for anything that wants the action manifest.
struct ActionGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "action",
        abstract: "List and run OpenFlix actions with JSON in and JSON out (for agents)",
        discussion: """
        The same actions the MCP server (`openflix mcp`) exposes, with the same
        argument validation, callable from a shell. `list` prints the manifest:
        every action's JSON Schema, its effect (read, spend, share, ...) and the
        MCP annotations derived from it. `run` takes the arguments as JSON and
        prints one result envelope (contract openflix.action_result.v1).

        Actions whose effect is "spend" charge the user's own provider accounts,
        exactly as they do over MCP.

        EXAMPLES
          openflix action list --pretty
          openflix action run budget_status
          openflix action run list_generations --input '{"status":"failed","limit":5}'
          echo '{"prompt":"a fox at dusk","route":"smart"}' | openflix action run generate_submit --input -
        """,
        subcommands: [ActionList.self, ActionRun.self]
    )
}

struct ActionList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print the action manifest (contract openflix.action_manifest.v1)"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        print(CLIActionCatalog.manifest.jsonString(pretty: pretty))
    }
}

struct ActionRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run one action and print its result envelope",
        discussion: """
        Prints exactly one JSON document to stdout:
          {"contract":"openflix.action_result.v1","action":...,"status":"ok","data":{...}}
        or, when it did not succeed,
          {"contract":...,"status":"refused"|"failed","error":{"code","class","message","retryable"}}

        "refused" means nothing was attempted (bad arguments, a budget or safety
        rule, an unknown id) and the call can be corrected at no cost. "failed"
        means it was attempted and something broke (a provider error).

        Progress from long-running actions (project_run) is written to stderr,
        one JSON object per line, so stdout stays a single document.

        EXIT CODES
          0  ok      2  refused      1  failed
        """
    )

    @Argument(help: "Action name, e.g. list_generations (see `openflix action list`)")
    var name: String

    @Option(name: .long, help: "Arguments as a JSON object, or - to read them from stdin. Default: {}")
    var input: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        let envelope = await Self.execute(name: name, rawInput: input,
                                          readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
                                          progress: Self.stderrProgress)
        print(envelope.jsonString(pretty: pretty))
        let status = envelope["status"]?.stringValue
        if status == "refused" { throw ExitCode(2) }
        if status == "failed" { throw ExitCode(1) }
    }

    /// Everything but the printing and the exit code, so tests can drive it
    /// without a process.
    static func execute(name: String, rawInput: String?,
                        readStdin: () -> Data,
                        progress: (@Sendable (ActionProgress) -> Void)?) async -> JSONValue {
        let arguments: [String: AnyCodableValue]
        do {
            arguments = try parseInput(rawInput, readStdin: readStdin)
        } catch let input as ActionInputError {
            return ActionResult.failure(action: name, ActionFailure(input))
        } catch {
            return ActionResult.failure(action: name, CLIActions.failure(from: error))
        }

        do {
            let data = try await CLIActions.run(
                name, arguments: arguments,
                context: ActionContext(caller: .localAgent(nil), progress: progress))
            return ActionResult.success(action: name, data: JSONValue(any: data))
        } catch {
            return ActionResult.failure(action: name, CLIActions.failure(from: error))
        }
    }

    static func parseInput(_ raw: String?, readStdin: () -> Data) throws -> [String: AnyCodableValue] {
        guard let raw else { return [:] }
        let data = raw == "-" ? readStdin() : Data(raw.utf8)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let value = try? JSONDecoder().decode(AnyCodableValue.self, from: data),
              case .dictionary(let object) = value else {
            throw ActionInputError(argument: nil, message: "--input must be a JSON object")
        }
        return object
    }

    private static let stderrProgress: @Sendable (ActionProgress) -> Void = { p in
        let line = JSONValue.object([
            "event": .string("progress"),
            "completed": .int(p.completed),
            "total": .int(p.total),
            "message": .string(p.message),
        ]).jsonString()
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
