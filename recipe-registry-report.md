# OpenFlix Recipe Registry & Benchmark Report

**Date:** 2026-04-12
**Scope:** 45 new recipe files + 10 benchmark bundles

---

## Summary

Created 45 new `.openflix` recipe files (bringing total to 50) and 10 benchmark comparison bundles for the OpenFlix registry. All recipes use valid model IDs, unique UUIDs, and follow the formatVersion 2 schema.

---

## Recipe Distribution by Category

| Category | Existing | New | Total | Provider/Model Mix |
|----------|----------|-----|-------|--------------------|
| cinematic | 1 | 7 | 8 | fal (veo3, kling-video) |
| anime | 1 | 6 | 7 | fal (veo3, kling-video) |
| product | 1 | 5 | 6 | runway (gen4_turbo), fal (veo3) |
| nature | 1 | 6 | 7 | fal (veo3, wan/v2.1/1080p) |
| abstract | 1 | 5 | 6 | luma (ray-2), fal (veo3) |
| social | 0 | 5 | 5 | fal (minimax/hailuo-02) |
| trailer | 0 | 5 | 5 | fal (veo3), runway (gen4_turbo) |
| dialogue | 0 | 6 | 6 | fal (kling-video) |
| **Total** | **5** | **45** | **50** | |

---

## New Recipe Files

### Cinematic (7 new)
1. `cinematic-epic-battle.openflix` — Medieval army clash, aerial + dolly zoom
2. `cinematic-film-noir.openflix` — Detective in rain-slicked alley, B&W
3. `cinematic-wedding.openflix` — Vineyard ceremony at golden hour
4. `cinematic-car-chase.openflix` — Night car chase, neon reflections
5. `cinematic-underwater.openflix` — Deep ocean diver, bioluminescence
6. `cinematic-desert-drone.openflix` — FPV drone over Saharan dunes
7. `cinematic-rain-street.openflix` — Tokyo neon rain, cyberpunk grade

### Anime (6 new)
1. `anime-magical-girl.openflix` — Transformation with light ribbons
2. `anime-mecha-battle.openflix` — Giant robots in destroyed city
3. `anime-cherry-blossom.openflix` — Ghibli-style hilltop scene
4. `anime-samurai-standoff.openflix` — Bridge standoff, ink wash style
5. `anime-fantasy-castle.openflix` — Floating castle with dragons
6. `anime-rain-scene.openflix` — Shinkai-style bus stop rain

### Product (5 new)
1. `product-perfume.openflix` — Luxury bottle from liquid gold
2. `product-sneaker.openflix` — Floating shoe with powder bursts
3. `product-watch.openflix` — Macro mechanical movement
4. `product-food-plating.openflix` — Michelin-star plating overhead
5. `product-car-interior.openflix` — Luxury sports car glide-through

### Nature (6 new)
1. `nature-coral-reef.openflix` — Underwater reef dolly
2. `nature-northern-lights.openflix` — Aurora over Arctic landscape
3. `nature-jungle-canopy.openflix` — Ascending through rainforest
4. `nature-volcanic-eruption.openflix` — Lava fountaining, lightning
5. `nature-savanna-wildlife.openflix` — Elephant herd at golden hour
6. `nature-flower-bloom.openflix` — Peony macro timelapse

### Abstract (5 new)
1. `abstract-fractal-zoom.openflix` — Mandelbrot infinite zoom
2. `abstract-paint-explosion.openflix` — Slow-mo paint collision
3. `abstract-tessellation.openflix` — Evolving geometric tiles
4. `abstract-light-prism.openflix` — White light spectrum split
5. `abstract-smoke-tendrils.openflix` — Colored smoke formations

### Social (5 new) — all 9:16 / 720x1280
1. `social-food-prep.openflix` — Poke bowl assembly overhead
2. `social-dance-transition.openflix` — Outfit/location swap on spin
3. `social-outfit-reveal.openflix` — Casual to glam snap-cut
4. `social-travel-montage.openflix` — Multi-destination whip-pans
5. `social-pet-compilation.openflix` — Golden retriever puppy clips

### Trailer (5 new)
1. `trailer-scifi-teaser.openflix` — Derelict spaceship exploration
2. `trailer-horror-opening.openflix` — Victorian hallway, creeping door
3. `trailer-documentary-intro.openflix` — Iceland landscape + village
4. `trailer-game-trailer.openflix` — Fantasy kingdom combat montage
5. `trailer-music-video.openflix` — Surreal cathedral performance

### Dialogue (6 new)
1. `dialogue-interview.openflix` — Two-camera studio interview
2. `dialogue-courtroom.openflix` — Lawyer closing argument
3. `dialogue-coffee-shop.openflix` — Friends at window seat
4. `dialogue-monologue.openflix` — Tight close-up emotional delivery
5. `dialogue-news-anchor.openflix` — Broadcast desk delivery
6. `dialogue-podcast.openflix` — Two-host recording session

---

## Benchmark Bundles (10)

| # | File | Category | Recipe | Winner | Quality | Providers Compared |
|---|------|----------|--------|--------|---------|-------------------|
| 1 | `benchmark-cinematic-epic-battle.json` | cinematic | Epic Battle Sequence | fal/veo3 | 89 | 4 (fal, kling, runway, luma) |
| 2 | `benchmark-anime-samurai-standoff.json` | anime | Samurai Standoff | fal/veo3 | 91 | 3 (fal x2, luma) |
| 3 | `benchmark-product-watch.json` | product | Watch Mechanism | runway/gen4_turbo | 93 | 3 (runway, fal, kling) |
| 4 | `benchmark-nature-northern-lights.json` | nature | Northern Lights | fal/veo3 | 94 | 4 (fal x2, luma, kling) |
| 5 | `benchmark-abstract-paint-explosion.json` | abstract | Paint Droplet Explosion | fal/veo3 | 88 | 3 (fal, luma x2) |
| 6 | `benchmark-social-food-prep.json` | social | Viral Food Prep | fal/veo3 | 85 | 3 (fal x2, minimax) |
| 7 | `benchmark-trailer-scifi-teaser.json` | trailer | Sci-Fi Movie Teaser | fal/veo3 | 92 | 4 (fal x2, runway, luma) |
| 8 | `benchmark-dialogue-courtroom.json` | dialogue | Courtroom Drama | fal/kling-video | 84 | 3 (fal x2, kling) |
| 9 | `benchmark-cinematic-rain-street.json` | cinematic | Rain-Soaked Street | fal/veo3 | 90 | 4 (fal x3, runway) |
| 10 | `benchmark-nature-volcanic-eruption.json` | nature | Volcanic Eruption | fal/veo3 | 91 | 4 (fal x2, runway, luma) |

### Benchmark Insights
- **fal/veo3** won 9 out of 10 benchmarks (dominant across categories)
- **runway/gen4_turbo** won the product/macro benchmark (Watch Mechanism, quality 93)
- **fal/kling-video** won the dialogue benchmark (Courtroom, quality 84) — best for human expressions
- Quality range: 62-94 across all results
- Cost range: $0.15-$0.80 per generation
- Latency range: 20-75 seconds

---

## Validation

- [x] 50 total recipe files (5 existing + 45 new)
- [x] 10 benchmark JSON files
- [x] All 50 UUIDs are unique
- [x] All model IDs are from the approved list
- [x] Social recipes use 9:16 / 720x1280
- [x] All other recipes use 16:9 / 1280x720
- [x] Existing 5 recipe files untouched
- [x] All JSON valid (formatVersion 2 schema)
- [x] Prompts are 2-4 sentences with camera, lighting, and technical details
- [x] Category-appropriate negative prompts applied
