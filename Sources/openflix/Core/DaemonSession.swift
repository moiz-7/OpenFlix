import Foundation
import Network

/// Per-connection state for a daemon client.
class DaemonSession {
    let id: UUID
    let connection: NWConnection
    var subscribedProjects: Set<String> = []

    init(connection: NWConnection) {
        self.id = UUID()
        self.connection = connection
    }

    /// Start reading newline-delimited JSON from the connection.
    func startReading(handler: @escaping (Data) -> Void) {
        readNextLine(handler: handler)
    }

    private func readNextLine(handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let data = content, !data.isEmpty {
                // Split on newlines in case multiple messages arrive together
                let lines = data.split(separator: UInt8(ascii: "\n"))
                for line in lines {
                    handler(Data(line))
                }
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.readNextLine(handler: handler)
            }
        }
    }

    /// Send a response to this connection.
    func send(_ response: DaemonResponse, encoder: JSONEncoder) {
        guard let data = try? encoder.encode(response) else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    /// Send an event to this connection.
    func sendEvent(_ event: DaemonEvent, encoder: JSONEncoder) {
        guard let data = try? encoder.encode(event) else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}
