# MCP Quickstart — drive OpenFlix from an AI agent

OpenFlix ships a built-in MCP (Model Context Protocol) server: `openflix mcp`
speaks JSON-RPC 2.0 over stdio, so any MCP-capable agent (Claude Code, Claude
Desktop, etc.) can generate video, check budgets, and vote on results as
native tools.

It is **dual-era**: it serves the current stateless revision (`2026-07-28` —
`server/discover`, per-request `_meta`, no handshake) *and* the handshake-based
revisions clients use today (`2025-06-18`, `2024-11-05`), on the same pipe with
no configuration. See [`mcp-protocol.md`](mcp-protocol.md) for the details, the
tool annotations, and what was deliberately left out.

## 1. Install the CLI

```bash
brew tap moiz-7/openflix && brew install openflix
```

## 2. Set up at least one provider key

`keys set` takes the key as an argument (it is not prompted):

```bash
openflix keys set fal <your-fal-key>
```

Seven providers are supported: `fal`, `replicate`, `runway`, `luma`, `kling`,
`minimax`, and `local` (ComfyUI — keyless, $0). Keys are stored in the macOS
Keychain.

## 3. Set a budget (recommended before letting an agent spend)

```bash
openflix budget set --daily-limit 5 --per-generation-max 1 --monthly-limit 50
```

Every generation the agent submits is estimated first and blocked if it would
exceed a limit. `budget_status` (tool) or `openflix budget` shows current spend.

## 4. Register the server

Claude Code:

```bash
claude mcp add openflix -- openflix mcp
```

Claude Desktop (`claude_desktop_config.json`) or `.claude.json`:

```json
{
  "mcpServers": {
    "openflix": {
      "command": "openflix",
      "args": ["mcp"]
    }
  }
}
```

## The 15 tools

| Tool | What it does |
|------|--------------|
| `generate` | Submit, wait for completion, and download in one call. Pass `provider`+`model`, or `route: "smart"` (see below). |
| `generate_submit` | Fire-and-forget submit; returns a generation id. Same `route: "smart"` support. |
| `generate_poll` | Poll a generation's status (optionally block with `wait`). |
| `list_generations` | List past generations. |
| `get_generation` | Fetch one generation record. |
| `cancel_generation` | Cancel an in-flight generation. |
| `retry_generation` | Retry a failed generation (preserves reference image + params). |
| `list_providers` | List the 7 providers and their models. |
| `evaluate_quality` | Score a downloaded video (0-100 heuristic quality gate). |
| `submit_feedback` | **Local-only** quality note on one generation — never leaves the machine. |
| `submit_vote` | **Share a pairwise preference vote with the community** (winner beat loser) — feeds `--route smart` for everyone. Only provider/model names + optional category are sent; deduplicated server-side, safe to retry. |
| `get_metrics` | Provider performance metrics (quality, latency, cost, success rate). |
| `budget_status` | Current spend vs. daily/per-generation/monthly limits. |
| `project_run` | Run a multi-shot project. |
| `health_check` | Which providers have a key on this machine (local Keychain read — it does not ping anyone). |

Every tool is annotated, so your agent's client can tell a local read from a
call that spends money **before** it makes it: `generate`, `generate_submit`,
`retry_generation` and `cancel_generation` are `readOnlyHint: false` +
`destructiveHint: true`; the reads are `readOnlyHint: true` +
`openWorldHint: false`. `submit_feedback` is the one write that is
`openWorldHint: false`, which is the wire saying out loud that it never leaves
the machine.

Plus 3 resources — `openflix://providers`, `openflix://metrics`,
`openflix://budget` — and 2 resource templates,
`openflix://generation/{id}` and `openflix://recipe/{id}`, which are the same
strings the OpenFlix app accepts as clickable deep links.

## Your recipes are prompts

Every saved `.openflix` recipe shows up in `prompts/list` as `recipe_<id>`, with
its declared args as typed prompt arguments — an arg with no default is
`required`, and an `enum` arg autocompletes its choices through
`completion/complete`. Two built-ins ship too: `compare_providers` and
`budget_check`.

Rendering a prompt returns **text only**. It never submits a generation —
spending stays an explicit `generate` tool call, which is budget-checked first.

## Smart routing from an agent

`generate` and `generate_submit` accept `route: "smart"` instead of an explicit
`provider`+`model` — the CLI picks the pair with the best community preference
win rate. Add `category` (e.g. `cinematic`, `anime`, `product`) for
category-aware routing:

```json
{"prompt": "golden hour city skyline, slow dolly", "route": "smart", "category": "cinematic"}
```

Close the loop: after comparing two generations, have the agent call
`submit_vote` with the winner and loser ids — that vote is the data smart
routing reads back.

## Feedback vs. vote

- `submit_feedback` — private, local-only score for your own metrics.
- `submit_vote` — anonymous community signal (provider/model + category only;
  never the prompt or the video). This is the one that improves routing for
  every OpenFlix user.
