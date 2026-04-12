# Phase 3: Hosted Recipe Registry + Public Benchmark Layer

**Date:** 2026-04-12
**Result:** 180/180 CLI tests, 198/198 app tests, registry server verified, full roundtrip tested
**New:** Registry server, 3 CLI commands, app deep links, 3 docs files

---

## Summary

Phase 3 makes recipes discoverable. A minimal FastAPI registry server lets users publish, search, browse, and fork recipes via web pages and API. The CLI gains `publish`, `search`, and URL-based `import`. The app gains `openflix://recipe/<id>` deep link support and a "Publish to Registry" button. Three documentation files spec the format, publishing workflow, and API.

**Before:** Recipes were portable as `.openflix` files but discovery was manual — share a file, email a link.

**After:** Publish → browse at registry.openflix.app → fork via CLI/app → benchmark → publish results. The system is now networked.

---

## New Files Created

### Registry Server (`registry/`)
| File | Purpose |
|------|---------|
| `server.py` | FastAPI app: 6 recipe endpoints, 3 benchmark endpoints, 5 HTML pages, SQLite storage |
| `templates/base.html` | Dark-theme base layout (nav, search, footer) |
| `templates/index.html` | Homepage: search bar, recent recipes grid, category badges |
| `templates/recipe.html` | Recipe detail: prompt, stats, lineage, download/import/fork actions |
| `templates/benchmark.html` | Benchmark results table with winner highlight |
| `static/style.css` | Dark theme CSS (GitHub-dark palette, monospace-friendly) |
| `requirements.txt` | fastapi, uvicorn, aiosqlite, jinja2, python-multipart |
| `.env.example` | REGISTRY_HOST, REGISTRY_PORT, DB_PATH |
| `README.md` | Setup, run, API usage, deploy |

### CLI (`VortexCLI/Sources/openflix/`)
| File | Purpose |
|------|---------|
| `Core/RegistryClient.swift` | HTTP client: publish, fetch, fetchFromURL, search, publishBenchmark |

### App (`OpenFlix/`)
| File | Purpose |
|------|---------|
| `Vortex/Services/RegistryClient.swift` | App HTTP client: fetchBundle, fetchFromURL, publish |

### Documentation (`docs/`)
| File | Purpose |
|------|---------|
| `recipe-format.md` | .openflix format v2 specification |
| `publishing.md` | Publishing guide (CLI, app, curl) |
| `registry-api.md` | API reference (all endpoints, errors, rate limits) |

## Files Modified

| File | Change |
|------|--------|
| `RecipeCommand.swift` (CLI) | Added `RecipePublish`, `RecipeSearch` subcommands; extended `RecipeImport` with `--url` for registry/URL import |
| `RecipeBenchmarkCommand.swift` (CLI) | Added `--publish` and `--author` flags for publishing benchmark results |
| `OpenFlixApp.swift` (app) | Added `openflix://recipe/<id>` deep link handler with registry fetch + import |
| `PromptStudioView.swift` (app) | Added "Publish to Registry" context menu item with success/error alert |
| `README.md` | Added "Publish & Share" section and "Documentation" links |
| `test.sh` (CLI) | +5 tests (169-173): publish/search/import-url help, benchmark --publish flag, RegistryClient existence |

## Registry API

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/recipes` | POST | Upload .openflix bundle |
| `/api/recipes` | GET | Search/list (q, category, provider, limit, offset) |
| `/api/recipes/{id}` | GET | Recipe detail JSON |
| `/api/recipes/{id}/bundle` | GET | Download .openflix file |
| `/api/recipes/{id}/forks` | GET | List forks |
| `/api/recipes/{id}/lineage` | GET | Ancestor chain |
| `/api/benchmarks` | POST | Publish benchmark results |
| `/api/benchmarks` | GET | List benchmarks |
| `/api/benchmarks/{id}` | GET | Benchmark detail |

## HTML Pages

| URL | Page |
|-----|------|
| `/` | Homepage: search + recent recipes + categories |
| `/recipe/{id}` | Recipe detail with prompt, stats, lineage, actions |
| `/benchmark/{id}` | Benchmark results table with winner |
| `/category/{name}` | Category browse |
| `/search?q=...` | Search results |

## Roundtrip Verified

```
1. Start registry: uvicorn server:app --port 8321
2. Publish example: curl -X POST .../api/recipes -d @cinematic-sunset.openflix → {id, url}
3. Search: curl .../api/recipes?q=sunset → 1 result
4. Download: curl .../api/recipes/{id}/bundle → valid .openflix JSON
5. CLI import: openflix recipe import --url {id} → imported recipe
6. Browse: open http://localhost:8321/recipe/{id} → HTML page with prompt, stats, actions
```

## Test Results

- **CLI:** 180/180 (175 previous + 5 new), 0 failures
- **App:** 198/198, 0 failures
- **Registry:** Server starts, all endpoints functional
