# Featured Recipes

Curated picks from the OpenFlix recipe collection.

## Starter Recipes (Begin Here)

| Recipe | Category | Provider | Description |
|--------|----------|----------|-------------|
| [Cinematic Sunset](cinematic-sunset.openflix) | cinematic | fal/veo3 | Golden hour drone shot |
| [Anime Sword Fight](anime-fight.openflix) | anime | fal/kling-v2 | Dynamic sword clash |
| [Product Reveal](product-reveal.openflix) | product | runway/gen4 | Smartphone showcase |
| [Nature Timelapse](nature-timelapse.openflix) | nature | fal/wan-2.1 | Mountain clouds |
| [Abstract Morph](abstract-morph.openflix) | abstract | luma/ray-2 | Fluid color art |

## Run Any Recipe

```bash
openflix recipe run recipes/cinematic-sunset.openflix --wait
```

## Benchmark a Recipe

```bash
openflix recipe benchmark recipes/cinematic-sunset.openflix --providers fal,kling,luma --wait
```

## Fork and Modify

```bash
openflix recipe import recipes/cinematic-sunset.openflix
openflix recipe fork <id> --name "My Version" --prompt "same but at dawn"
openflix recipe run <forked-id> --wait
```

## Categories

Browse recipes by category:
- **cinematic/** -- Film, drama, epic scenes
- **anime/** -- Anime and manga style
- **product/** -- Product reveals and ads
- **nature/** -- Landscapes and wildlife
- **abstract/** -- Abstract and generative art
- **social/** -- Short-form vertical content
- **trailer/** -- Movie/game trailers
- **dialogue/** -- Character close-ups and conversations
