import Foundation
import OpenFlixKit

/// The bridge's view of the running OpenFlix app: its MCP tools (library
/// search, player state and control, recent generations), reached over the
/// app's own Unix socket.
///
/// Relaying — rather than the app opening a port — keeps the app's security
/// decision intact: it listens on a `0600` socket only, off by default, with
/// its own read-only / control levels chosen in its Settings. The bridge adds
/// the remote agent's grant on top; it can never widen what the app allows.
///
/// Each call is its own connection, speaking MCP's stateless `2026-07-28` form
/// (no handshake, the protocol version in every request's `_meta`), which the
/// app server answers natively.
struct AppRelay: Sendable {

    static let host = "openflix-app"
    static let protocolVersion = "2026-07-28"

    let socketPath: String
    let timeoutSeconds: Int

    init(socketPath: String? = nil, timeoutSeconds: Int = 8) {
        self.socketPath = socketPath ?? Self.defaultSocketPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// Same override the app itself honours (`OPENFLIX_MCP_SOCKET`).
    static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["OPENFLIX_MCP_SOCKET"], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenFlix/mcp.sock").path
    }

    enum RelayError: Error, Equatable {
        /// No socket: the app is not running, or agent access is off in its Settings.
        case unavailable(String)
        case protocolError(String)
    }

    // MARK: - Tools

    /// The app's tools as action descriptors, with each effect derived from
    /// the app's own annotations.
    func descriptors() async throws -> [ActionDescriptor] {
        let result = try await request(method: "tools/list", params: [:])
        guard let tools = result["tools"]?.arrayValue else {
            throw RelayError.protocolError("tools/list returned no tools array")
        }
        return tools.compactMap(Self.descriptor(from:))
    }

    static func descriptor(from tool: JSONValue) -> ActionDescriptor? {
        guard let name = tool["name"]?.stringValue, ActionDescriptor.isWellFormedName(name) else { return nil }
        let hints = tool["annotations"]
        let readOnly = hints?["readOnlyHint"]?.boolValue ?? false
        // MCP's defaults are pessimistic: unannotated means destructive and
        // open-world. Keep them pessimistic here too.
        let destructive = hints?["destructiveHint"]?.boolValue ?? true
        let effect: ActionEffect = readOnly ? .read : (destructive ? .destructive : .control)
        return ActionDescriptor(
            name: name,
            title: tool["title"]?.stringValue ?? name,
            description: tool["description"]?.stringValue ?? name,
            effect: effect,
            openWorld: hints?["openWorldHint"]?.boolValue ?? true,
            idempotent: hints?["idempotentHint"]?.boolValue ?? false,
            inputSchema: tool["inputSchema"] ?? JSONSchema.object(properties: [:]),
            outputSchema: tool["outputSchema"],
            // Titles, file names and transcript lines come from the user's
            // media — text nobody here wrote. An agent host must treat it as
            // data, never as instructions.
            returnsUntrustedText: true)
    }

    /// Runs one app tool. A tool that answered with `isError` is a refusal by
    /// the app (for example, control is not enabled in its Settings).
    func call(_ name: String, arguments: JSONValue) async throws -> Result<JSONValue, ActionFailure> {
        let result: JSONValue
        do {
            result = try await request(method: "tools/call", params: ["name": .string(name), "arguments": arguments])
        } catch let RelayError.protocolError(message) where message.hasPrefix("rpc ") {
            return .failure(ActionFailure(code: "APP_RPC_ERROR", errorClass: .invalidInput, message: message))
        }

        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue
        let parsed = text.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }

        if result["isError"]?.boolValue == true {
            let message = parsed?["message"]?.stringValue ?? parsed?["error"]?.stringValue ?? text ?? "the app refused"
            return .failure(ActionFailure(code: "APP_REFUSED", errorClass: .policy, message: message, details: parsed))
        }
        return .success(result["structuredContent"] ?? parsed ?? .object(["text": .string(text ?? "")]))
    }

    // MARK: - Wire

    private func request(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        var withMeta = params
        withMeta["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(Self.protocolVersion),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
            "io.modelcontextprotocol/clientInfo": .object(["name": .string("openflix-bridge"),
                                                           "version": .string(OpenFlixVersion.current)]),
        ])
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(1),
            "method": .string(method), "params": .object(withMeta),
        ])
        let path = socketPath, timeout = timeoutSeconds
        let reply: JSONValue = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.exchange(message, socketPath: path, timeoutSeconds: timeout) })
            }
        }
        if let error = reply["error"] {
            throw RelayError.protocolError("rpc \(error["code"]?.intValue ?? 0): \(error["message"]?.stringValue ?? "error")")
        }
        guard let result = reply["result"] else {
            throw RelayError.protocolError("reply carried neither result nor error")
        }
        return result
    }

    /// One newline-delimited JSON-RPC request and its reply, on a fresh
    /// connection. Blocking, so it runs off the cooperative pool.
    private static func exchange(_ message: JSONValue, socketPath: String, timeoutSeconds: Int) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw RelayError.unavailable("The OpenFlix app is not listening (no socket at \(socketPath)). Open the app and turn on Settings → AI Agents → Let an Agent Use OpenFlix.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.unavailable("could not create a socket") }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw RelayError.unavailable("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw RelayError.unavailable("The OpenFlix app's socket refused the connection — the app may have quit or turned agent access off.")
        }

        let line = Data((message.jsonString() + "\n").utf8)
        let sent = line.withUnsafeBytes { send(fd, $0.baseAddress, line.count, 0) }
        guard sent == line.count else { throw RelayError.unavailable("could not send to the app") }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else {
                throw RelayError.unavailable(n == 0 ? "the app closed the connection without replying"
                                                    : "the app did not reply within \(timeoutSeconds)s")
            }
            buffer.append(contentsOf: chunk[0..<n])
            guard buffer.count <= 8 * 1024 * 1024 else { throw RelayError.protocolError("reply too large") }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let first = buffer[buffer.startIndex..<newline]
                guard let reply = try? JSONDecoder().decode(JSONValue.self, from: first) else {
                    throw RelayError.protocolError("the app replied with something that is not JSON")
                }
                return reply
            }
        }
    }
}
