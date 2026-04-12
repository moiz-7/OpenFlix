# OpenFlix

**AI video generation from your terminal.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](https://developer.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9%2B-orange)](https://swift.org)

OpenFlix is a command-line tool for generating AI videos across multiple providers. Bring your own API keys, submit generations, poll for results, download videos, and orchestrate multi-shot projects — all from a single binary. Every command outputs structured JSON to stdout, making it native to scripting, pipelines, and AI agents.

```
openflix generate "a cat floating through space" \
    --provider fal --model fal-ai/veo3 --wait
```

---

## Table of Contents

1. [Install](#install)
2. [Quick Start](#quick-start)
3. [Why OpenFlix?](#why-openflix)
4. [Command Reference](#command-reference)
5. [Providers & Models](#providers--models)
6. [Budget & Safety](#budget--safety)
7. [MCP Server](#mcp-server)
8. [Daemon](#daemon)
9. [Projects](#projects)
10. [Architecture](#architecture)
11. [Exit Codes](#exit-codes)
12. [Contributing](#contributing)
13. [License](#license)

---

## Install

### Homebrew

```sh
brew install openflix
```

### Build from source

Requires macOS 14 (Sonoma)+, Xcode 15+ or Swift 5.9+.

```sh
git clone https://github.com/openflix/openflix.git
cd openflix/VortexCLI
swift build -c release
cp .build/release/openflix /usr/local/bin/openflix
```

---

## Quick Start

```sh
# 1. Store your API key in the macOS Keychain
openflix keys set fal YOUR_FAL_KEY

# 2. Generate a video and wait for the result
openflix generate "neon city timelapse at sunset" \
    --provider fal --model fal-ai/minimax/hailuo-02 --wait

# 3. List your generations
openflix list --status succeeded --limit 5
```

All output is newline-terminated JSON. Pipe into `jq`, store in a file, or feed to another program.

---

## Why OpenFlix?

### For humans

- **One tool, six providers.** Switch between fal.ai, Replicate, Runway, Luma, Kling, and MiniMax without learning six different APIs.
- **Keys stay in your Keychain.** API keys are stored in macOS Keychain, not dotfiles. Environment variables work too.
- **Cost visibility.** Per-generation cost estimates, daily/monthly budgets, and spend summaries before you get a surprise bill.
- **Streaming progress.** Pass `--stream` to receive newline-delimited JSON events as a generation moves from queued to processing to complete.
- **Project orchestration.** Define multi-shot video projects as JSON, execute them as a dependency DAG with parallel workers, export an ffmpeg concat manifest.

### For AI agents

- **JSON-first.** Every command writes structured JSON to stdout. Errors go to stderr with machine-readable codes. No tables to parse.
- **MCP native.** Run `openflix mcp` to expose 14 tools and 3 resources over Model Context Protocol. Claude Code, Cursor, and any MCP client can generate videos as a tool call.
- **Deterministic exit codes.** `0` for success, `1` for all errors. Structured error payloads include `code`, `retryable`, and `retry_after_seconds`.
- **Budget guardrails.** Daily, monthly, and per-generation cost limits prevent runaway autonomous spending.
- **Prompt safety.** Local heuristic checker blocks dangerous prompts before any API call is made.

---

## Command Reference

### Generation

| Command | Description |
|---------|-------------|
| [`generate`](#generate) | Generate a video |
| [`status`](#status) | Check generation status |
| [`list`](#list) | List generation history |
| [`download`](#download) | Download a completed video |
| [`cancel`](#cancel) | Cancel a running generation |
| [`retry`](#retry) | Retry a failed generation |
| [`delete`](#delete) | Remove from local history |
| [`purge`](#purge) | Bulk-remove old generations |
| [`batch`](#batch) | Submit multiple generations in parallel |

### Providers & Keys

| Command | Description |
|---------|-------------|
| [`providers`](#providers) | List available providers |
| [`models`](#models) | List models for a provider |
| [`keys set`](#keys) | Store API key in Keychain |
| [`keys get`](#keys) | Retrieve API key |
| [`keys delete`](#keys) | Remove API key |
| [`keys list`](#keys) | Show which providers have keys |
| [`health`](#health) | System diagnostics |

### Cost & Quality

| Command | Description |
|---------|-------------|
| [`cost`](#cost) | Spend summary |
| [`budget status`](#budget) | Current budget and limits |
| [`budget set`](#budget) | Configure budget limits |
| [`budget reset`](#budget) | Reset daily spend counter |
| [`evaluate`](#evaluate) | Evaluate video quality |
| [`feedback`](#feedback) | Record quality score |
| [`metrics`](#metrics) | Provider performance metrics |

### Projects

| Command | Description |
|---------|-------------|
| [`project create`](#project) | Create from JSON spec |
| [`project run`](#project-run) | Execute project DAG |
| [`project status`](#project-status) | Show progress |
| [`project list`](#project-list) | List all projects |
| [`project delete`](#project-delete) | Delete project |
| [`project export`](#project-export) | Export output manifest |
| [`project shot`](#project-shot) | Manage individual shots |

### Infrastructure

| Command | Description |
|---------|-------------|
| [`mcp`](#mcp-server) | Run as MCP server (stdio) |
| [`daemon start`](#daemon) | Start Unix socket daemon |
| [`daemon stop`](#daemon) | Stop daemon |
| [`daemon status`](#daemon) | Check daemon status |

---

### `generate`

Submit a video generation request.

```sh
openflix generate "ocean sunrise timelapse" \
    --provider runway --model gen4_turbo \
    --duration 5 --aspect-ratio 16:9 --stream
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<prompt>` | String | required | Text prompt describing the video |
| `--provider` | String | required | Provider ID (`fal`, `replicate`, `runway`, `luma`, `kling`, `minimax`) |
| `--model` | String | required | Model ID (run `openflix models --provider <id>` to list) |
| `--duration` | Double | — | Duration in seconds (max 600, model cap also applies) |
| `--aspect-ratio` | String | — | e.g. `16:9`, `9:16`, `1:1` |
| `--width` | Int | — | Output width in pixels |
| `--height` | Int | — | Output height in pixels |
| `--negative-prompt` | String | — | What to avoid |
| `--image` | String | — | Reference image URL or local path (image-to-video models) |
| `--param` | String[] | `[]` | Extra params as `key=value` (e.g. `audio=true seed=42`) |
| `-o, --output` | String | — | Output file path |
| `--api-key` | String | — | Override API key |
| `--timeout` | Double | `300` | Max wait in seconds |
| `--poll-interval` | Double | `3` | Poll frequency in seconds |
| `--wait` | Flag | — | Block until complete |
| `--stream` | Flag | — | Stream NDJSON progress events |
| `--skip-download` | Flag | — | Skip auto-download on completion |
| `--retry` | Int | `0` | Max retries on failure |
| `--dry-run` | Flag | — | Validate without submitting |
| `--pretty` | Flag | — | Pretty-print JSON |

```sh
# Image-to-video with extra provider params
openflix generate "character walks forward" \
    --provider fal \
    --model fal-ai/kling-video/v2/master/text-to-video \
    --image ./reference.jpg \
    --param seed=42 \
    --wait -o ~/Videos/shot.mp4

# Dry run to verify key and get cost estimate
openflix generate "sunset over mountains" \
    --provider luma --model ray-3 --duration 8 --dry-run
```

### `status`

Poll the current status of a generation.

```sh
openflix status abc123 --wait --stream
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<id>` | String | required | Generation ID |
| `--wait` | Flag | — | Block until complete |
| `--stream` | Flag | — | Stream progress events |
| `--cached` | Flag | — | Return local cache without polling |
| `-o, --output` | String | — | Output file path |
| `--skip-download` | Flag | — | Skip auto-download |
| `--api-key` | String | — | Override API key |
| `--timeout` | Double | `300` | Max wait in seconds |
| `--poll-interval` | Double | `3` | Poll frequency |
| `--pretty` | Flag | — | Pretty-print JSON |

### `list`

```sh
openflix list --status succeeded --provider fal --limit 10
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--status` | String | — | Filter: `queued`, `submitted`, `processing`, `succeeded`, `failed`, `cancelled` |
| `--provider` | String | — | Filter by provider ID |
| `--search` | String | — | Filter by prompt substring |
| `--limit` | Int | `50` | Max results |
| `--oldest` | Flag | — | Sort oldest first |
| `--pretty` | Flag | — | Pretty-print JSON |

### `download`

Download the video for a completed generation.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<id>` | String | required | Generation ID |
| `-o, --output` | String | `~/.vortex/downloads/<id>.mp4` | Output file path |
| `--wait` | Flag | — | Block until generation completes before downloading |
| `--api-key` | String | — | Override API key |
| `--timeout` | Double | `300` | Max wait in seconds |
| `--poll-interval` | Double | `3` | Poll frequency |
| `--pretty` | Flag | — | Pretty-print JSON |

### `cancel`

Cancel a queued, submitted, or processing generation. Best-effort remote cancel.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<id>` | String | required | Generation ID |
| `--api-key` | String | — | Override API key |
| `--pretty` | Flag | — | Pretty-print JSON |

### `retry`

Resubmit a failed or cancelled generation with the same parameters. The original is kept; a new generation is created with a `retried_from` field.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<id>` | String | required | Generation ID |
| `--wait` | Flag | — | Block until retried generation completes |
| `--stream` | Flag | — | Stream progress events |
| `--skip-download` | Flag | — | Skip auto-download |
| `--api-key` | String | — | Override API key |
| `--timeout` | Double | `300` | Max wait in seconds |
| `--poll-interval` | Double | `3` | Poll frequency |
| `--pretty` | Flag | — | Pretty-print JSON |

### `delete`

Remove a generation record from local history. Does not cancel remote jobs or delete downloaded files.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<id>` | String | required | Generation ID |
| `--pretty` | Flag | — | Pretty-print JSON |

### `purge`

Bulk-remove generations. At least one of `--older-than` or `--status` is required.

```sh
openflix purge --status failed --delete-files
openflix purge --older-than 30 --status cancelled
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--older-than` | Int | — | Purge generations older than N days |
| `--status` | String | — | Purge generations with this status |
| `--delete-files` | Flag | — | Also delete downloaded video files |
| `--pretty` | Flag | — | Pretty-print JSON |

### `batch`

Submit multiple generations in parallel from a JSON file or stdin.

```sh
openflix batch --file shots.json --wait --concurrency 4
cat shots.json | openflix batch --wait
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--file` | String | stdin | JSON file path |
| `--concurrency` | Int | `4` | Max parallel generations |
| `--wait` | Flag | — | Block until all complete |
| `--stream` | Flag | — | Stream progress events |
| `--retry` | Int | `1` | Max retries per generation |
| `--skip-download` | Flag | — | Skip auto-download |
| `--api-key` | String | — | Override API key |
| `--timeout` | Double | `600` | Max wait per generation |
| `--pretty` | Flag | — | Pretty-print JSON |

Input format:

```json
[
  {"prompt": "cat on moon", "provider": "fal", "model": "fal-ai/veo3", "tag": "shot1"},
  {"prompt": "neon city rain", "provider": "runway", "model": "gen4_turbo", "duration": 10, "tag": "shot2"}
]
```

Supported fields: `prompt`, `provider`, `model`, `negative_prompt`, `duration`, `aspect_ratio`, `width`, `height`, `image`, `extra_params`, `tag`.

### `cost`

```sh
openflix cost --provider fal --since 2025-01-01
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--provider` | String | — | Filter by provider |
| `--since` | String | — | ISO 8601 date (`YYYY-MM-DD`) |
| `--pretty` | Flag | — | Pretty-print JSON |

### `keys`

Manage API keys in the macOS Keychain. Keys are shared with the OpenFlix GUI app under service prefix `com.openflix.vortex.*`.

```sh
openflix keys set fal YOUR_KEY       # Store
openflix keys get fal                # Retrieve (masked)
openflix keys get fal --reveal       # Retrieve (full value)
openflix keys delete fal             # Remove
openflix keys list                   # Show all providers
```

**Key resolution order** (highest priority first):

1. `--api-key` flag
2. Environment variable `VORTEX_{PROVIDER}_KEY` (e.g. `VORTEX_FAL_KEY`)
3. Generic fallback `VORTEX_API_KEY`
4. macOS Keychain (`com.openflix.vortex.{provider}`)

### `models`

```sh
openflix models --provider fal --pretty
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--provider` | String | required | Provider ID |
| `--pretty` | Flag | — | Pretty-print JSON |

### `providers`

List all registered providers with model counts.

### `health`

System diagnostics: store writability, downloads directory, API key configuration per provider.

```sh
openflix health --pretty
```

### `evaluate`

Run quality evaluation on a completed generation's video file.

```sh
# Heuristic (file size, resolution, codec — no API calls)
openflix evaluate abc123

# LLM vision (Claude analyzes extracted frames)
openflix evaluate abc123 --evaluator llm-vision --claude-api-key sk-...
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<generation-id>` | String | required | Generation ID |
| `--evaluator` | String | `heuristic` | `heuristic` or `llm-vision` |
| `--threshold` | Double | `60` | Quality threshold (0-100) |
| `--claude-api-key` | String | — | API key for `llm-vision` evaluator |
| `--claude-model` | String | `claude-sonnet-4-20250514` | Claude model |
| `--max-frames` | Int | `4` | Frames to extract for vision eval |
| `--pretty` | Flag | — | Pretty-print JSON |

### `feedback`

Record a quality score for a generation. Feeds the provider metrics system used by the `quality` routing strategy.

```sh
openflix feedback abc123 --score 85 --reason "Great motion, accurate subject"
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<generation-id>` | String | required | Generation ID |
| `--score` | Double | required | Quality score (0-100) |
| `--reason` | String | — | Optional explanation |
| `--pretty` | Flag | — | Pretty-print JSON |

### `metrics`

```sh
openflix metrics --provider fal --sort quality --pretty
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--provider` | String | — | Filter by provider |
| `--sort` | String | `quality` | Sort by: `quality`, `latency`, `cost`, `success_rate` |
| `--pretty` | Flag | — | Pretty-print JSON |

### `budget`

Manage cost limits. Subcommands: `status` (default), `set`, `reset`.

```sh
openflix budget set --daily-limit 10 --per-generation-max 2 --monthly-limit 100
openflix budget status --pretty
openflix budget reset
```

**`budget set`** options:

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--daily-limit` | Double | — | Daily spend limit in USD |
| `--per-generation-max` | Double | — | Max cost per generation in USD |
| `--monthly-limit` | Double | — | Monthly spend limit in USD |
| `--warning-threshold` | Double | `80` | Warning threshold percentage (0-100) |
| `--pretty` | Flag | — | Pretty-print JSON |

---

## Providers & Models

Six providers, 24 models. Each provider requires its own API key.

### fal.ai (`fal`)

| Model ID | Name | Resolution | Max Duration | $/sec | I2V |
|----------|------|------------|--------------|-------|-----|
| `fal-ai/veo3` | Veo 3 | 1280x720 | 8s | 0.15 | |
| `fal-ai/bytedance/seedance/v2/text-to-video` | Seedance 2.0 | 1920x1080 | 15s | 0.05 | |
| `fal-ai/bytedance/seedance/v2/image-to-video` | Seedance 2.0 I2V | 1920x1080 | 15s | 0.06 | Yes |
| `fal-ai/kling-video/v2/master/text-to-video` | Kling v2 Master | 1280x720 | 10s | 0.06 | Yes |
| `fal-ai/minimax/hailuo-02` | Hailuo 02 | 1280x720 | 6s | 0.05 | |
| `fal-ai/luma-dream-machine` | Luma Dream Machine | 1280x720 | 5s | 0.08 | |
| `fal-ai/hunyuan-video` | Hunyuan Video | 1280x720 | 5s | 0.04 | |
| `fal-ai/wan/v2.1/1080p` | Wan 2.1 1080p | 1920x1080 | 5s | 0.03 | |

### Replicate (`replicate`)

| Model ID | Name | Resolution | Max Duration | $/sec | I2V |
|----------|------|------------|--------------|-------|-----|
| `minimax/video-01-live` | MiniMax Video-01 Live | 1280x720 | 6s | 0.05 | |
| `tencent/hunyuan-video` | Hunyuan Video | 1280x720 | 5s | 0.04 | |
| `wavespeed-ai/wan-2.1` | Wan 2.1 | 1280x720 | 5s | 0.03 | |
| `kwaai/kling-v1.6-pro` | Kling v1.6 Pro | 1280x720 | 10s | 0.10 | Yes |

### Runway (`runway`)

| Model ID | Name | Resolution | Max Duration | $/sec | I2V |
|----------|------|------------|--------------|-------|-----|
| `gen4_turbo` | Gen-4 Turbo | 1280x720 | 10s | 0.05 | Yes |
| `gen4.5` | Gen-4.5 | 1280x720 | 10s | 0.10 | Yes |

### Luma (`luma`)

| Model ID | Name | Resolution | Max Duration | $/sec | I2V |
|----------|------|------------|--------------|-------|-----|
| `ray-2` | Ray 2 | 1280x720 | 5s | 0.10 | Yes |
| `ray-flash-2` | Ray Flash 2 | 1280x720 | 5s | 0.05 | Yes |
| `ray-3` | Ray 3 | 1280x720 | 10s | 0.20 | Yes |

### Kling (`kling`)

| Model ID | Name | Resolution | Max Duration | $/sec | I2V |
|----------|------|------------|--------------|-------|-----|
| `kling-v2.6-pro` | Kling v2.6 Pro | 1280x720 | 10s | 0.10 | Yes |
| `kling-v2.6-std` | Kling v2.6 Standard | 1280x720 | 10s | 0.05 | Yes |
| `kling-v2.5-turbo` | Kling v2.5 Turbo | 1280x720 | 5s | 0.03 | Yes |

### MiniMax (`minimax`)

| Model ID | Name | Resolution | Max Duration | $/sec | I2V |
|----------|------|------------|--------------|-------|-----|
| `MiniMax-Hailuo-2.3` | Hailuo 2.3 | 1280x720 | 10s | 0.05 | |
| `T2V-01-Director` | T2V-01 Director | 1280x720 | 6s | 0.04 | |
| `S2V-01` | S2V-01 (I2V) | 1280x720 | 6s | 0.05 | Yes |

Cost figures are estimates used for budget pre-flight checks. Actual provider billing may differ.

---

## Budget & Safety

### Budget guardrails

Set per-generation, daily, and monthly cost caps. Every `generate` command runs a pre-flight budget check — if the estimated cost would exceed any limit, the generation is rejected with `BUDGET_EXCEEDED` before any API call.

```sh
openflix budget set --daily-limit 10 --per-generation-max 2 --monthly-limit 100
openflix budget status --pretty
```

A warning is emitted (generation still proceeds) when projected daily spend exceeds `warning_threshold` (default: 80%) of the daily limit.

Budget config: `~/.vortex/budget_config.json`. Daily spend: `~/.vortex/daily_spend.json`.

### Prompt safety

`PromptSafetyChecker` runs locally before every generation. No external API calls.

| Level | Action | Categories |
|-------|--------|------------|
| **Blocked** | Generation rejected | CSAM, extreme violence, PII generation, malware |
| **Warning** | Generation proceeds with flag | Violence, suggestive, deceptive |
| **Safe** | No action | Everything else |

Blocked prompts return exit code `1` with error code `PROMPT_UNSAFE`.

---

## MCP Server

OpenFlix implements the [Model Context Protocol](https://modelcontextprotocol.io) over stdio, making it a native tool server for Claude Code, Claude Desktop, and any MCP-compatible host.

```sh
openflix mcp
```

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

| Tool | Description |
|------|-------------|
| `generate` | Submit, poll until complete, download |
| `generate_submit` | Submit only (non-blocking) |
| `generate_poll` | Poll status of existing generation |
| `list_generations` | List generation history |
| `get_generation` | Get single generation details |
| `cancel_generation` | Cancel active generation |
| `retry_generation` | Retry failed generation |
| `list_providers` | List all providers and models |
| `evaluate_quality` | Run quality evaluation |
| `submit_feedback` | Record quality score (0-100) |
| `get_metrics` | Provider performance metrics |
| `budget_status` | Current budget info |
| `project_run` | Execute a project DAG |
| `health_check` | System diagnostics |

### Resources (3)

| URI | Description |
|-----|-------------|
| `vortex://providers` | All providers and models with capabilities and pricing |
| `vortex://metrics` | Provider performance and quality metrics |
| `vortex://budget` | Current budget status and daily spend |

**Protocol:** JSON-RPC 2.0 over stdin/stdout. Tool errors return structured payloads with `code` and `retryable` fields as content (not JSON-RPC error responses), so agents can inspect and retry without special error handling.

---

## Daemon

The daemon provides a persistent Unix socket server for long-running agent connections.

```sh
# Start in foreground
openflix daemon start --foreground

# Or background via nohup
nohup openflix daemon start --foreground &

# Check status
openflix daemon status

# Stop
openflix daemon stop
```

- **Socket:** `~/.vortex/daemon.sock`
- **PID file:** `~/.vortex/daemon.pid`
- **Transport:** Newline-delimited JSON-RPC over Unix domain socket (NWListener)

Agents can `subscribe` to project IDs to receive real-time events as shots progress. Supported methods: `health`, `project.list`, `project.status`, `subscribe`, `unsubscribe`, `evaluate`, `feedback`, `provider.metrics`.

---

## Projects

Projects organize multi-shot video generation into scenes with dependency management, parallel execution, and intelligent provider routing.

### Create

```sh
openflix project create --file spec.json
```

```json
{
  "name": "Product Launch",
  "settings": {
    "default_provider": "fal",
    "default_model": "fal-ai/veo3",
    "max_concurrency": 4,
    "routing_strategy": "quality",
    "quality_enabled": true,
    "quality_threshold": 70
  },
  "scenes": [
    {
      "name": "Opening",
      "shots": [
        {
          "name": "wide_establishing",
          "prompt": "cinematic wide shot of a modern office at dawn",
          "duration": 5
        },
        {
          "name": "logo_reveal",
          "prompt": "smooth camera push into glass door with logo",
          "dependencies": ["wide_establishing"]
        }
      ]
    }
  ]
}
```

### Run

```sh
# Execute with streaming progress
openflix project run PROJECT_ID --stream

# With quality evaluation
openflix project run PROJECT_ID --evaluate --quality-threshold 70

# Resume after partial failure
openflix project run PROJECT_ID --resume
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `<project-id>` | String | required | Project ID |
| `--concurrency` | Int | `4` | Max parallel shots |
| `--stream` | Flag | — | Stream progress events |
| `--resume` | Flag | — | Reset stale/failed shots to pending |
| `--skip-download` | Flag | — | Skip auto-download |
| `--evaluate` | Flag | — | Enable quality evaluation |
| `--quality-threshold` | Double | — | Quality threshold 0-100 (implies `--evaluate`) |
| `--evaluator` | String | — | `heuristic` or `llm-vision` |
| `--api-key` | String | — | Override API key |
| `--pretty` | Flag | — | Pretty-print JSON |

### Routing strategies

| Strategy | Behavior |
|----------|----------|
| `manual` | Use provider/model specified on each shot |
| `cheapest` | Lowest cost per second among available models |
| `fastest` | Shortest max duration (heuristic proxy for speed) |
| `quality` | Highest quality score from metrics history; falls back to cost as proxy |
| `scatterGather` | Submit to N providers in parallel, keep the best result |

### Quality gate

When quality evaluation is enabled, each shot enters an `evaluating` state after generation succeeds. Two evaluators:

**`heuristic`** — local, no API calls. Scores on file existence (20pts), file size 50KB-2GB (20pts), valid extension (10pts), ffprobe duration/resolution/codec (30pts), clean generation (20pts). Degrades gracefully when ffprobe is unavailable.

**`llm-vision`** — extracts frames from the video and sends them to the Claude API with the original prompt for contextual scoring across 5 dimensions: prompt adherence, visual quality, temporal coherence, composition, technical quality.

If a shot scores below threshold and retry budget remains, it is reset to `pending` for re-dispatch. Evaluation is advisory — if the evaluator fails, the shot is accepted.

### DAG execution

Shots declare dependencies by name. The executor resolves them into parallel waves via topological sort (Kahn's algorithm), dispatching up to `max_concurrency` shots simultaneously. Failed shots retry up to `max_retries_per_shot` times with exponential backoff.

### Export

```sh
openflix project export PROJECT_ID --manifest --output ./export
ffmpeg -f concat -safe 0 -i ./export/concat.txt -c copy final.mp4
```

### Other project commands

```sh
openflix project status PROJECT_ID --detail --pretty
openflix project list --status succeeded
openflix project delete PROJECT_ID --delete-generations
openflix project shot add PROJECT_ID SCENE_ID --name shot_3 --prompt "..."
openflix project shot retry PROJECT_ID SHOT_ID
openflix project shot skip PROJECT_ID SHOT_ID
openflix project shot update PROJECT_ID SHOT_ID --prompt "new prompt"
openflix project shot remove PROJECT_ID SHOT_ID
```

---

## Architecture

```
openflix
├── VortexCLI.swift              @main — ArgumentParser entry point
├── Commands/                    One file per command
├── Providers/
│   ├── ProviderProtocol.swift   VideoProvider protocol + ProviderRegistry
│   ├── FalClient.swift          fal.ai queue API
│   ├── ReplicateClient.swift    Replicate predictions API
│   ├── RunwayClient.swift       Runway v1 API
│   ├── LumaClient.swift         Luma Dream Machine API
│   ├── KlingClient.swift        Kling API
│   └── MiniMaxClient.swift      MiniMax 3-step API (submit → query → retrieve)
├── Core/
│   ├── Models.swift             CLIGeneration, VortexError, ErrorCode, StructuredError
│   ├── GenerationEngine.swift   Submit → poll → download loop with retry/backoff
│   ├── GenerationStore.swift    ~/.vortex/store.json (flock + NSLock)
│   ├── CLIKeychain.swift        macOS Keychain — 4-tier key resolution
│   ├── BudgetManager.swift      Swift actor — daily/monthly/per-gen cost limits
│   ├── PromptSafetyChecker.swift  Local heuristic prompt screening
│   ├── ProviderRouter.swift     5 routing strategies + scatter target selection
│   ├── DAGExecutor.swift        Swift actor — topological sort + TaskGroup dispatch
│   ├── ScatterGather.swift      Multi-provider parallel dispatch, best-result selection
│   ├── QualityGate.swift        Evaluation orchestration (advisory, never blocking)
│   ├── HeuristicEvaluator.swift File + ffprobe scoring (100-point scale)
│   ├── LLMVisionEvaluator.swift Claude API multi-frame vision scoring
│   ├── ProviderMetricsStore.swift  Running averages per provider+model
│   ├── ProjectModels.swift      Project, Scene, Shot, ProjectSpec types
│   ├── ProjectStore.swift       Per-project JSON files (flock-protected)
│   ├── VideoDownloader.swift    URLSession download to ~/.vortex/downloads/
│   ├── MCPServer.swift          JSON-RPC 2.0 over stdio
│   ├── MCPToolRegistry.swift    14 tool + 3 resource definitions
│   ├── MCPProtocol.swift        Request/response types, AnyCodableValue
│   ├── DaemonServer.swift       Unix socket server (NWListener)
│   ├── DaemonSession.swift      Per-connection state + read/write loop
│   └── DaemonProtocol.swift     Daemon JSON-RPC message types
└── Output/
    └── Output.swift             emitDict, emitArray, emitEvent, fail, failStructured
```

### Data flow (single generation)

1. `PromptSafetyChecker.check()` — blocked prompts throw immediately
2. `BudgetManager.preFlightCheck()` — exceeded limits throw before any API call
3. `provider.submit()` — HTTPS call, remote task ID persisted to `GenerationStore`
4. `provider.poll()` — configurable interval, transient errors retry 3x with backoff
5. `BudgetManager.recordSpend()` — actual cost tracked on success
6. `VideoDownloader.download()` — atomic download to `~/.vortex/downloads/<id>.mp4`

### Data storage

| Path | Contents |
|------|----------|
| `~/.vortex/store.json` | All generation records |
| `~/.vortex/downloads/` | Downloaded video files |
| `~/.vortex/projects/<id>/project.json` | Per-project state |
| `~/.vortex/metrics.json` | Provider quality/latency/cost metrics |
| `~/.vortex/budget_config.json` | Budget limits |
| `~/.vortex/daily_spend.json` | Daily spend counter |
| `~/.vortex/daemon.sock` | Daemon Unix socket |
| `~/.vortex/daemon.pid` | Daemon PID |

### Design decisions

- **Zero runtime dependencies.** Links only against `swift-argument-parser` and the macOS `Security` framework. All networking via Foundation `URLSession`.
- **Actor concurrency.** `BudgetManager`, `DAGExecutor`, `MCPServer`, `DaemonServer` use Swift actors for thread-safe concurrent access.
- **File locking.** All JSON stores use `flock` + `NSLock` to prevent corruption from concurrent CLI invocations.
- **Provider protocol.** Each provider implements `submit`, `poll`, `estimateCost`, and optional `cancel`. Adding a provider is one file + one line in `ProviderRegistry`.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error (structured JSON on stderr) |

### Error codes

All errors carry a `code` field. MCP and structured errors include `retryable` and `retry_after_seconds`.

| Code | Retryable | HTTP | Description |
|------|-----------|------|-------------|
| `AUTH_MISSING` | No | 401 | No API key for provider |
| `AUTH_INVALID` | No | 401 | Key rejected by provider |
| `AUTH_EXPIRED` | No | 401 | Key expired |
| `PROVIDER_UNAVAILABLE` | No | 503 | Provider not registered |
| `PROVIDER_RATE_LIMITED` | Yes | 429 | Rate limit hit |
| `PROVIDER_TIMEOUT` | Yes | 504 | Poll timed out |
| `PROVIDER_SERVER_ERROR` | Yes | 502 | Provider 5xx |
| `INPUT_INVALID` | No | 400 | Invalid parameter |
| `INPUT_TOO_LARGE` | No | 400 | Exceeds provider limits |
| `PROMPT_UNSAFE` | No | 400 | Prompt blocked by safety checker |
| `BUDGET_EXCEEDED` | No | 402 | Would exceed budget limit |
| `QUOTA_EXCEEDED` | No | 402 | Provider quota exhausted |
| `DISK_FULL` | No | 500 | Local disk full |
| `GENERATION_FAILED` | No | 500 | Provider reported failure |
| `GENERATION_NOT_FOUND` | No | 404 | ID not in local store |
| `QUALITY_BELOW_THRESHOLD` | No | 500 | Failed quality gate |
| `DOWNLOAD_FAILED` | Yes | 500 | Download network error |
| `INTERNAL_ERROR` | No | 500 | Unexpected error |
| `CONFIG_INVALID` | No | 400 | Invalid configuration |
| `NOT_COMPLETE` | Yes | 404 | Generation not yet complete |

```json
{"error": "No API key for 'fal'. Use: openflix keys set fal <key>", "code": "no_api_key"}
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `VORTEX_FAL_KEY` | API key for fal.ai |
| `VORTEX_REPLICATE_KEY` | API key for Replicate |
| `VORTEX_RUNWAY_KEY` | API key for Runway |
| `VORTEX_LUMA_KEY` | API key for Luma |
| `VORTEX_KLING_KEY` | API key for Kling |
| `VORTEX_MINIMAX_KEY` | API key for MiniMax |
| `VORTEX_API_KEY` | Generic fallback (all providers) |
| `ANTHROPIC_API_KEY` | For `llm-vision` quality evaluator |

---

## Contributing

```sh
git clone https://github.com/openflix/openflix.git
cd openflix/VortexCLI
swift build
.build/debug/openflix --help
```

### Adding a provider

1. Create `Sources/openflix/Providers/NewProviderClient.swift`
2. Implement `VideoProvider` protocol (`submit`, `poll`, `estimateCost`)
3. Define models as `[CLIProviderModel]` with pricing and capabilities
4. Add to `ProviderRegistry` in `ProviderProtocol.swift`
5. Add `VORTEX_NEWPROVIDER_KEY` env var support in `CLIKeychain.swift`

### Code conventions

- All stdout output via `Output.emitDict` / `Output.emitArray` / `Output.emitEvent`. No `print()`.
- All errors via `Output.fail` or `Output.failMessage` (both `-> Never`).
- Keychain service prefix: `com.openflix.vortex.{provider}` (shared with GUI app).
- New MCP tools: add definition to `MCPToolRegistry.allTools` + case in `MCPServer.dispatchTool()`.

---

## License

[MIT](../LICENSE) -- Copyright (c) 2026 Moiz Saeed
