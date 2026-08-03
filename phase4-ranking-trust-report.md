# Phase 4: Ranking, Lineage, Trust, and Growth Surfaces

**Date:** 2026-04-12
**Result:** All pages render (200), all API endpoints functional, 180/180 CLI tests, 198/198 app tests

---

## Summary

Phase 4 transforms the registry from a file host into an intelligence surface. Recipes are now ranked, trust-signaled, and deeply linked through lineage trees. Benchmarks are storable as rerunnable bundles. Every page pushes users toward the core loop: discover -> import -> fork -> benchmark -> publish.

---

## New API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/rankings/recipes` | GET | Ranked recipes (sort: quality/forks/wins/trending/downloads, filter: category) |
| `/api/rankings/benchmarks` | GET | Ranked benchmarks (sort: recent, filter: category) |
| `/api/recipes/{id}/run` | POST | Record a recipe run (increments run_count, updates last_tested_at) |
| `/api/recipes/{id}/tree` | GET | Full fork tree: ancestors + descendants + stats (depth, best descendant) |
| `/api/benchmarks/{id}/bundle` | GET | Download rerunnable benchmark bundle JSON |

## New HTML Pages

| Page | URL | Content |
|------|-----|---------|
| Leaderboard | `/leaderboard` | Sort tabs (Quality/Forks/Wins/Trending/Downloads), category filter, ranked list with gold/silver/bronze badges |
| Benchmarks Index | `/benchmarks` | Browse all benchmarks, category filter, provider count badges, winner badges |

## Enhanced Pages

| Page | Additions |
|------|-----------|
| Homepage (`/`) | "Top Recipes" section with rank badges, "Latest Benchmark Winners" section |
| Recipe (`/recipe/{id}`) | Trust signals row (runs, benchmark wins, last tested, downloads), best descendant highlight, 4-card action grid (Run/Fork/Benchmark/Download) |
| Benchmark (`/benchmark/{id}`) | Provider count badge, rerun CTA with CLI command, download bundle button |

## Schema Additions

| Table | Column | Type | Purpose |
|-------|--------|------|---------|
| recipes | run_count | INTEGER | Verified run count |
| recipes | last_tested_at | TEXT | Last run timestamp |
| recipes | benchmark_win_count | INTEGER | Times won a benchmark |
| benchmarks | provider_count | INTEGER | Number of providers compared |
| benchmarks | bundle_json | TEXT | Full benchmark bundle for rerun |

## Bug Fix

- Fixed all `TemplateResponse` calls for Starlette 1.0 API (`TemplateResponse(request, name, context)` instead of `TemplateResponse(name, {"request": request, ...})`)

## Trust Signals Displayed

- Verified run count
- Benchmark win count
- Last tested date
- Download count
- Provider count (on benchmarks)
- Best descendant quality score (in lineage)

## Test Results

- **CLI:** 180/180, 0 failures
- **App:** 198/198, 0 failures
- **Registry:** All 7 pages render 200, all 13 API endpoints functional
