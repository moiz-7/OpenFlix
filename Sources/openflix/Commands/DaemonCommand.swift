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
            // Actually daemonize. This used to print a suggestion to run nohup
            // yourself and exit 0 — so `openflix daemon start` reported success
            // while starting nothing, and `daemon status` then said the daemon
            // was down. Re-exec ourselves with --foreground, detached.
            try Self.spawnDetached()

            // Wait briefly for the socket so we report the truth rather than
            // an optimistic "started".
            var pid: Int?
            for _ in 0..<40 {   // up to ~2s
                try await Task.sleep(nanoseconds: 50_000_000)
                let (running, p) = DaemonServer.isRunning()
                if running { pid = p; break }
            }
            guard let pid else {
                Output.failMessage(
                    "Daemon did not come up within 2s — run 'openflix daemon start --foreground' to see why.",
                    code: "daemon_start_failed")
            }
            Output.emitDict([
                "event": "daemon.started",
                "socket": DaemonServer.defaultSocketPath,
                "pid": pid,
                "foreground": false,
            ])
        }
    }

    /// Re-exec this binary as `daemon start --foreground`, detached from the
    /// terminal, with stdio pointed at a log file so failures are diagnosable.
    private static func spawnDetached() throws {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw OpenFlixError.invalidResponse("Cannot open daemon log at \(logURL.path)")
        }
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = exe
        process.arguments = ["daemon", "start", "--foreground"]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Deliberately not waiting: the child outlives this process.
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
