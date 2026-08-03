# Phase 3 Waves 2+3 (CLI half): Local ComfyUI Provider + Workflow Publish/Import

## Task 1 — Local/open-model provider (zero marginal cost)

New kit provider `ComfyUIClient` (`Sources/OpenFlixKit/ComfyUIClient.swift`), provider id
`local`, model id `comfyui`, implementing the kit's `VideoProvider` protocol (mirrors
`ReplicateClient`).

- **API:** `POST {base}/prompt` with `{"prompt": <graph>, "client_id": <uuid>}` →
  `{"prompt_id"}`; poll `GET {base}/history/{prompt_id}` (empty dict = still running);
  download `GET {base}/view?filename=&subfolder=&type=` (videos > gifs > images,
  deterministic node order).
- **Graph template:** JSON string with `{{prompt}}`, `{{negative_prompt}}`, `{{seed}}`,
  `{{duration}}` placeholders. Substitution is dumb string replace after JSON-escaping
  (`renderGraph`, pure + unit-tested). CLI loads `~/.openflix/comfyui-graph.json` when
  present; the built-in default is a clearly-marked placeholder graph
  (`REPLACE_THIS_PLACEHOLDER_GRAPH`) — video graphs are rig-specific, so users export
  theirs via ComfyUI "Save (API Format)".
- **Base URL:** env `OPENFLIX_COMFYUI_URL`, default `http://127.0.0.1:8188` — wired in the
  CLI's `ProviderRegistry.init` (the kit stays Foundation-only and env-free).
- **Keyless:** `CLIKeychain.keylessProviders = ["local"]`; `resolveKey` early-returns `""`
  — the single choke point all generation paths use (generate, batch, projects, workflows,
  dry-run). `health` and `keys list` report `"keyless": true`.
- **Pricing:** `comfyui: 0.0` in `ModelPricing.costPerSecondUSD` + `local: 0.0` provider
  fallback → estimates are $0 everywhere; budget pre-flight is skipped at $0.
- **Seed:** from `extraParams["seed"]`, else random per submit (fanout candidates differ).

## Task 2 — Workflow publish/import (registry contract)

Two new subcommands in the `workflow` group (`Sources/openflix/Commands/WorkflowCommand.swift`)
plus `RegistryClient` additions, coded against the Wave 2 registry contract (incl. the
addendum: publish response `{id, url}`, download-credit endpoint).

- **`workflow publish <file.json> [--name --description --token]`** — validates the file
  with `WorkflowParser.parse` (identical rules to `workflow run`) BEFORE any network call;
  `POST {registry}/api/workflows` `{"name", "description"?, "spec": {<file JSON>}}` with
  Bearer token via `RegistryClient.resolveToken`. Name defaults to the spec's `name`.
  Output: `{"id", "url", "name", "stage_count"}` (server `url` preferred, constructed
  fallback).
- **`workflow import <id-or-full-url> [--output --force]`** — `WorkflowRegistryRef.resolve`
  accepts a bare id, `…/workflows/<id>`, or `…/api/workflows/<id>` (full URLs pin the
  host); `GET {base}/api/workflows/{id}`; fire-and-forget `POST …/{id}/download` credit
  (5s timeout, never fails the import); validates the fetched `spec` locally; saves to
  `--output` or sanitized `<name>.workflow.json`; refuses overwrite without `--force`
  (`file_exists`). Output: `{"id", "name", "saved_path", "stage_count"}`.
- **Structured errors:** `file_not_found`, `invalid_workflow_ref`, `fetch_failed`,
  `file_exists`, `write_failed`, `publish_failed`, plus all spec-validation codes
  (e.g. `empty_stages` locally before any network).

## Files changed

| File | Change |
|------|--------|
| `Sources/OpenFlixKit/ComfyUIClient.swift` | NEW — ComfyUI VideoProvider (template render, submit, pure `parsePollStatus`) |
| `Sources/OpenFlixKit/ModelPricing.swift` | `comfyui: 0.0` model entry + `local: 0.0` provider fallback |
| `Sources/openflix/Core/CLIKeychain.swift` | `keylessProviders` set + `resolveKey` short-circuit |
| `Sources/openflix/Providers/ProviderProtocol.swift` | Register ComfyUIClient (env base URL + `~/.openflix/comfyui-graph.json` template) |
| `Sources/openflix/Commands/HealthCommand.swift` | Keyless providers report `configured: true, keyless: true` |
| `Sources/openflix/Commands/KeysCommand.swift` | `keys list` marks keyless providers |
| `Sources/openflix/Core/RegistryClient.swift` | `publishWorkflow`, `fetchWorkflow`, `creditWorkflowDownload` |
| `Sources/openflix/Commands/WorkflowCommand.swift` | `WorkflowPublish`, `WorkflowImport`, pure `WorkflowRegistryRef` helpers |
| `Tests/OpenFlixKitTests/ComfyUIClientTests.swift` | NEW — 14 tests (render/escape, poll fixtures, $0, catalog, default template) |
| `Tests/openflixTests/WorkflowRegistryTests.swift` | NEW — 8 tests (ref parsing, output name, name defaulting, validation gate) |
| `test.sh` | +6 smoke tests (199–204): local listed, local dry-run keyless $0, publish/import commands, offline error paths |
| `README.md` | Provider table row: Local (ComfyUI), $0, keyless + setup note |
| `docs/workflows-engine.md` | New "Publishing & importing workflows" section |

## Test results (gauntlet)

| Gate | Baseline | After Task 1 | After Task 2 (final) |
|------|----------|--------------|----------------------|
| `swift build` warnings | 0 | 0 | 0 |
| `swift test` | 106 | 120 | **128** (33 kit + 95 CLI), 0 failures |
| `bash test.sh` | 205 | 207 | **211**, 0 failures |

No live provider/network calls in any test: kit tests use canned JSON fixtures; test.sh
smoke tests use `--dry-run` and unreachable-registry env (`http://127.0.0.1:1`).

## Handoff notes

- The default ComfyUI graph template is intentionally NOT runnable — submitting it makes
  ComfyUI reject the `REPLACE_THIS_PLACEHOLDER_GRAPH` node with a clear error. Real use
  requires `~/.openflix/comfyui-graph.json`.
- `parsePollStatus` treats `status_str == "error"` as failed even before `completed`
  flips; empty history dict = still running (ComfyUI semantics).
- `local` shows `configured: true` in `health` but `all_providers_configured` still
  reflects the keyed providers only (keyless is skipped, not counted as missing).
- Registry-side 422s surface as `http_error` with the server's
  "Invalid workflow spec: stages[i]: …" detail in the message.
- Publish does not send a client-generated `id` (the contract's optional top-level `id`
  + 409 duplicate path is unused — server assigns ids; simplest wins).
