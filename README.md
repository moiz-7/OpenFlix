# OpenFlix

**AI video generation from your terminal.** Bring your own API keys, generate videos from six providers, orchestrate multi-shot projects with DAG execution, and plug directly into AI agents via MCP.

[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](https://developer.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9%2B-orange)](https://swift.org)

---

## Table of Contents

1. [Install](#install)
2. [Quick Start](#quick-start)
3. [Why OpenFlix?](#why-openflix)
4. [Command Reference](#command-reference)
5. [Providers and Models](#providers-and-models)
6. [Budget and Safety](#budget-and-safety)
7. [MCP Server](#mcp-server)
8. [Daemon and Project Orchestration](#daemon-and-project-orchestration)
9. [Architecture](#architecture)
10. [Error Codes](#error-codes)
11. [Contributing](#contributing)
12. [License](#license)

---

## Install

### Homebrew (recommended)

```sh
brew install bubble-research/tap/openflix
```

### Build from source

Requirements: macOS 14+, Xcode 15+ or Swift 5.9+.

```sh
git clone https://github.com/moiz-7/OpenFlix.git
cd OpenFlix
swift build -c release
cp .build/release/openflix /usr/local/bin/
```

---

## Quick Start

```sh
# 1. Store your API key
openflix keys set fal YOUR_FAL_API_KEY

# 2. Generate a video and wait for the result
openflix generate "a red panda riding a skateboard through Tokyo" \
  --provider fal \
  --model fal-ai/veo3 \
  --wait

# 3. Check all your generations
openflix list --pretty
```

All output is newline-terminated JSON. Pipe it into `jq`, store it in a file, or feed it to another program without any parsing workarounds.

---

## Why OpenFlix?

### For humans

- **Bring Your Own Keys (BYOK):** your API keys are stored in the macOS Keychain, never sent anywhere except to the provider you choose.
- **Six providers, 24 models:** compare results across fal.ai, Replicate, Runway, Luma, Kling, and MiniMax without leaving the terminal.
- **Streaming progress:** pass `--stream` to receive newline-delimited JSON events as a generation moves from queued to processing to complete.
- **Cost visibility:** every generation records an estimated and actual cost. Run `openflix cost` for a per-provider breakdown.
- **Multi-shot projects:** define a scene graph in JSON, run it with `openflix project run`, and get a concat-ready ffmpeg manifest when it finishes.

### For AI agents

- **Machine-readable output:** every command emits JSON to stdout, every error emits JSON to stderr with a stable `code` field.
- **MCP server:** run `openflix mcp` to expose 14 tools and 3 resources over the Model Context Protocol. Works with Claude Code, Claude Desktop, and any MCP-compatible host.
- **Daemon socket:** a persistent Unix socket server (`~/.vortex/daemon.sock`) accepts JSON-RPC 2.0 messages for agents that need long-lived connections.
- **Structured error taxonomy:** 18 typed `ErrorCode` values with `retryable` and `http_equivalent` fields so agents know exactly what to do on failure.
- **Budget guardrails:** set per-generation, daily, and monthly USD limits. Generations that would exceed a limit are rejected before the API call is made.
- **Prompt safety:** a local heuristic checker blocks or flags prompts before they reach any provider.
- **Health check:** `openflix health` returns a machine-readable report on store accessibility, downloads directory, and which providers have configured keys.

---

## Command Reference

Every command supports `--pretty` for human-readable JSON output and `--api-key` to override the key resolution chain.

### `generate`

Submit a video generation request.

| Flag / Option | Type | Description |
|---|---|---|
| `<prompt>` | argument | Text prompt describing the video |
| `--provider` | string | Provider ID (replicate, fal, runway, luma, kling, minimax) |
| `--model` | string | Model ID (see `openflix models --provider <id>`) |
| `--duration` | double | Duration in seconds (max 600, model-specific cap also applies) |
| `--aspect-ratio` | string | Aspect ratio, e.g. `16:9`, `9:16`, `1:1` |
| `--width` | int | Output width in pixels |
| `--height` | int | Output height in pixels |
| `--negative-prompt` | string | What to avoid in the video |
| `--image` | string | Reference image URL or local path (image-to-video models) |
| `--param` | string (repeatable) | Extra key=value pairs forwarded to the provider, e.g. `audio=true seed=42` |
| `--wait` | flag | Block until generation completes, then emit final JSON |
| `--stream` | flag | Emit newline-delimited JSON progress events to stdout |
| `--timeout` | double | Max seconds to wait (default: 300) |
| `--poll-interval` | double | Poll interval in seconds (default: 3) |
| `-o` / `--output` | string | Output file path for the downloaded video |
| `--api-key` | string | API key (overrides env var and Keychain) |
| `--skip-download` | flag | Do not download the video after generation completes |
| `--retry` | int | Max retries on provider failure (default: 0) |
| `--dry-run` | flag | Validate request and print cost estimate without submitting |
| `--pretty` | flag | Pretty-print JSON output |

```sh
# Submit and stream progress events
openflix generate "ocean sunrise timelapse" \
  --provider runway \
  --model gen4_turbo \
  --duration 5 \
  --aspect-ratio 16:9 \
  --stream

# Image-to-video with extra provider params
openflix generate "character walks forward" \
  --provider fal \
  --model fal-ai/kling-video/v2/master/text-to-video \
  --image ./reference.jpg \
  --param seed=42 \
  --wait \
  --output ~/Videos/shot.mp4

# Dry run to verify key and get cost estimate
openflix generate "sunset over mountains" \
  --provider luma \
  --model ray-3 \
  --duration 8 \
  --dry-run
```

### `status`

Poll the current status of a generation.

| Flag / Option | Type | Description |
|---|---|---|
| `<id>` | argument | Generation ID |
| `--wait` | flag | Block until generation completes |
| `--stream` | flag | Emit newline-delimited JSON progress events |
| `--timeout` | double | Max seconds to wait (default: 300) |
| `--poll-interval` | double | Poll interval in seconds (default: 3) |
| `-o` / `--output` | string | Output file path for the downloaded video |
| `--api-key` | string | API key override |
| `--skip-download` | flag | Do not download after completion |
| `--cached` | flag | Return cached status without hitting the provider API |
| `--pretty` | flag | Pretty-print JSON output |

### `download`

Download the video for a completed generation.

| Flag / Option | Type | Description |
|---|---|---|
| `<id>` | argument | Generation ID |
| `-o` / `--output` | string | Output file path (default: `~/.vortex/downloads/<id>.mp4`) |
| `--wait` | flag | Block until generation completes before downloading |
| `--timeout` | double | Max seconds to wait (default: 300) |
| `--poll-interval` | double | Poll interval in seconds (default: 3) |
| `--api-key` | string | API key override |
| `--pretty` | flag | Pretty-print JSON output |

### `list`

List generation history from `~/.vortex/store.json`.

| Flag / Option | Type | Description |
|---|---|---|
| `--status` | string | Filter: `queued`, `submitted`, `processing`, `succeeded`, `failed`, `cancelled` |
| `--provider` | string | Filter by provider ID |
| `--search` | string | Filter by prompt substring |
| `--limit` | int | Max results (default: 50) |
| `--oldest` | flag | Sort ascending (oldest first) |
| `--pretty` | flag | Pretty-print JSON output |

### `cancel`

Cancel a queued, submitted, or processing generation. Sends a best-effort cancel to the remote provider.

| Flag / Option | Type | Description |
|---|---|---|
| `<id>` | argument | Generation ID |
| `--api-key` | string | API key override |
| `--pretty` | flag | Pretty-print JSON output |

### `retry`

Resubmit a failed or cancelled generation with the same parameters. The original generation is kept; a new one is created with a `retried_from` field.

| Flag / Option | Type | Description |
|---|---|---|
| `<id>` | argument | Generation ID |
| `--wait` | flag | Block until the retried generation completes |
| `--stream` | flag | Stream progress events |
| `--skip-download` | flag | Do not download after completion |
| `--timeout` | double | Max seconds to wait (default: 300) |
| `--poll-interval` | double | Poll interval in seconds (default: 3) |
| `--api-key` | string | API key override |
| `--pretty` | flag | Pretty-print JSON output |

### `delete`

Remove a generation record from local history. Does not cancel remote jobs or delete downloaded files.

| Flag / Option | Type | Description |
|---|---|---|
| `<id>` | argument | Generation ID |
| `--pretty` | flag | Pretty-print JSON output |

### `purge`

Bulk-remove generations matching filter criteria. At least one of `--older-than` or `--status` is required.

| Flag / Option | Type | Description |
|---|---|---|
| `--older-than` | int | Purge generations older than N days |
| `--status` | string | Purge generations with this status |
| `--delete-files` | flag | Also delete downloaded video files from disk |
| `--pretty` | flag | Pretty-print JSON output |

```sh
openflix purge --status failed --delete-files
openflix purge --older-than 30 --status cancelled
```

### `cost`

Show actual and estimated cost summary from local history.

| Flag / Option | Type | Description |
|---|---|---|
| `--provider` | string | Filter by provider ID |
| `--since` | string | ISO 8601 date (YYYY-MM-DD) — only include generations after this date |
| `--pretty` | flag | Pretty-print JSON output |

### `keys`

Manage API keys stored in the macOS Keychain. Keys stored here are shared with the OpenFlix GUI application.

| Subcommand | Arguments | Description |
|---|---|---|
| `keys set <provider> <key>` | provider ID, key value | Store a key in the Keychain |
| `keys get <provider>` | provider ID | Retrieve a key (masked by default) |
| `keys get <provider> --reveal` | | Print the full key value |
| `keys delete <provider>` | provider ID | Remove a key from the Keychain |
| `keys list` | | List all providers and whether they have a key stored |

Key resolution order (highest priority first):

1. `--api-key` flag
2. Environment variable `VORTEX_<PROVIDER>_KEY` (e.g. `VORTEX_FAL_KEY`, `VORTEX_RUNWAY_KEY`)
3. Generic fallback `VORTEX_API_KEY`
4. macOS Keychain entry `com.openflix.vortex.<provider>`

### `models`

List models for a provider with capabilities and pricing.

| Flag / Option | Type | Description |
|---|---|---|
| `--provider` | string | Provider ID (required) |
| `--pretty` | flag | Pretty-print JSON output |

```sh
openflix models --provider fal --pretty
```

### `providers`

List all registered providers. Subcommands: `list` (default), `models`.

| Flag / Option | Type | Description |
|---|---|---|
| `--pretty` | flag | Pretty-print JSON output |

### `health`

Report system health for agent diagnostics: store writability, downloads directory, and API key configuration per provider.

| Flag / Option | Type | Description |
|---|---|---|
| `--pretty` | flag | Pretty-print JSON output |

Returns `{ "healthy": true/false, "store_writable": ..., "downloads_writable": ..., "generation_count": ..., "providers": [...], "all_providers_configured": ... }`.

### `batch`

Submit multiple generations in parallel from a JSON array.

| Flag / Option | Type | Description |
|---|---|---|
| `--file` | string | Path to JSON file (reads from stdin if omitted) |
| `--concurrency` | int | Max parallel generations (default: 4) |
| `--wait` | flag | Block until all generations complete |
| `--stream` | flag | Stream progress events |
| `--skip-download` | flag | Do not download videos after generation |
| `--timeout` | double | Max seconds per generation (default: 600) |
| `--retry` | int | Max retries per generation on failure (default: 1) |
| `--api-key` | string | API key override |
| `--pretty` | flag | Pretty-print JSON output |

Input format:

```json
[
  {"prompt": "cat on moon", "provider": "fal", "model": "fal-ai/veo3", "tag": "shot1"},
  {"prompt": "neon city rain", "provider": "runway", "model": "gen4_turbo", "tag": "shot2"}
]
```

Supported fields per item: `prompt`, `provider`, `model`, `negative_prompt`, `duration`, `aspect_ratio`, `width`, `height`, `image`, `extra_params`, `tag`.

```sh
openflix batch --file shots.json --wait --concurrency 4
cat shots.json | openflix batch --wait
```

### `evaluate`

Run quality evaluation on a downloaded video. The generation must be in `succeeded` status with a local file.

| Flag / Option | Type | Description |
|---|---|---|
| `<generation-id>` | argument | Generation ID |
| `--evaluator` | string | `heuristic` (default) or `llm-vision` |
| `--threshold` | double | Quality threshold 0-100 (default: 60) |
| `--claude-api-key` | string | Anthropic API key for `llm-vision` evaluator |
| `--claude-model` | string | Claude model to use for vision evaluation |
| `--max-frames` | int | Max frames to extract for LLM evaluation (default: 4) |
| `--pretty` | flag | Pretty-print JSON output |

### `feedback`

Record a quality score for a generation. Scores feed the provider metrics system used by the `quality` routing strategy.

| Flag / Option | Type | Description |
|---|---|---|
| `<generation-id>` | argument | Generation ID |
| `--score` | double | Quality score 0-100 (required) |
| `--reason` | string | Optional textual explanation |
| `--pretty` | flag | Pretty-print JSON output |

```sh
openflix feedback abc123 --score 85 --reason "Great motion, accurate subject"
```

### `metrics`

Show aggregated provider performance metrics.

| Flag / Option | Type | Description |
|---|---|---|
| `--provider` | string | Filter by provider ID |
| `--sort` | string | `quality` (default), `latency`, `cost`, `success_rate` |
| `--pretty` | flag | Pretty-print JSON output |

### `budget`

Manage cost limits for autonomous agent use. Subcommands: `status` (default), `set`, `reset`.

**`budget status`**

| Flag / Option | Type | Description |
|---|---|---|
| `--pretty` | flag | Pretty-print JSON output |

**`budget set`**

| Flag / Option | Type | Description |
|---|---|---|
| `--daily-limit` | double | Daily spend limit in USD |
| `--per-generation-max` | double | Max cost per individual generation in USD |
| `--monthly-limit` | double | Monthly spend limit in USD |
| `--warning-threshold` | double | Warning threshold percentage (0-100, default: 80) |
| `--pretty` | flag | Pretty-print JSON output |

**`budget reset`**

Resets the daily spend counter to zero.

```sh
openflix budget set --daily-limit 5.00 --per-generation-max 1.00
openflix budget status --pretty
openflix budget reset
```

### `project`

Manage multi-shot video generation projects. Subcommands: `create`, `run`, `status`, `list`, `delete`, `shot`, `export`.

**`project create`**

| Flag / Option | Type | Description |
|---|---|---|
| `--file` | string | JSON spec file path (reads from stdin if omitted) |
| `--pretty` | flag | Pretty-print JSON output |

**`project run`**

| Flag / Option | Type | Description |
|---|---|---|
| `<project-id>` | argument | Project ID |
| `--concurrency` | int | Max parallel shots (default: project setting, typically 4) |
| `--stream` | flag | Stream newline-delimited JSON progress events |
| `--resume` | flag | Reset stale dispatched/processing/failed shots to pending before running |
| `--skip-download` | flag | Do not download videos after generation |
| `--api-key` | string | API key override |
| `--evaluate` | flag | Enable quality evaluation after each generation |
| `--quality-threshold` | double | Quality threshold 0-100 (implies `--evaluate`) |
| `--evaluator` | string | Evaluator type: `heuristic` or `llm-vision` |
| `--pretty` | flag | Pretty-print JSON output |

**`project status`**

| Flag / Option | Type | Description |
|---|---|---|
| `<project-id>` | argument | Project ID |
| `--detail` | flag | Include per-shot status in output |
| `--pretty` | flag | Pretty-print JSON output |

**`project list`**

| Flag / Option | Type | Description |
|---|---|---|
| `--status` | string | Filter by status: `draft`, `running`, `paused`, `succeeded`, `partialFailure`, `failed`, `cancelled` |
| `--pretty` | flag | Pretty-print JSON output |

**`project delete`**

| Flag / Option | Type | Description |
|---|---|---|
| `<project-id>` | argument | Project ID |
| `--delete-generations` | flag | Also remove associated generations from the generation store |
| `--pretty` | flag | Pretty-print JSON output |

**`project shot`**

Manage individual shots within a project. Subcommands: `add`, `retry`, `skip`, `update`, `remove`.

| Subcommand | Key Options | Description |
|---|---|---|
| `shot add <project-id> <scene-id>` | `--name`, `--prompt`, `--provider`, `--model`, `--duration`, `--aspect-ratio`, `--dependencies` (comma-separated IDs) | Add a shot to a scene |
| `shot retry <project-id> <shot-id>` | | Reset a failed/cancelled shot to pending |
| `shot skip <project-id> <shot-id>` | | Mark a shot as skipped |
| `shot update <project-id> <shot-id>` | `--prompt`, `--provider`, `--model`, `--generation-id`, `--status` | Update shot properties |
| `shot remove <project-id> <shot-id>` | | Remove a shot from the project |

**`project export`**

| Flag / Option | Type | Description |
|---|---|---|
| `<project-id>` | argument | Project ID |
| `--output` | string | Output directory for manifest files |
| `--manifest` | flag | Generate an ffmpeg concat demuxer file |
| `--pretty` | flag | Pretty-print JSON output |

```sh
openflix project export <project-id> --manifest --output ./export
# Then stitch the clips together:
ffmpeg -f concat -safe 0 -i ./export/concat.txt -c copy final.mp4
```

### `daemon`

Manage the background daemon that exposes a Unix socket for persistent agent connections. Subcommands: `start`, `stop`, `status`.

| Subcommand | Options | Description |
|---|---|---|
| `daemon start` | `--foreground` | Start the daemon |
| `daemon stop` | | Send SIGTERM and clean up socket/PID files |
| `daemon status` | | Report whether the daemon is running and its PID |

For background operation:

```sh
nohup openflix daemon start --foreground &
openflix daemon status
openflix daemon stop
```

Socket: `~/.vortex/daemon.sock` — PID file: `~/.vortex/daemon.pid`

### `mcp`

Start OpenFlix as an MCP server communicating via stdin/stdout using JSON-RPC 2.0. No flags. See [MCP Server](#mcp-server).

```sh
openflix mcp
```

---

## Providers and Models

API keys are resolved from `--api-key` flag > environment variable > Keychain. The environment variable name is `VORTEX_<PROVIDER>_KEY` (e.g. `VORTEX_FAL_KEY`, `VORTEX_RUNWAY_KEY`).

### fal.ai (`fal`)

| Model ID | Display Name | Default Resolution | Max Duration | Cost/s | I2V |
|---|---|---|---|---|---|
| `fal-ai/veo3` | Veo 3 | 1280x720 | 8s | $0.15 | no |
| `fal-ai/bytedance/seedance/v2/text-to-video` | Seedance 2.0 | 1920x1080 | 15s | $0.05 | no |
| `fal-ai/bytedance/seedance/v2/image-to-video` | Seedance 2.0 I2V | 1920x1080 | 15s | $0.06 | yes |
| `fal-ai/kling-video/v2/master/text-to-video` | Kling v2 Master | 1280x720 | 10s | $0.06 | yes |
| `fal-ai/minimax/hailuo-02` | Hailuo 02 | 1280x720 | 6s | $0.05 | no |
| `fal-ai/luma-dream-machine` | Luma Dream Machine | 1280x720 | 5s | $0.08 | no |
| `fal-ai/hunyuan-video` | Hunyuan Video | 1280x720 | 5s | $0.04 | no |
| `fal-ai/wan/v2.1/1080p` | Wan 2.1 1080p | 1920x1080 | 5s | $0.03 | no |

### Replicate (`replicate`)

| Model ID | Display Name | Default Resolution | Max Duration | Cost/s | I2V |
|---|---|---|---|---|---|
| `minimax/video-01-live` | MiniMax Video-01 Live | 1280x720 | 6s | $0.05 | no |
| `tencent/hunyuan-video` | Hunyuan Video | 1280x720 | 5s | $0.04 | no |
| `wavespeed-ai/wan-2.1` | Wan 2.1 | 1280x720 | 5s | $0.03 | no |
| `kwaai/kling-v1.6-pro` | Kling v1.6 Pro | 1280x720 | 10s | $0.10 | yes |

### Runway (`runway`)

| Model ID | Display Name | Default Resolution | Max Duration | Cost/s | I2V |
|---|---|---|---|---|---|
| `gen4_turbo` | Gen-4 Turbo | 1280x720 | 10s | $0.05 | yes |
| `gen4.5` | Gen-4.5 | 1280x720 | 10s | $0.10 | yes |

### Luma (`luma`)

| Model ID | Display Name | Default Resolution | Max Duration | Cost/s | I2V |
|---|---|---|---|---|---|
| `ray-2` | Ray 2 | 1280x720 | 5s | $0.10 | yes |
| `ray-flash-2` | Ray Flash 2 | 1280x720 | 5s | $0.05 | yes |
| `ray-3` | Ray 3 | 1280x720 | 10s | $0.20 | yes |

### Kling (`kling`)

| Model ID | Display Name | Default Resolution | Max Duration | Cost/s | I2V |
|---|---|---|---|---|---|
| `kling-v2.6-pro` | Kling v2.6 Pro | 1280x720 | 10s | $0.10 | yes |
| `kling-v2.6-std` | Kling v2.6 Standard | 1280x720 | 10s | $0.05 | yes |
| `kling-v2.5-turbo` | Kling v2.5 Turbo | 1280x720 | 5s | $0.03 | yes |

### MiniMax (`minimax`)

| Model ID | Display Name | Default Resolution | Max Duration | Cost/s | I2V |
|---|---|---|---|---|---|
| `MiniMax-Hailuo-2.3` | Hailuo 2.3 | 1280x720 | 10s | $0.05 | no |
| `T2V-01-Director` | T2V-01 Director | 1280x720 | 6s | $0.04 | no |
| `S2V-01` | S2V-01 (I2V) | 1280x720 | 6s | $0.05 | yes |

I2V = image-to-video support. Cost figures are estimates used for budget pre-flight checks and local cost tracking; actual provider billing may differ.

---

## Budget and Safety

### Budget Guardrails

`BudgetManager` is a Swift actor that enforces cost limits before any API call is made. Limits are stored at `~/.vortex/budget_config.json` and daily spend at `~/.vortex/daily_spend.json`.

Three limit tiers:

- **Per-generation max:** if the estimated cost of a single request exceeds this value, the generation is rejected immediately with a `budget_exceeded` error.
- **Daily limit:** if adding the estimated cost to today's recorded spend would exceed this value, the generation is rejected.
- **Monthly limit:** same logic applied to the accumulated monthly spend.

A warning is emitted (but the generation proceeds) when projected daily spend exceeds `warning_threshold_percent` of the daily limit (default: 80%).

When a generation completes successfully, its actual cost is recorded to the daily spend counter.

```sh
openflix budget set --daily-limit 10.00 --per-generation-max 2.00 --warning-threshold 75
openflix budget status --pretty
```

### Prompt Safety

`PromptSafetyChecker` runs locally before every generation — no API call required. It classifies prompts into three levels:

| Level | Action | Categories |
|---|---|---|
| `blocked` | Generation rejected, `promptBlocked` error returned | `csam`, `extreme_violence`, `pii_generation`, `malware` |
| `warning` | Generation proceeds, flags noted | `violence`, `suggestive`, `deceptive` |
| `safe` | No action | — |

The check runs inside `GenerationEngine.submit()` before the budget check and before any network call.

---

## MCP Server

OpenFlix implements the [Model Context Protocol](https://modelcontextprotocol.io) over stdio, making it usable as a native tool server for Claude Code, Claude Desktop, and any MCP-compatible host.

### Configuration

Add to `~/.claude.json` or `claude_desktop_config.json`:

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

### Tools (14)

| Tool | Required Parameters | Description |
|---|---|---|
| `generate` | `prompt`, `provider`, `model` | Submit, poll until complete, and download. Optional: `negative_prompt`, `width`, `height`, `duration_seconds`, `aspect_ratio`, `timeout`, `max_retries`. |
| `generate_submit` | `prompt`, `provider`, `model` | Submit only, non-blocking. Returns generation ID for later polling. Optional: same generation fields minus `timeout`/`max_retries`. |
| `generate_poll` | `generation_id` | Poll status of an existing generation. Optional: `wait` (bool), `timeout`. |
| `list_generations` | — | List generations. Optional: `status`, `provider`, `limit` (default 20), `search`. |
| `get_generation` | `generation_id` | Get full details for one generation. |
| `cancel_generation` | `generation_id` | Cancel an active generation. |
| `retry_generation` | `generation_id` | Retry a failed generation with the same parameters. |
| `list_providers` | — | List all providers and models with capabilities and pricing. |
| `evaluate_quality` | `generation_id` | Run quality evaluation. Optional: `evaluator` (`heuristic`/`llm-vision`), `threshold`. |
| `submit_feedback` | `generation_id`, `score` | Record quality feedback (0-100). Optional: `reason`. |
| `get_metrics` | — | Get provider metrics. Optional: `provider`, `sort` (`quality`/`latency`/`cost`/`success_rate`). |
| `budget_status` | — | Get current budget status: daily spend, limits, remaining. |
| `project_run` | `project_id` | Execute a multi-shot project DAG. Optional: `strategy`, `evaluate`. |
| `health_check` | — | Check which providers have configured keys. |

### Resources (3)

| URI | MIME Type | Description |
|---|---|---|
| `vortex://providers` | `application/json` | All providers and models with capabilities and cost-per-second |
| `vortex://metrics` | `application/json` | Current provider performance metrics |
| `vortex://budget` | `application/json` | Current budget status and daily spend |

### Protocol details

- Transport: JSON-RPC 2.0 over stdin/stdout
- Protocol version: `2024-11-05`
- Errors from tool calls are returned as `content` with `"isError": true` containing a `StructuredError` JSON object (not as JSON-RPC error responses), so agents can inspect the `code` and `retryable` fields without special error handling.

---

## Daemon and Project Orchestration

### Daemon

The daemon (`openflix daemon start --foreground`) binds a Unix domain socket at `~/.vortex/daemon.sock` and accepts JSON-RPC 2.0 messages. It is intended for agents that need a persistent connection rather than spawning a new process per command.

### Projects

A project is a directed acyclic graph (DAG) of shots organized into scenes. Shots declare dependencies on other shots by shot ID; the executor does not dispatch a shot until all its dependencies have succeeded or been skipped.

#### Project spec format

```json
{
  "name": "My Short Film",
  "description": "Optional description",
  "settings": {
    "default_provider": "fal",
    "default_model": "fal-ai/veo3",
    "default_aspect_ratio": "16:9",
    "default_duration": 5,
    "max_concurrency": 4,
    "max_retries_per_shot": 2,
    "timeout_per_shot": 600,
    "routing_strategy": "cheapest",
    "cost_budget_usd": 20.00,
    "quality_enabled": true,
    "quality_evaluator": "heuristic",
    "quality_threshold": 70,
    "quality_max_retries": 1
  },
  "scenes": [
    {
      "name": "Opening",
      "order_index": 0,
      "shots": [
        {
          "name": "establishing_shot",
          "prompt": "wide angle view of a city at dawn",
          "duration": 5,
          "dependencies": []
        },
        {
          "name": "close_up",
          "prompt": "close up of a coffee cup steaming",
          "duration": 3,
          "dependencies": ["establishing_shot"]
        }
      ]
    }
  ]
}
```

#### Routing strategies

The `routing_strategy` field controls how the executor selects a provider and model for shots that do not specify them explicitly:

| Strategy | Behavior |
|---|---|
| `manual` | Each shot must have `provider` and `model` set explicitly. |
| `cheapest` | Selects the model with the lowest `cost_per_second_usd` that meets the shot's duration and image requirements. |
| `fastest` | Heuristic: selects the model with the shortest `max_duration_seconds`. |
| `quality` | Uses recorded metrics (`openflix metrics`) to pick the highest average quality score; falls back to highest cost as a proxy when no metrics exist. |
| `scatterGather` | Dispatches the shot to N providers simultaneously (controlled by `scatter_count`), then picks the first successful result. With `--evaluate`, picks the highest-quality result. |

#### Quality gate

When `quality_enabled: true` (or `--evaluate` is passed to `project run`), each shot transitions to an `evaluating` state after its generation succeeds. The evaluator scores the video on a 0-100 scale. If the score falls below the threshold and retry budget remains, the shot is reset to `pending` for re-dispatch. If the evaluator itself fails (e.g. ffprobe not available), the shot is accepted — evaluation is advisory, never blocking.

Two evaluators are available:

**`heuristic`** — local, no API calls. Scores on:
- File exists and is non-empty (20 pts)
- File size between 50 KB and 2 GB (20 pts)
- Valid video file extension (10 pts)
- ffprobe: duration within ±20% of expected (10 pts), resolution ≥ 720p (10 pts), video codec present (10 pts)
- Generation succeeded without errors (20 pts)

Degrades gracefully with partial credit when ffprobe is not installed.

**`llm-vision`** — extracts up to N frames from the video and sends them to the Claude API alongside the original prompt for contextual scoring. Requires `--claude-api-key`.

#### Project lifecycle

```sh
# Create from spec
openflix project create --file spec.json

# Run with streaming and quality evaluation
openflix project run <project-id> --stream --evaluate --quality-threshold 70

# Check detailed per-shot progress
openflix project status <project-id> --detail --pretty

# Resume after interruption (resets stale dispatched shots and failed shots to pending)
openflix project run <project-id> --resume

# Export for video editing
openflix project export <project-id> --manifest --output ./export
ffmpeg -f concat -safe 0 -i ./export/concat.txt -c copy final.mp4
```

---

## Architecture

```
openflix
├── VortexCLI.swift              @main entry point
├── Commands/                    One file per command (ArgumentParser subcommands)
├── Providers/                   One file per provider
│   ├── ProviderProtocol.swift   VideoProvider protocol + ProviderRegistry
│   ├── FalClient.swift
│   ├── ReplicateClient.swift
│   ├── RunwayClient.swift
│   ├── LumaClient.swift
│   ├── KlingClient.swift
│   └── MiniMaxClient.swift
├── Core/
│   ├── Models.swift             CLIGeneration, CLIProviderModel, VortexError, ErrorCode, StructuredError
│   ├── GenerationEngine.swift   submit(), submitAndWait(), waitForCompletion() — poll loop with retry/backoff
│   ├── GenerationStore.swift    ~/.vortex/store.json — flock + NSLock for thread/process safety
│   ├── VideoDownloader.swift    URLSession download to ~/.vortex/downloads/<id>.mp4
│   ├── CLIKeychain.swift        Keychain read/write, three-tier key resolution
│   ├── ProviderRouter.swift     5 routing strategies, scatter targets selection
│   ├── DAGExecutor.swift        Actor — Kahn's topological sort + TaskGroup parallel dispatch
│   ├── ScatterGather.swift      Multi-provider parallel dispatch, best-result selection
│   ├── ProjectModels.swift      Project, Scene, Shot, ProjectSpec data structures
│   ├── ProjectStore.swift       ~/.vortex/projects/<id>/project.json — per-project flock
│   ├── EvaluatorProtocol.swift  VideoEvaluator protocol, EvaluationResult, QualityConfig
│   ├── HeuristicEvaluator.swift File + ffprobe based scoring
│   ├── LLMVisionEvaluator.swift Claude API vision scoring
│   ├── QualityGate.swift        evaluate() + check() orchestration (advisory, never blocking)
│   ├── ProviderMetricsStore.swift ~/.vortex/metrics.json — running averages per provider+model
│   ├── BudgetManager.swift      Actor — daily/per-gen/monthly limits, spend tracking
│   ├── PromptSafetyChecker.swift Local heuristic — blocked/warning/safe classification
│   ├── MCPServer.swift          JSON-RPC 2.0 over stdio, tool dispatch
│   ├── MCPToolRegistry.swift    Tool and resource definitions
│   ├── MCPProtocol.swift        MCPRequest, MCPResponse, AnyCodableValue types
│   ├── DaemonServer.swift       Unix socket server (NWListener)
│   ├── DaemonSession.swift      Per-connection session handler
│   └── DaemonProtocol.swift     JSON-RPC daemon message types
└── Output/
    └── Output.swift             emitDict, emitArray, emitEvent, fail, failMessage, failStructured
```

### Data flow — single generation

1. `GenerationEngine.submit()` calls `PromptSafetyChecker.check()`. Blocked prompts throw `VortexError.promptBlocked` immediately.
2. If a cost estimate is computable, `BudgetManager.preFlightCheck()` is called. Denied requests throw `VortexError.budgetExceeded`.
3. The provider's `submit(request:apiKey:)` is called over HTTPS. The remote task ID and status URL are persisted to `GenerationStore`.
4. `waitForCompletion()` polls `provider.poll()` on a configurable interval. Transient errors (URLError, rate limits) trigger up to 3 automatic poll retries with linear backoff. Submission failures retry with exponential backoff up to `maxRetries`.
5. On success, `BudgetManager.recordSpend()` is called. The video is downloaded to `~/.vortex/downloads/<id>.mp4` (or a custom path). Download failures are recorded as warnings — the generation status remains `succeeded` and the download is retriable via `openflix download`.
6. All stdout output is JSON. All stderr output is JSON with an `error` and `code` field.

### Store files

| Path | Purpose |
|---|---|
| `~/.vortex/store.json` | All generation records, JSON, flock-protected |
| `~/.vortex/projects/<id>/project.json` | Per-project state with scenes and shots |
| `~/.vortex/metrics.json` | Provider quality/latency/cost/success running averages |
| `~/.vortex/budget_config.json` | Budget limit configuration |
| `~/.vortex/daily_spend.json` | Current day's recorded spend |
| `~/.vortex/downloads/` | Default download directory |
| `~/.vortex/daemon.sock` | Daemon Unix socket |
| `~/.vortex/daemon.pid` | Daemon process ID |

---

## Error Codes

All errors emitted to stderr carry a `code` field. For MCP responses and `failStructured` calls, the `ErrorCode` enum provides structured values with `retryable` and `http_equivalent` metadata.

| ErrorCode | Retryable | HTTP Equivalent | Meaning |
|---|---|---|---|
| `AUTH_MISSING` | no | 401 | No API key found for the provider |
| `AUTH_INVALID` | no | 401 | API key rejected by the provider |
| `AUTH_EXPIRED` | no | 401 | API key has expired |
| `PROVIDER_UNAVAILABLE` | no | 503 | Provider ID not registered |
| `PROVIDER_RATE_LIMITED` | yes | 429 | Provider returned 429; retry after `retry_after_seconds` if set |
| `PROVIDER_TIMEOUT` | yes | 504 | Poll loop timed out before generation completed |
| `PROVIDER_SERVER_ERROR` | yes | 502 | Provider returned 5xx |
| `INPUT_INVALID` | no | 400 | Invalid input parameter |
| `INPUT_TOO_LARGE` | no | 400 | Input exceeds provider limits |
| `PROMPT_UNSAFE` | no | 400 | Prompt blocked by safety checker |
| `BUDGET_EXCEEDED` | no | 402 | Generation would exceed a configured budget limit |
| `QUOTA_EXCEEDED` | no | 402 | Provider quota exhausted |
| `DISK_FULL` | no | 500 | Local disk full during download |
| `GENERATION_FAILED` | no | 500 | Provider reported generation failure |
| `GENERATION_NOT_FOUND` | no | 404 | Generation ID not in local store |
| `QUALITY_BELOW_THRESHOLD` | no | 500 | Video did not pass quality gate (advisory) |
| `DOWNLOAD_FAILED` | yes | 500 | Network error during video download |
| `INTERNAL_ERROR` | no | 500 | Unexpected internal error |
| `CONFIG_INVALID` | no | 400 | Invalid configuration |
| `NOT_COMPLETE` | yes | 404 | Generation exists but is not yet complete |

CLI error response shape (non-MCP):

```json
{"error": "No API key for 'fal'. Use: openflix keys set fal <key>", "code": "no_api_key"}
```

Process exit code is `1` on all errors.

---

## Contributing

### Development setup

```sh
git clone https://github.com/moiz-7/OpenFlix.git
cd OpenFlix
swift build
.build/debug/openflix --help
```

### Running tests

```sh
bash test.sh
```

The test script runs both build verification and runtime tests against the debug binary. All tests must pass before merging.

New features require:

1. New tests in `test.sh` covering the happy path and at least one error case.
2. Both debug and release builds verified (`swift build -c release`).
3. Runtime tests where applicable, not just `--help` output checks.

### Code conventions

- All stdout output via `Output.emitDict` / `Output.emitArray` / `Output.emitEvent`. No `print()` calls in command or core code.
- All errors via `Output.fail` or `Output.failMessage` — both are `-> Never`.
- Flags declared with `@Flag(name: .long)`, options with `@Option(name: .long)`.
- New providers: implement `VideoProvider`, add to `ProviderRegistry.init()`.
- New MCP tools: add a `MCPToolDefinition` to `MCPToolRegistry.allTools` and a `case` in `MCPServer.dispatchTool()`.
- Keychain service prefix is `com.openflix.vortex.<provider>` — shared with the companion GUI app. Do not change.
- `GenerationStore` API: use `get(_:)` not `load()`, `all()` not `loadAll()`.
- GRDB/store insert pattern: use `var` not `let` for mutable model structs.

---

## License

Source available for reference and personal, non-commercial use only. You may not copy, modify, distribute, sublicense, or use this software in a commercial product without prior written permission from Bubble Research. See [LICENSE](LICENSE).
