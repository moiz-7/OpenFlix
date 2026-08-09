import ArgumentParser
import Foundation

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as MCP (Model Context Protocol) server over stdio",
        discussion: """
        Starts OpenFlix as an MCP server that communicates via stdin/stdout using JSON-RPC 2.0.
        This allows AI agents (Claude Code, etc.) to use OpenFlix as a native tool server.

        CONFIGURATION (claude_desktop_config.json or .claude.json):
          {
            "mcpServers": {
              "openflix": {
                "command": "openflix",
                "args": ["mcp"]
              }
            }
          }

        PROTOCOL — dual-era. Serves 2026-07-28, 2025-06-18 and 2024-11-05.
        A modern client may skip the handshake entirely and call server/discover
        with its protocol version in per-request _meta; a legacy client keeps
        using initialize exactly as before. Naming a revision this server does
        not serve returns -32022 with the list to retry with, rather than the
        silence a legacy-only server answers with.

        EXPOSED TOOLS (15):
          generate, generate_submit, generate_poll, list_generations,
          get_generation, cancel_generation, retry_generation, list_providers,
          evaluate_quality, submit_feedback, submit_vote, get_metrics,
          budget_status, project_run, health_check

        Every tool is annotated, so a client can tell a local read from a call
        that spends money before it makes it: generate, generate_submit,
        retry_generation and cancel_generation are readOnlyHint:false +
        destructiveHint:true; list_providers, get_metrics, budget_status and the
        other reads are readOnlyHint:true + openWorldHint:false.

        generate/generate_submit accept route:"smart" (+ optional category)
        instead of provider+model to auto-select by community win rate.

        EXPOSED RESOURCES (3 + 2 templates):
          openflix://providers, openflix://metrics, openflix://budget
          openflix://generation/{id}, openflix://recipe/{id}

        EXPOSED PROMPTS:
          compare_providers, budget_check, plus every saved .openflix recipe as
          recipe_<id> with its declared args as typed prompt arguments (enum
          args autocomplete through completion/complete). Rendering a prompt
          returns text — it never submits a generation.
        """
    )

    func run() async throws {
        await MCPServer().run()
    }
}
