# OpenFlix

The reproducible AI video workflow system.

## What is OpenFlix?

OpenFlix turns AI video generation from one-shot prompting into a reproducible,
benchmarkable, shareable workflow. The core primitive is the **recipe** -- a portable
specification that captures everything needed to generate a video: prompt, model,
parameters, seed, and provenance.

Recipes are forkable, benchmarkable, and shareable as `.openflix` files.

## Quick Start

### 1. Install

From source:
```bash
cd VortexCLI && swift build
cp .build/debug/openflix /usr/local/bin/
```

### 2. Set up API key
```bash
openflix keys set fal your-fal-key
```

### 3. Run an example recipe
```bash
openflix recipe run recipes/cinematic-sunset.openflix --wait
```

### 4. Create your own recipe
```bash
openflix recipe init "neon city timelapse at night" \
  --provider fal --model fal-ai/veo3 --name "Neon City"
```

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
openflix keys set <provider> <key>  Store API key
openflix providers                  List providers
openflix models --provider <id>     List models
openflix health                     Check provider status
openflix cost                       Show cost breakdown
openflix budget                     Manage spending limits
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

## Example Recipes

See [`recipes/`](recipes/) for ready-to-run examples:
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

- [Canonical Workflows](docs/workflows.md) -- Create, benchmark, fork, share
- [Recipe Format](docs/recipe-format.md) -- .openflix specification
- [Publishing Guide](docs/publishing.md) -- How to publish recipes and benchmarks
- [Registry API](docs/registry-api.md) -- API reference

## Architecture

| Surface | Purpose |
|---------|---------|
| **macOS App** | Visual creation -- prompt studio, comparison theater, model arena |
| **CLI** (`openflix`) | Automation -- scripting, benchmarking, CI/CD, reproducibility |
| **Registry** | Discovery -- browse, fork, leaderboards, benchmark results |

## Data Storage

- Recipes: `~/.openflix/recipes.json`
- Generations: `~/.openflix/store.json`
- API keys: macOS Keychain (`com.openflix.cli.*`)
- Projects: `~/.openflix/projects/`
- Metrics: `~/.openflix/metrics.json`

## Documentation

- [Recipe Format Specification](docs/recipe-format.md)
- [Publishing Guide](docs/publishing.md)
- [Registry API Reference](docs/registry-api.md)

## Requirements

- macOS 14.0+
- API key for at least one provider

## License

Proprietary -- Copyright (c) 2026 Bubble Research. All rights reserved.
See [LICENSE](LICENSE) for details.
