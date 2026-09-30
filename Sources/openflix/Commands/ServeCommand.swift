import ArgumentParser
import Foundation
import OpenFlixKit

/// `openflix serve` — the HTTP bridge for agents on other machines.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the HTTP bridge so agents on other machines can use OpenFlix",
        discussion: """
        Serves every OpenFlix action over HTTP to agents holding a grant (see
        `openflix agents`). Listens on 127.0.0.1 ONLY. To reach it from another
        machine, put Tailscale Serve in front of it, which adds HTTPS and keeps
        it on your tailnet (never the public internet):

          openflix serve
          tailscale serve --bg http://127.0.0.1:18790

        The bridge also relays the running app's library and player tools over
        the app's own socket, when the app is open and agent access is on in its
        Settings. It can never allow more than the app's own setting does.

        Spending actions need a quote first: POST /v1/actions/<name>:preflight
        returns an op_hash; after the user approves, POST /v1/actions/<name>
        with headers OpenFlix-Quote: <op_hash> and Idempotency-Key: <unique>.
        Each agent's spending is limited by its grant's daily cap.

        ROUTES
          GET  /v1/health
          GET  /v1/manifest
          POST /v1/actions/<name>:preflight
          POST /v1/actions/<name>
        """
    )

    @Option(name: .long, help: "Port on 127.0.0.1 (default \(BridgeServer.defaultPort))")
    var port: Int = Int(BridgeServer.defaultPort)

    @Flag(name: .customLong("no-app"), help: "Do not relay the app's library and player tools")
    var noApp: Bool = false

    mutating func run() async throws {
        guard (1...65535).contains(port) else {
            Output.failMessage("--port must be 1-65535", code: "invalid_input")
        }
        let router = BridgeRouter(grants: .shared, gate: BridgeGate(), relay: noApp ? nil : AppRelay())
        let server = BridgeServer(port: UInt16(port), router: router)
        let bound: UInt16
        do {
            bound = try await server.start()
        } catch {
            Output.failMessage("Could not listen on 127.0.0.1:\(port): \(error)", code: "listen_failed")
        }

        let grants = AgentGrantStore.shared.all()
        var ready: [String: Any] = [
            "event": "bridge.ready",
            "url": "http://127.0.0.1:\(bound)",
            "agents": grants.map(\.name),
            "app_relay": !noApp,
        ]
        if grants.isEmpty {
            ready["note"] = "No agent grants yet — nothing can authenticate. Create one with: openflix agents grant <name>"
        }
        if let data = try? JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys, .withoutEscapingSlashes]),
           let line = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        CLILog.info("bridge.started", ["port": Int(bound), "agents": grants.count, "app_relay": !noApp])

        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        }
        server.stop()
    }
}
