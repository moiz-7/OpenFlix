import Foundation
import Network

/// Persistent daemon server listening on a Unix domain socket.
/// Accepts JSON-RPC requests from agents and dispatches to handlers.
actor DaemonServer {
    private let socketPath: String
    private let pidPath: String
    private var listener: NWListener?
    private var sessions: [UUID: DaemonSession] = [:]
    private var executors: [String: DAGExecutor] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix/daemon.sock").path
    }

    static var defaultPidPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix/daemon.pid").path
    }

    init(socketPath: String? = nil, pidPath: String? = nil) {
        self.socketPath = socketPath ?? Self.defaultSocketPath
        self.pidPath = pidPath ?? Self.defaultPidPath
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Check if already running
        if let existingPid = readPid(), isProcessRunning(existingPid) {
            throw OpenFlixError.invalidResponse("Daemon already running (PID \(existingPid))")
        }

        // Remove stale socket
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create NWListener on Unix domain socket
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let nwListener = try NWListener(using: params)
        self.listener = nwListener

        // Write PID file
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: pidPath, atomically: true, encoding: .utf8
        )

        nwListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                fputs("{\"event\":\"daemon.ready\",\"socket\":\"\(self.socketPath)\"}\n", stderr)
            case .failed(let error):
                fputs("{\"error\":\"Daemon listener failed: \(error)\",\"code\":\"daemon_error\"}\n", stderr)
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleNewConnection(connection) }
        }

        nwListener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        // Cancel all executors
        for (_, executor) in executors {
            Task { await executor.cancel() }
        }

        // Close all sessions
        for (_, session) in sessions {
            session.close()
        }
        sessions.removeAll()
        executors.removeAll()

        // Stop listener
        listener?.cancel()
        listener = nil

        // Cleanup files
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let session = DaemonSession(connection: connection)
        sessions[session.id] = session

        session.startReading { [weak self] data in
            guard let self else { return }
            Task { await self.handleData(data, from: session) }
        }

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                guard let self else { return }
                Task { await self.removeSession(session.id) }
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func removeSession(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }

    private func handleData(_ data: Data, from session: DaemonSession) async {
        guard let request = try? decoder.decode(DaemonRequest.self, from: data) else {
            let response = DaemonResponse.failure(
                id: "unknown", code: "parse_error", message: "Invalid JSON-RPC request"
            )
            session.send(response, encoder: encoder)
            return
        }

        let response = await handleRequest(request, from: session)
        session.send(response, encoder: encoder)
    }

    // MARK: - Request Dispatch

    func handleRequest(_ request: DaemonRequest, from session: DaemonSession) async -> DaemonResponse {
        switch request.method {
        case DaemonMethods.health:
            return DaemonResponse.success(
                id: request.id,
                result: .dictionary([
                    "healthy": .bool(true),
                    "active_sessions": .int(sessions.count),
                    "active_projects": .int(executors.count),
                ])
            )

        case DaemonMethods.projectList:
            let projects = ProjectStore.shared.list()
            let items: [AnyCodableValue] = projects.map { p in
                .dictionary([
                    "id": .string(p.id),
                    "name": .string(p.name),
                    "status": .string(p.status.rawValue),
                ])
            }
            return DaemonResponse.success(id: request.id, result: .array(items))

        case DaemonMethods.projectStatus:
            guard case .string(let projectId) = request.params?["project_id"] else {
                return DaemonResponse.failure(id: request.id, code: "missing_param", message: "project_id required")
            }
            guard let project = ProjectStore.shared.get(projectId) else {
                return DaemonResponse.failure(id: request.id, code: "not_found", message: "Project not found")
            }
            return DaemonResponse.success(
                id: request.id,
                result: .dictionary([
                    "id": .string(project.id),
                    "name": .string(project.name),
                    "status": .string(project.status.rawValue),
                ])
            )

        case DaemonMethods.subscribe:
            guard case .string(let projectId) = request.params?["project_id"] else {
                return DaemonResponse.failure(id: request.id, code: "missing_param", message: "project_id required")
            }
            session.subscribedProjects.insert(projectId)
            return DaemonResponse.success(id: request.id, result: .dictionary(["subscribed": .bool(true)]))

        case DaemonMethods.unsubscribe:
            guard case .string(let projectId) = request.params?["project_id"] else {
                return DaemonResponse.failure(id: request.id, code: "missing_param", message: "project_id required")
            }
            session.subscribedProjects.remove(projectId)
            return DaemonResponse.success(id: request.id, result: .dictionary(["unsubscribed": .bool(true)]))

        case DaemonMethods.evaluate:
            guard case .string(let genId) = request.params?["generation_id"] else {
                return DaemonResponse.failure(id: request.id, code: "missing_param", message: "generation_id required")
            }
            guard let gen = GenerationStore.shared.get(genId) else {
                return DaemonResponse.failure(id: request.id, code: "not_found", message: "Generation not found")
            }
            guard let localPath = gen.localPath else {
                return DaemonResponse.failure(id: request.id, code: "no_local_path", message: "No local path for generation")
            }
            var config = QualityConfig()
            config.enabled = true
            if case .string(let e) = request.params?["evaluator"],
               let t = QualityConfig.EvaluatorType(rawValue: e) {
                config.evaluator = t
            }
            do {
                let result = try await QualityGate.evaluate(
                    generation: gen, videoPath: localPath, shot: nil, config: config
                )
                return DaemonResponse.success(id: request.id, result: AnyCodableValue.from(result.jsonRepresentation))
            } catch {
                return DaemonResponse.failure(id: request.id, code: "eval_error", message: error.localizedDescription)
            }

        case DaemonMethods.feedback:
            guard case .string(let genId) = request.params?["generation_id"] else {
                return DaemonResponse.failure(id: request.id, code: "missing_param", message: "generation_id required")
            }
            guard case .double(let score) = request.params?["score"] else {
                return DaemonResponse.failure(id: request.id, code: "missing_param", message: "score required")
            }
            guard let gen = GenerationStore.shared.get(genId) else {
                return DaemonResponse.failure(id: request.id, code: "not_found", message: "Generation not found")
            }
            ProviderMetricsStore.shared.recordFeedback(provider: gen.provider, model: gen.model, score: score)
            return DaemonResponse.success(id: request.id, result: .dictionary(["recorded": .bool(true)]))

        case DaemonMethods.providerMetrics:
            let metrics = ProviderMetricsStore.shared.allMetrics()
            let items: [AnyCodableValue] = metrics.map { AnyCodableValue.from($0.jsonRepresentation) }
            return DaemonResponse.success(id: request.id, result: .array(items))

        default:
            return DaemonResponse.failure(
                id: request.id, code: "unknown_method",
                message: "Unknown method: \(request.method)"
            )
        }
    }

    // MARK: - Event Broadcasting

    func broadcast(event: DaemonEvent, projectId: String) {
        for session in sessions.values where session.subscribedProjects.contains(projectId) {
            session.sendEvent(event, encoder: encoder)
        }
    }

    // MARK: - Status

    var status: [String: Any] {
        [
            "running": listener != nil,
            "socket": socketPath,
            "active_sessions": sessions.count,
            "active_projects": executors.count,
        ]
    }

    static func isRunning() -> (running: Bool, pid: Int?) {
        guard let pidStr = try? String(contentsOfFile: defaultPidPath, encoding: .utf8),
              let pid = Int(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (false, nil)
        }
        // Check if process exists
        if kill(Int32(pid), 0) == 0 {
            return (true, pid)
        }
        // Stale PID file
        try? FileManager.default.removeItem(atPath: defaultPidPath)
        try? FileManager.default.removeItem(atPath: defaultSocketPath)
        return (false, nil)
    }

    // MARK: - Private

    private func readPid() -> Int? {
        guard let str = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return nil }
        return Int(str.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isProcessRunning(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }
}
