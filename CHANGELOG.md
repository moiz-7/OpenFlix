# Changelog — OpenFlix CLI

All notable changes to the `openflix` CLI. Format loosely follows [Keep a Changelog](https://keepachangelog.com); versions are git tags (`v*`), which the release workflow verifies against the binary's reported version.

## [1.0.1] — 2026-08-03

### Added
- `openflix vote <winner> <loser> [--category]` — share a pairwise preference vote with the community registry (the data `--route smart` reads). Anonymous: provider/model + category + random client id + `event_id` dedup key only.
- MCP: `submit_vote` tool; `generate`/`generate_submit` accept `route: "smart"` + `category` (provider/model no longer required), returning the routing decision. 15 tools total.
- Smart routing honors the registry's `ranked` anti-poisoning flag — single-source-flooded models never steer `--route smart`.

### Changed
- **Universal binary** (arm64 + x86_64). v1.0.0 was Apple-Silicon-only with no arch guard — Intel Macs installed a binary that could not run.
- Quickstart's vote step now points at `openflix vote` and its community claim is accurate; `openflix feedback` documented as the local-only alternative.

### Fixed (since v1.0.0, previously unreleased on brew)
- Replicate: model slugs route to `/v1/models/{owner}/{name}/predictions` (was 422 on every submit).
- Runway/Kling hosts corrected; provider error bodies surfaced instead of bare HTTP codes.
- SSRF/download-cap hardening; budget gates estimate cost before submit; spend recorded on every terminal poll path; `retry` preserves reference image + extra params; empty scatter targets no longer abort.

## [1.0.0] — 2026-07

Initial release: 6 commercial providers + local ComfyUI, recipes (init/run/fork/benchmark/publish), generation engine with budgets + prompt safety + hooks, workflows/DAG, projects, MCP server, daemon, smart routing (read-only).
