import ArgumentParser
import Foundation

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the openflix daemon for persistent agent connections",
        discussion: """
        The daemon provides a persistent Unix socket server for agent connections.
        Agents can submit jobs, subscribe to events, and manage projects via JSON-RPC.

        EXAMPLES
          openflix daemon start --foreground
          openflix daemon status
          openflix daemon stop
        """,
        subcommands: [DaemonStart.self, DaemonStop.self, DaemonStatusCmd.self]
    )
}

struct DaemonStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the openflix daemon"
    )

    @Flag(name: .long, help: "Run in foreground (for debugging)")
    var foreground: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let (running, pid) = DaemonServer.isRunning()
        if running {
            Output.failMessage("Daemon already running (PID \(pid ?? 0))", code: "already_running")
        }

        if foreground {
            let server = DaemonServer()
            Output.emitDict([
                "event": "daemon.starting",
                "socket": DaemonServer.defaultSocketPath,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "foreground": true,
            ])
            try await server.start()
            // Keep running until signal
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                // Block forever — daemon runs until killed
            }
        } else {
            // Background: fork/exec is complex in Swift. For now, suggest nohup.
            Output.emitDict([
                "message": "Use 'nohup openflix daemon start --foreground &' to run in background",
                "socket": DaemonServer.defaultSocketPath,
            ])
        }
    }
}

struct DaemonStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the openflix daemon"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let (running, pid) = DaemonServer.isRunning()
        guard running, let daemonPid = pid else {
            Output.failMessage("Daemon is not running", code: "not_running")
        }

        kill(Int32(daemonPid), SIGTERM)

        // Clean up socket and PID files
        try? FileManager.default.removeItem(atPath: DaemonServer.defaultSocketPath)
        try? FileManager.default.removeItem(atPath: DaemonServer.defaultPidPath)

        Output.emitDict([
            "stopped": true,
            "pid": daemonPid,
        ])
    }
}

struct DaemonStatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check if the openflix daemon is running"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let (running, pid) = DaemonServer.isRunning()

        var d: [String: Any] = [
            "running": running,
            "socket": DaemonServer.defaultSocketPath,
        ]
        if let p = pid { d["pid"] = p }

        Output.emitDict(d)
    }
}
