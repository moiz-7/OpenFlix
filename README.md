# OpenFlix

Generate AI videos from your terminal. Works with every major video generation API — bring your own keys.

```
openflix generate "a red panda eating ramen in tokyo" --provider fal --model wan-pro
```

## Install

```bash
brew install bubble-research/tap/openflix
```

Or build from source (requires macOS 14+, Xcode 15+):

```bash
git clone https://github.com/moiz-7/OpenFlix.git
cd OpenFlix
swift build -c release
cp .build/release/openflix /usr/local/bin/openflix
```

## Setup

Store your API key for any provider:

```bash
openflix keys set fal <your-key>
openflix keys set replicate <your-key>
openflix keys set runway <your-key>
openflix keys set luma <your-key>
openflix keys set kling <your-key>
openflix keys set minimax <your-key>
```

Keys are stored in the system Keychain — never in plain text.

## Commands

| Command | Description |
|---------|-------------|
| `generate` | Submit a video generation |
| `status` | Check generation status |
| `list` | List all generations |
| `download` | Download a completed video |
| `retry` | Retry a failed generation |
| `cancel` | Cancel a pending generation |
| `delete` | Delete a generation record |
| `purge` | Remove all completed generations |
| `keys` | Manage API keys |
| `providers` | List supported providers and models |
| `cost` | View spend history |
| `budget` | Set spending limits |
| `health` | Check provider API status |
| `batch` | Submit multiple generations from a JSON file |
| `project` | Manage multi-shot video projects |
| `daemon` | Run as a background socket server |
| `evaluate` | Score a video with heuristic or LLM analysis |
| `feedback` | Rate a generation (used to tune provider routing) |
| `metrics` | View per-provider quality and cost metrics |
| `mcp` | Run as an MCP server (stdio) |

## Examples

```bash
# Generate and wait for result
openflix generate "timelapse of a city at night" --provider runway --model gen4-turbo --wait

# List recent generations
openflix list --limit 10

# Check provider health
openflix health

# Set a daily spend limit
openflix budget set --daily 10.00

# Run a multi-shot project
openflix project run my-project-id --evaluate --quality-threshold 0.7

# Batch submit from file
openflix batch jobs.json --concurrency 3
```

## Providers & Models

Run `openflix providers` to see all supported models and current health status.

## MCP Support

OpenFlix ships an MCP server for use with Claude and other AI assistants:

```bash
openflix mcp
```

Add to your MCP client config and call tools like `openflix_generate`, `openflix_list`, `openflix_status` directly from your AI assistant.

## License

Proprietary — source available for reference. See [LICENSE](LICENSE).
