# Changelog — OpenFlix CLI

All notable changes to the `openflix` CLI. Format loosely follows [Keep a Changelog](https://keepachangelog.com); versions are git tags (`v*`), which the release workflow verifies against the binary's reported version.

## [1.1.0] — 2026-08-08

**1.0.2 was tagged in code but never released** — `Version.swift` said `1.0.2`,
no `v1.0.2` tag was ever pushed, and Homebrew continued serving 1.0.1. So this
release is the first one that puts the 1.0.2 demo-readiness fixes below into
anyone's hands, alongside everything new here.

### Added
- **The MCP server speaks the current protocol era.** It served only
  `2024-11-05`, and the `2026-07-28` revision's own compatibility matrix says
  *Modern client → Legacy server = **Fails***. `openflix mcp` is the server that
  spends money (`generate`, `generate_submit`), so that break would have taken
  out the half of the agent story that actually creates video. It now answers
  `server/discover` **and** `initialize` on the same pipe, serving
  `2026-07-28` / `2025-06-18` / `2024-11-05`, and returns `-32022` with the
  supported list rather than silence when asked for a revision it does not know.
  A client pinned to `2024-11-05` still works, unchanged.
- **MCP depth:** tool annotations (spending tools are marked destructive),
  `outputSchema` + `structuredContent`, resource templates, recipes exposed as
  MCP prompts with argument completion.
- **Logging.** There was none — zero `OSLog` or `Logger` across the whole
  package — in a tool that spends BYOK money unattended. Every submission,
  terminal status, refusal (with its reason) and provider HTTP failure is now
  recorded to `~/.openflix/logs/openflix.log` (JSONL, 1 MiB rotation) and
  `OSLog`. **Never to stdout**, so machine-readable output is unaffected. API
  keys, tokens and prompt text are redacted. Control with `OPENFLIX_LOG_LEVEL`,
  `OPENFLIX_LOG_FILE`, `OPENFLIX_LOG_STDERR`.

### Fixed
- **Security: path traversal was reachable through MCP.** Record stores resolved
  an agent-supplied id straight into `~/.openflix/<kind>/<id>.json`, so `../`
  escaped the directory. Identifiers are now validated on tool arguments and
  templated resource reads.
- **`batch` billed you before it validated.** Items ran in parallel and each was
  checked at submit, so a bad duration on item 7 surfaced *after* items 0–6 had
  been sent to providers and charged. Every item is now validated before any is
  submitted.
- **Duration is refused honestly everywhere, not just on `generate`.**
  `batch` / `recipe` / `project` / `workflow` / scatter / MCP silently
  normalised an impossible value instead of refusing it; the invariant now lives
  at `GenerationEngine.submit`, which every spend path goes through.
- **Reference images with spaces or `%` were dropped silently.** `URL(string:)`
  returned nil before the "local images are never uploaded" refusal could fire,
  so the generation ran as text-to-video and was billed. It now refuses with a
  message, and remote URLs containing spaces are encoded rather than discarded.
- **Cost estimates could be fabricated or non-finite.** A nonexistent provider
  quoted a made-up $0.05; workflow cost estimation could overflow finite inputs
  to infinity, and non-finite math defeats budget gates (`NaN > limit` is false).
- **`project_run` claimed to execute a project and never did.** Its MCP
  description said "Execute a multi-shot project DAG" while it only returned the
  shell command to run. The description now says what it does; execution stays a
  deliberate `openflix project run <id>` because it spends money per shot.
- **`--timeout` could abort the process after a generation was already billed.**
  `Int(Double)` traps on a non-finite value, and this one ran on the timeout
  path — losing the record of something the user had paid for.
- **Replicate advertised image-to-video and never sent an image.** A user who
  attached a reference image had it silently discarded and was billed for a
  text-to-video generation that ignored their input. The flag is now honest;
  implementing it needs Replicate's per-model `input` schema, which differs by
  model. Every other provider that claims the capability does send the image.
- Scatter/gather no longer nominates targets for an impossible shot length;
  ComfyUI graph rendering no longer traps on a non-finite duration.

### Internal
- Tests: **186 → 392** unit, **216 → 231** end-to-end. `MCPServer` and
  `DAGExecutor` had zero coverage and now have real coverage of the abort,
  deadlock and empty-input classes this project has been bitten by before.
- A cross-repo tripwire in `test.sh` pins the on-disk generation-record keys the
  macOS app reads, including a `CodingKeys` check — an encoder change would
  otherwise break `openflix://generation/<id>` deep links silently.

## [1.0.2] — 2026-08-06

The demo-readiness release. Nothing here changes the API surface; all of it is
"the first five minutes on a stranger's Mac now tell the truth".

### Fixed
- **Smart-routing fallback no longer picks the unrunnable placeholder.** On a
  machine with provider keys but no preference data, `--route smart` fell
  through to the cheapest option — which is the $0 local ComfyUI entry, and
  ComfyUI is not installed on a fresh Mac. It now prefers a provider you
  actually hold a key for, and only lands on `local/comfyui` when that is
  genuinely all there is.
- **`openflix quickstart`'s first command now runs.** The printed `recipe init`
  invocation was missing the required provider/model, so the very first thing a
  new user pasted failed. The keyless-machine hint appears when there are no
  keys, and the publish step says a write token is needed instead of failing
  with a bare 401.
- **`openflix vote` returns machine-readable JSON when the registry is
  unreachable**, so an agent driving the CLI sees a structured error instead of
  prose on stderr.
- **`openflix keys set` rejects unknown providers.** It used to accept any
  string and store a key nothing would ever read, which surfaced later as an
  inexplicable "no API key" during generation.

### Docs
- New `docs/mcp-quickstart.md`: the real `claude mcp add` command, all 15 tools,
  and `submit_vote` + `route:"smart"` shown as first-class.
- README first-run path corrected; dead links removed; `quickstart`, `vote` and
  `mcp` documented.

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
