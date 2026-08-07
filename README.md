# OpenFlix CLI

**The shipped OpenFlix product** — v1.0.2 on Homebrew, universal binary (Apple Silicon + Intel), macOS 14+.

AI video generation for terminals and agents: 7 providers, reproducible recipes, enforced budgets, community-powered smart routing (`--route smart`), pairwise voting (`openflix vote`), and an MCP server so AI agents can drive it safely.

> This repo is the CLI only. The OpenFlix macOS app (player + Studio) is a separate, not-yet-released product developed in a private monorepo that vendors this repo as a submodule.

## What is OpenFlix?

OpenFlix turns AI video generation from one-shot prompting into a reproducible,
benchmarkable, shareable workflow. The core primitive is the **recipe** -- a portable
specification that captures everything needed to generate a video: prompt, model,
parameters, seed, and provenance.

Recipes are forkable, benchmarkable, and shareable as `.openflix` files.

## Quick Start

### 1. Install

Homebrew (recommended):
```bash
brew tap moiz-7/openflix && brew install openflix
```

Or from source:
```bash
swift build -c release
cp .build/release/openflix /usr/local/bin/
```

### 2. Set up API key
```bash
openflix keys set fal your-fal-key
```

### 3. Create and run your first recipe
```bash
openflix recipe init "golden hour city skyline, slow dolly" \
  --provider fal --model fal-ai/wan/v2.1/1080p --name my-first-recipe
openflix recipe run <recipe-id> --wait
```
(`recipe init` prints the new recipe's id. Prefer a ready-made starting point?
Import one from the registry: `openflix recipe import --url <recipe-id>` — browse
[registry.openflix.app](https://registry.openflix.app).)

### 4. Not sure where to start?
```bash
openflix quickstart
```
Checks which provider keys you have configured and prints the canonical
generate → compare → vote → publish loop as copy-pasteable commands.

### 5. Benchmark across models
```bash
openflix recipe benchmark <recipe-id> \
  --providers fal,kling,luma --wait
```

### 6. Fork and iterate
```bash
openflix recipe fork <recipe-id> --name "darker version" \
  --prompt "same scene but post-apocalyptic"
openflix recipe run <forked-id> --wait
```

### 7. Export and share
```bash
openflix recipe export <recipe-id> -o my-recipe.openflix
```

## Publish & Share

### Publish a recipe to the registry
```bash
openflix recipe publish <recipe-id> --author "Your Name"
```

### Search the registry
```bash
openflix recipe search "cinematic" --category cinematic
```

### Import from registry
```bash
openflix recipe import --url <recipe-url-or-id>
```

### Publish benchmark results
```bash
openflix recipe benchmark <id> --providers fal,kling --wait --publish
```

### Browse recipes
Visit [registry.openflix.app](https://registry.openflix.app) to discover and fork recipes.

## Why Recipes?

| Without recipes | With recipes |
|----------------|-------------|
| "I typed a prompt and got a video" | "I have a reproducible spec I can re-run, fork, and benchmark" |
| Can't compare models fairly | Run one recipe across providers, compare cost/quality/speed |
| Creative work is lost | Fork chains preserve creative lineage |
| Can't share workflows | .openflix files are portable and inspectable |

## Surfaces

| Surface | Purpose |
|---------|---------|
| **CLI** (`openflix`) | Automation, scripting, benchmarking, CI/CD |
| **macOS App** (OpenFlix) | Visual creation, comparison theater, model arena |

## CLI Commands

### Create & Manage Recipes
```
openflix recipe init <prompt>     Create a new recipe
openflix recipe show <id>         Show recipe details
openflix recipe list              List all recipes
openflix recipe fork <id>         Fork a recipe with modifications
openflix recipe export <id>       Export to .openflix file
openflix recipe import <file>     Import from .openflix file
```

### Run & Benchmark
```
openflix recipe run <id>          Generate video from recipe
openflix recipe benchmark <id>    Run across multiple providers
openflix compare <id1> <id2>      Compare two generations
openflix vote <winner> <loser>    Record a pairwise preference vote (fuels --route smart)
```

### Generate (direct)
```
openflix generate <prompt>        Submit a generation job
openflix status <id>              Check generation status
openflix list                     List generations
openflix download <id>            Download video
openflix evaluate <id>            Evaluate video quality
```

### Infrastructure
```
openflix quickstart                 Guided onboarding: keys check + canonical workflow
openflix keys set <provider> <key>  Store API key
openflix providers                  List providers
openflix models --provider <id>     List models
openflix health                     Check provider status
openflix cost                       Show cost breakdown
openflix budget                     Manage spending limits
openflix mcp                        Run as an MCP server for AI agents (see docs/mcp-quickstart.md)
```

## Providers

| Provider | Models | Pricing |
|----------|--------|---------|
| fal.ai | Veo 3, Seedance 2.0, Kling v2 Master, Hailuo 02, Luma Dream Machine, Hunyuan, Wan 2.1 | $0.03-0.15/s |
| Replicate | Hunyuan, Wan 2.1, Kling v1.6 Pro | $0.03-0.10/s |
| Runway | Gen-4 Turbo, Gen-4.5 | $0.05-0.10/s |
| Luma | Ray 2, Ray Flash 2, Ray 3 | $0.05-0.20/s |
| Kling | v2.6 Pro, v2.6 Standard, v2.5 Turbo | $0.03-0.10/s |
| MiniMax | Hailuo 2.3, T2V-01 Director, S2V-01 | $0.04-0.05/s |
| Local (ComfyUI) | comfyui — your own workflow graph, keyless | $0 |

The `local` provider talks to a ComfyUI server (`OPENFLIX_COMFYUI_URL`, default
`http://127.0.0.1:8188`) and needs no API key. Video graphs are rig-specific:
export your workflow with **Save (API Format)** in ComfyUI, insert
`{{prompt}}`, `{{negative_prompt}}`, `{{seed}}`, and `{{duration}}`
placeholders, and save it to `~/.openflix/comfyui-graph.json`.

## Example Recipes

The [`recipes/`](recipes/) directory in this repo has 50 ready-to-run example
bundles (a git clone only — a Homebrew install ships just the binary; import
examples from [registry.openflix.app](https://registry.openflix.app) instead
with `openflix recipe import --url <recipe-id>`). Highlights:
- `cinematic-sunset.openflix` -- Drone sunset shot
- `anime-fight.openflix` -- Anime sword fight
- `product-reveal.openflix` -- Product showcase
- `nature-timelapse.openflix` -- Mountain timelapse
- `abstract-morph.openflix` -- Abstract fluid art

## Featured Recipes

| Recipe | Category | Provider | Run it |
|--------|----------|----------|--------|
| Cinematic Sunset | cinematic | fal/veo3 | `openflix recipe run recipes/cinematic-sunset.openflix --wait` |
| Anime Sword Fight | anime | fal/kling-v2 | `openflix recipe run recipes/anime-fight.openflix --wait` |
| Product Reveal | product | runway/gen4 | `openflix recipe run recipes/product-reveal.openflix --wait` |

See [recipes/FEATURED.md](recipes/FEATURED.md) for the full curated collection.

## Benchmark Results

Run any recipe across providers to compare cost, quality, and speed:

```bash
openflix recipe benchmark recipes/cinematic-sunset.openflix \
  --providers fal,kling,luma --wait --publish
```

See [benchmarks/](benchmarks/) for published benchmark results.

## Workflows

- [Workflow Engine](docs/workflows-engine.md) -- Multi-stage pipelines: `openflix workflow run`, journaling, `--resume`, hooks
- [MCP Quickstart](docs/mcp-quickstart.md) -- Wire OpenFlix into Claude Code or any MCP-capable agent

## Architecture

| Surface | Purpose |
|---------|---------|
| **macOS App** | Visual creation -- prompt studio, comparison theater, model arena |
| **CLI** (`openflix`) | Automation -- scripting, benchmarking, CI/CD, reproducibility |
| **Registry** | Discovery -- browse, fork, leaderboards, benchmark results |

## Data Storage

- Recipes: `~/.openflix/recipes.json`
- Generations: `~/.openflix/generations/` (one JSON file per record; legacy `store.json` migrates automatically)
- API keys: macOS Keychain (`com.openflix.cli.*`)
- Projects: `~/.openflix/projects/`
- Metrics: `~/.openflix/metrics.json`

## Documentation

- [Workflow Engine](docs/workflows-engine.md)
- [MCP Quickstart](docs/mcp-quickstart.md) -- agent setup, all 15 tools, smart routing, voting

## Requirements

- macOS 14.0+
- API key for at least one provider

## License

Proprietary -- Copyright (c) 2026 Bubble Research. All rights reserved.
See [LICENSE](LICENSE) for details.
