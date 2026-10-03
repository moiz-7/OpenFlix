import ArgumentParser
import Foundation
import OpenFlixKit

/// `openflix integrate` — make OpenFlix available to an agent framework.
struct Integrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "integrate",
        abstract: "Install the OpenFlix skill and MCP server for OpenClaw or Hermes",
        discussion: """
        Installs the OpenFlix skill (one SKILL.md both agents read) where the
        agent loads skills, and prints the agent's own command to add the
        OpenFlix MCP server. --register runs that command for you.

          OpenClaw  skill → ~/.openclaw/skills/openflix/SKILL.md
          Hermes    skill → ~/.hermes/skills/media/openflix/SKILL.md

        For an agent on ANOTHER machine, pass --remote with the URL your
        `openflix serve` is reachable at (e.g. through `tailscale serve`); the
        output is the MCP config to paste on that machine, and the skill to copy.

        EXAMPLES
          openflix integrate openclaw --register
          openflix integrate hermes
          openflix integrate hermes --remote https://my-mac.tailnet.ts.net
          openflix integrate print-skill > SKILL.md
        """
    )

    enum Target: String, ExpressibleByArgument, CaseIterable {
        case openclaw, hermes
        case printSkill = "print-skill"
    }

    @Argument(help: "openclaw, hermes, or print-skill")
    var target: Target

    @Flag(name: .long, help: "Also run the agent's own `mcp add` command")
    var register: Bool = false

    @Option(name: .long, help: "The https URL of `openflix serve` for an agent on another machine")
    var remote: String?

    @Option(name: .customLong("skills-dir"), help: "Install the skill under this directory instead")
    var skillsDir: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        if target == .printSkill {
            print(EmbeddedSkill.markdown)
            return
        }
        let agent: AgentIntegration = target == .openclaw ? .openclaw : .hermes

        if let remote {
            guard let url = AgentIntegration.mcpURL(fromRemote: remote) else {
                Output.failMessage("--remote must be an https URL (e.g. https://my-mac.tailnet.ts.net)", code: "invalid_input")
            }
            Output.emitDict([
                "agent": agent.name,
                "mode": "remote",
                "mcp_config": agent.remoteConfig(url: url),
                "skill": "On the agent's machine: mkdir -p ~/\((agent.skillRelativePath as NSString).deletingLastPathComponent) && openflix integrate print-skill > ~/\(agent.skillRelativePath)  (or copy skills/openflix/SKILL.md there)",
                "token": "Issue one here with: openflix agents grant \(agent.name) --effects read,refresh,control (add spend and --daily-cap to let it spend)",
            ])
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let skillFile: URL
        if let skillsDir {
            skillFile = URL(fileURLWithPath: (skillsDir as NSString).expandingTildeInPath)
                .appendingPathComponent("openflix/SKILL.md")
        } else {
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.homeDirectory).path) else {
                Output.failMessage("~/\(agent.homeDirectory) does not exist — is \(agent.displayName) installed? Pass --skills-dir to install the skill somewhere else.", code: "not_found")
            }
            skillFile = home.appendingPathComponent(agent.skillRelativePath)
        }

        do {
            try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try (EmbeddedSkill.markdown + "\n").write(to: skillFile, atomically: true, encoding: .utf8)
        } catch {
            Output.failMessage("Could not write \(skillFile.path): \(error.localizedDescription)", code: "write_failed")
        }

        let binary = AgentIntegration.openflixPath()
        let command = agent.addCommand(openflixPath: binary)
        var out: [String: Any] = [
            "agent": agent.name,
            "skill_installed": skillFile.path,
            "mcp_add_command": command.joined(separator: " "),
            "mcp_config": agent.localConfig(openflixPath: binary),
        ]
        if register {
            let result = AgentIntegration.run(command)
            out["registered"] = result.ok
            if !result.ok {
                out["register_error"] = result.output
                out["next_step"] = "Run the mcp_add_command yourself, or add mcp_config to the agent's config."
            }
        } else {
            out["next_step"] = "Run mcp_add_command (or pass --register) so the agent gets OpenFlix's typed tools."
        }
        Output.emitDict(out)
    }
}

/// The per-agent facts `integrate` needs: where skills go, how each adds an
/// MCP server, and the config shape for a remote one.
enum AgentIntegration {
    case openclaw, hermes

    var name: String { self == .openclaw ? "openclaw" : "hermes" }
    var displayName: String { self == .openclaw ? "OpenClaw" : "Hermes" }
    var homeDirectory: String { self == .openclaw ? ".openclaw" : ".hermes" }

    /// Hermes requires the directory name to equal the skill name, and groups
    /// skills by category.
    var skillRelativePath: String {
        self == .openclaw ? ".openclaw/skills/openflix/SKILL.md" : ".hermes/skills/media/openflix/SKILL.md"
    }

    func addCommand(openflixPath: String) -> [String] {
        switch self {
        case .openclaw: return ["openclaw", "mcp", "add", "openflix", "--command", openflixPath, "--arg", "mcp"]
        case .hermes:   return ["hermes", "mcp", "add", "openflix", "--command", openflixPath, "--args", "mcp"]
        }
    }

    /// For `~/.openclaw/openclaw.json` (`mcp.servers`) or `~/.hermes/config.yaml`
    /// (`mcp_servers`) — shown as data, written by the agent's own CLI.
    func localConfig(openflixPath: String) -> [String: Any] {
        switch self {
        case .openclaw:
            return ["mcp": ["servers": ["openflix": ["command": openflixPath, "args": ["mcp"]]]]]
        case .hermes:
            return ["mcp_servers": ["openflix": ["command": openflixPath, "args": ["mcp"], "timeout": 600]]]
        }
    }

    /// Streamable HTTP against `openflix serve`. OpenClaw needs the transport
    /// spelled out: with a bare `url` it assumes SSE.
    func remoteConfig(url: String) -> [String: Any] {
        switch self {
        case .openclaw:
            return ["mcp": ["servers": ["openflix": [
                "url": url, "transport": "streamable-http",
                "headers": ["Authorization": "Bearer <token from openflix agents grant>"],
                "requestTimeoutMs": 600_000,
            ]]]]
        case .hermes:
            return ["mcp_servers": ["openflix": [
                "url": url,
                "headers": ["Authorization": "Bearer ${OPENFLIX_TOKEN}"],
                "timeout": 600,
            ]]]
        }
    }

    /// `https://host[:port]` → `https://host[:port]/mcp`. Only https: a token
    /// must not cross a network in the clear.
    static func mcpURL(fromRemote raw: String) -> String? {
        guard var c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.path = "/mcp"
        c.query = nil
        c.fragment = nil
        return c.url?.absoluteString
    }

    /// The absolute path of this binary, so the agent launches the same one.
    static func openflixPath() -> String {
        let argv0 = CommandLine.arguments.first ?? "openflix"
        // Any path form (absolute or ./relative) resolves against the current
        // directory; the agent launches it from somewhere else.
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(argv0)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return argv0
    }

    /// Runs the agent's CLI through `/usr/bin/env`, draining output first.
    static func run(_ command: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
