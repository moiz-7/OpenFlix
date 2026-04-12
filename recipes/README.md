# OpenFlix Recipe Examples

Ready-to-run video generation recipes. Each `.openflix` file is a portable recipe bundle.

## Run a recipe

    openflix recipe run recipes/cinematic-sunset.openflix --wait

## Benchmark across providers

    openflix recipe benchmark recipes/cinematic-sunset.openflix --providers fal,kling,luma --wait

## Import and modify

    openflix recipe import recipes/cinematic-sunset.openflix
    openflix recipe fork <imported-id> --name "My Sunset" --prompt "same but at dawn"
    openflix recipe run <forked-id> --wait

## Create your own

    openflix recipe init "your prompt here" --provider fal --model fal-ai/veo3 --name "My Recipe"
    openflix recipe export <id> -o my-recipe.openflix

## Recipe format

Each `.openflix` file is JSON containing one or more recipes with:
- Prompt and negative prompt
- Provider and model
- Resolution, duration, aspect ratio
- Seed and extra parameters
- Provenance (fork source, category)
- Stats (generation count, quality score, cost)
