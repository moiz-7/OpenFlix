import Foundation
import Network

/// The bridge's listener: TCP on **127.0.0.1 only**.
///
/// Nothing here listens on a network interface. To reach it from another
/// machine you put a tunnel you already trust in front of it — Tailscale
/// Serve (`tailscale serve --bg http://127.0.0.1:<port>`) gives it HTTPS on
/// your tailnet only, never the public internet. That keeps TLS, device
/// identity and reachability in a tool built for them instead of in this one.
///
/// One request per connection; each connection is closed after its answer
/// or after `connectionTimeout`, whichever comes first.
final class BridgeServer: @unchecked Sendable {

    static let defaultPort: UInt16 = 18790
    static let connectionTimeout: TimeInterval = 30

    private let router: BridgeRouter
    private let requestedPort: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "openflix.bridge", qos: .userInitiated)

    init(port: UInt16 = BridgeServer.defaultPort, router: BridgeRouter) {
        self.requestedPort = port
        self.router = router
    }

    /// Starts listening and returns the bound port (useful with port 0).
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
            throw OpenFlixError.invalidInput("invalid port \(requestedPort)")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)

        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? port.rawValue) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                    CLILog.error("bridge.listener_failed", ["error": "\(error)"])
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: deadline)
        receive(on: connection, buffer: Data(), deadline: deadline)
    }

    private func receive(on connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch BridgeHTTPParser.parse(buffer) {
            case .complete(let request):
                Task {
                    let response = await self.router.handle(request)
                    self.send(response, on: connection, deadline: deadline)
                }
            case .invalid(let status, let message):
                self.send(.json(status, .object(["error": .object([
                    "code": .string("BAD_REQUEST"), "message": .string(message)])])),
                          on: connection, deadline: deadline)
            case .incomplete:
                if isComplete || error != nil {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, deadline: deadline)
                }
            }
        }
    }

    private func send(_ response: BridgeHTTPResponse, on connection: NWConnection, deadline: DispatchWorkItem) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            deadline.cancel()
            connection.cancel()
        })
    }

    /// A continuation may be resumed once; listener states can repeat.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
