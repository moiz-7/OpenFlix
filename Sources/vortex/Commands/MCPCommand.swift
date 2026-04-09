import ArgumentParser
import Foundation

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as MCP (Model Context Protocol) server over stdio",
        discussion: """
        Starts Vortex as an MCP server that communicates via stdin/stdout using JSON-RPC 2.0.
        This allows AI agents (Claude Code, etc.) to use Vortex as a native tool server.

        CONFIGURATION (claude_desktop_config.json or .claude.json):
          {
            "mcpServers": {
              "vortex": {
                "command": "vortex",
                "args": ["mcp"]
              }
            }
          }

        EXPOSED TOOLS (14):
          generate, generate_submit, generate_poll, list_generations,
          get_generation, cancel_generation, retry_generation, list_providers,
          evaluate_quality, submit_feedback, get_metrics, budget_status,
          project_run, health_check

        EXPOSED RESOURCES (3):
          vortex://providers, vortex://metrics, vortex://budget
        """
    )

    func run() async throws {
        await MCPServer().run()
    }
}
