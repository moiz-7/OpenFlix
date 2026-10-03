import Foundation
import OpenFlixKit

/// Opens video in the OpenFlix app — the one player agents should use.
///
/// Two routes, best first:
///
/// 1. **The app's own socket** (`player_control`), when the app is running
///    with agent access on. It answers, and it can seek.
/// 2. **An `openflix://` deep link** through LaunchServices otherwise. It needs
///    no setting — the app already accepts these from any process on the Mac —
///    and it launches the app if it is closed. It cannot seek or confirm.
///
/// Agents otherwise reach for `open`, VLC or QuickTime, which plays the file in
/// some other player with none of the library, transcripts or generation
/// history attached. Every surface that shows video to a person points here.
struct PlaybackLauncher: Sendable {

    enum Target: Equatable {
        case file(String)
        case stream(URL)
        case generation(String)
    }

    /// Hands an `openflix://` URL to LaunchServices. Injectable so tests never
    /// open an app.
    var openURL: @Sendable (URL) throws -> Void = PlaybackLauncher.openWithLaunchServices
    var relay: AppRelay? = AppRelay()

    // MARK: - Target resolution (pure)

    static func target(path: String?, url: String?, generationId: String?) throws -> Target {
        let given = [path, url, generationId].compactMap { $0 }.filter { !$0.isEmpty }
        guard given.count == 1 else {
            throw OpenFlixError.invalidInput("Pass exactly one of path, url or generation_id.")
        }
        if let path, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw OpenFlixError.invalidInput("path must be absolute (got: \(path)).")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
                throw OpenFlixError.invalidInput("No file at \(expanded).")
            }
            return .file(URL(fileURLWithPath: expanded).standardizedFileURL.path)
        }
        if let url, !url.isEmpty {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw OpenFlixError.invalidInput("url must be http(s) (got: \(url)). For a file on this Mac, pass path.")
            }
            return .stream(parsed)
        }
        let id = generationId ?? ""
        guard MCPIdentifier.isWellFormed(id) else {
            throw OpenFlixError.invalidInput("generation_id is not a valid id.")
        }
        guard GenerationStore.shared.get(id) != nil else { throw OpenFlixError.generationNotFound(id) }
        return .generation(id)
    }

    /// The deep link for a target. Generation ids resolve inside the app
    /// (`GenerationDeepLinkResolver` checks the app DB, then `~/.openflix`, then
    /// the registry), so a CLI generation opens as itself, not as a bare file.
    static func deepLink(for target: Target) -> URL? {
        var c = URLComponents()
        c.scheme = "openflix"
        switch target {
        case .file(let path):
            c.host = "open"
            c.queryItems = [URLQueryItem(name: "path", value: path)]
        case .stream(let url):
            c.host = "play"
            c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        case .generation(let id):
            c.host = "generation"
            c.path = "/" + id
        }
        return c.url
    }

    // MARK: - Playing

    func play(_ target: Target, seekSeconds: Double? = nil) async throws -> [String: Any] {
        // The socket can seek and confirms; try it first for a local file.
        if case .file(let path) = target, let relay {
            var arguments: [String: JSONValue] = ["action": .string("open"), "path": .string(path)]
            if let seekSeconds, seekSeconds.isFinite, seekSeconds >= 0 { arguments["seek_to"] = .double(seekSeconds) }
            if case .success(let data)? = try? await relay.call("player_control", arguments: .object(arguments)) {
                return ["status": "playing", "via": "app_socket", "path": path, "player": data.anyValue]
            }
        }

        guard let link = Self.deepLink(for: target) else {
            throw OpenFlixError.invalidInput("Could not form an openflix:// link for that target.")
        }
        try openURL(link)
        var result: [String: Any] = ["status": "opened", "via": "deep_link", "link": link.absoluteString]
        switch target {
        case .file(let path): result["path"] = path
        case .stream(let url): result["url"] = url.absoluteString
        case .generation(let id): result["generation_id"] = id
        }
        if seekSeconds != nil {
            result["note"] = "Opened without seeking: seeking needs OpenFlix → Settings → AI Agents → Read & control playback."
        }
        return result
    }

    func control(_ action: String) throws -> [String: Any] {
        guard action == "pause" || action == "resume" else {
            throw OpenFlixError.invalidInput("action must be pause or resume.")
        }
        guard let link = URL(string: action == "pause" ? "openflix://pause" : "openflix://play") else {
            throw OpenFlixError.invalidInput("bad link")
        }
        try openURL(link)
        return ["status": action == "pause" ? "paused" : "resumed", "via": "deep_link"]
    }

    // MARK: - LaunchServices

    /// `/usr/bin/open <openflix://…>`. Fails with a clear message when no app
    /// claims the scheme, which means OpenFlix is not installed.
    static let openWithLaunchServices: @Sendable (URL) throws -> Void = { url in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        // Drain before waiting: a full pipe would otherwise block the child.
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenFlixError.invalidResponse(
                "Could not open OpenFlix (is the app installed in /Applications?): "
                + message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
