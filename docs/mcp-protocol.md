# MCP protocol support — `openflix mcp`

`openflix mcp` is **dual-era**. It speaks the current stateless revision and the
handshake-based one that every MCP client in the wild uses today, on the same
stdio pipe, with no configuration.

## Why this exists

MCP `2026-07-28` did not add statelessness as an option — it **removed the
session from the protocol core**. There is no `initialize`/`initialized`
handshake and no session id. Every request carries its own protocol version,
client identity and client capabilities in `_meta`; a server advertises itself
through a `server/discover` RPC; every result carries a `resultType`
discriminator.

That revision's own compatibility matrix:

| Client | Server | Outcome |
|---|---|---|
| Modern | Legacy | **Fails** |
| Legacy | Modern | **Fails** |
| Dual-era | either | Works |
| either | Dual-era | Works |

"Fails" there is not a clean error. The spec says a legacy server "may reject the
request …, stay silent, or even process an era-ambiguous method under legacy
semantics".

`openflix mcp` used to be the Legacy row, and this is the server that exposes
`generate`, `generate_submit` and `retry_generation` — the one that spends the
user's own provider credit. The OpenFlix **app**'s MCP server refuses generation
by name and points agents here. So a modern-only client would have found the
read-only half of the product working and the half that actually creates video
silently unavailable.

## Revisions served

Newest first:

| Revision | Why it is on the list |
|---|---|
| `2026-07-28` | Current. Stateless core, `server/discover`, per-request `_meta`, `resultType`, `-32022`. |
| `2025-06-18` | Introduced `structuredContent`, `outputSchema` and tool `annotations` — all three of which this server now emits, which is what makes claiming it honest rather than decorative. |
| `2024-11-05` | What `openflix mcp` shipped with. A client pinned to it is a client that works today. |

The list is deliberately short. `2025-11-25` and `2025-03-26` are real revisions
whose behaviour has not been verified here, so they are not claimed — claiming a
revision you have not read is how a client ends up with a subtly wrong answer
instead of an honest `UnsupportedProtocolVersionError`.

## The modern path — no handshake

A modern client may open the pipe and immediately probe:

```json
{"jsonrpc":"2.0","id":1,"method":"server/discover",
 "params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities":{}}}}
```

and gets back `supportedVersions`, `capabilities`, `serverInfo`, `instructions`,
plus `ttlMs` / `cacheScope: "private"` — every byte here is one person's keys,
spend and work, so `private` is the only honest cache scope.

Every subsequent request repeats `_meta` (there is no session to hold it), and
every result carries `"resultType":"complete"`.

Naming a revision this server does not serve fails with the error the spec
designed for it, carrying the list to retry with:

```json
{"jsonrpc":"2.0","id":5,
 "error":{"code":-32022,"message":"Unsupported protocol version",
          "data":{"requested":"1900-01-01",
                  "supported":["2026-07-28","2025-06-18","2024-11-05"]}}}
```

The check runs before dispatch, so it is not something a client can slip past by
picking a different method.

## The legacy path — unchanged

`initialize` works exactly as it always has. The version echoed back is the one
the client asked for when we serve it, and `2024-11-05` otherwise — including
when the client asks for something we have never heard of, because a legacy
handshake must never fail with a modern error code. `notifications/initialized`
is accepted and answered with silence, as JSON-RPC requires.

Both eras work on one session: a dual-era client may probe with
`server/discover`, fall back to `initialize`, and neither path disturbs the
other. Era is decided **per request**, which is the only way it can be decided
when there is no session to hold the answer.

## What is deliberately not implemented

- **Streamable HTTP.** The spec's transports page says a custom transport over a
  reliable byte stream **SHOULD** reuse the stdio framing rather than define a
  new one — which is exactly what is on this wire. `openflix mcp` is a child
  process of the agent; adding an HTTP listener would add a port, an auth scheme
  and reachability by every process on the machine, and buy a horizontal-scaling
  property a per-user CLI cannot use.
- **Multi Round-Trip Requests / elicitation.** MRTR exists so a server can ask
  the client for input without a session. This server has nothing to ask: keys
  come from the Keychain and the one consent decision that matters — how much may
  be spent — is `openflix budget set`, a deliberate human act, not something an
  agent should be able to prompt its way past mid-call.
- **Sampling and roots.** Both deprecated in this revision. Sampling would also
  invert the trust model: it lets a server drive the caller's model.
- **Logging (the MCP capability).** Deprecated in this revision (SEP-2577).
  `openflix`'s own logging covers the operability need.
- **Pagination.** Every list is bounded by construction: 15 tools, 3 resources,
  ≤52 prompts. The genuinely unbounded space — every generation and every recipe
  on the machine — is reached through **resource templates**, which is what they
  are for.
- **`notifications/*/list_changed` and resource subscriptions.** They need the
  client to hold a `subscriptions/listen` stream, and buy one avoided re-list on
  a pipe where re-listing costs nothing. `listChanged` is therefore **not
  advertised** either, so no client is told to wait for a notification that never
  arrives.

## Tool annotations

Every tool is annotated, because **two of the four `ToolAnnotations` schema
defaults are the pessimistic value**: an unannotated tool is assumed
`destructive` and `openWorld`. Before this, `list_providers` (a lookup in a
built-in price table) and `generate` (an irreversible charge against the user's
provider account) were indistinguishable to a client.

The direction that matters is *not* "declare everything false":

| Tools | `readOnlyHint` | `destructiveHint` | `idempotentHint` | `openWorldHint` |
|---|---|---|---|---|
| `generate`, `generate_submit`, `retry_generation` | false | **true** | false | true |
| **`project_run`** | false | **true** | false | true |
| `cancel_generation` | false | **true** | false | true |
| `generate_poll` | false | false | true | true |
| `evaluate_quality` | false | false | false | true |
| `submit_vote` | false | false | true | true |
| `submit_feedback` | false | false | false | **false** |
| `list_generations`, `get_generation`, `list_providers`, `get_metrics`, `budget_status`, `health_check` | **true** | — | — | **false** |

MCP has no "costs money" hint, and a client uses `destructiveHint` to decide
whether to ask the human first. Marking a tool that charges the user
`destructiveHint: false` would make it **less** guarded than it is today, so
every tool that spends keeps the pessimistic value on purpose.

`project_run` is the sharpest case. Its **default** behaviour is a free, local
dry run — but a client reads `annotations` from `tools/list`, long before it
knows what arguments will be passed, so the only honest hint is the tool's
**worst case**: one irreversible charge per shot, across a whole graph. Softening
it because "most calls are safe" would make the tool that can spend the most on
this server the least guarded one.

`destructiveHint` and `idempotentHint` are meaningful only when `readOnlyHint` is
false, so read-only tools do not ship them at all.

`submit_feedback` is `openWorldHint: false` and `submit_vote` is
`openWorldHint: true` — the wire now says which of the two leaves the machine,
which is the whole difference between them.

## `project_run` — the one tool that spends across a whole graph

`project_run` executes a project's DAG of shots. It is the most consequential
tool on either server: `generate` charges once, this charges **once per shot**,
in dependency order, on the user's own provider credit.

It used to look the project up and tell you to use the shell. A tool named
`project_run` that does not run is exactly the gap an agent trips over, so it
runs — behind a shape designed for a caller that is a language model in a loop.

### Two arguments, both deliberate

| Call | What happens |
|---|---|
| `{"project_id": "…"}` | **Spends nothing.** Returns a plan. |
| `+ "confirm": true` | Refused — `cost_ceiling_required`, carrying the estimate. |
| `+ "confirm": true, "max_cost_usd": N` | Executes, held to `N`. |

The default is the safe one, so the cheapest thing an agent can do is find out
the price. Executing needs **two** arguments, and one of them is a number the
caller had to form an intention about. `confirm` alone is not enough precisely
because a boolean is the easiest thing in the world to set to `true`.

`max_cost_usd` is not ceremony. It is enforced twice:

1. **Before anything is submitted** — if the plan's estimate exceeds it, the run
   is refused and the reply carries both numbers.
2. **During the run** — it is handed to `DAGExecutor` as a cost budget, so it
   also stops dispatch once *billed* spend reaches it. An estimate is a guess;
   the provider's invoice is not.

It can only ever **narrow**. The project's own `costBudgetUSD` still applies
(the gate takes whichever is tighter), and `BudgetManager`'s daily, monthly and
per-generation limits still apply underneath, at `GenerationEngine.submit`.
Nothing an agent can pass raises a limit.

### What the plan contains

Everything needed to decide, and nothing that costs anything to produce:

- the provider and model **each shot would actually be dispatched to** — through
  `DAGExecutor.plannedTarget`, the same function the executor uses, so a plan
  cannot quote one model and run another;
- the per-shot and total estimate, with `candidates` > 1 where fanout or
  scatter-gather bills more than once;
- **which shots would be refused locally, and why** — the free, deterministic
  half of `GenerationEngine.submit`'s pre-flight, replayed: unknown provider,
  missing key, a `file://` reference image, an impossible duration, a blocked
  prompt. Knowing shot 5 is doomed *before* shots 1-4 are billed is the whole
  point. (The pre-generate hook is deliberately **not** run — it is a user
  program with side effects, and a plan must not trip it.)
- the current budget, so the estimate and the limit arrive together;
- `caveats`, naming what the estimate does not capture;
- `next_step`: the literal JSON to send to execute.

`executed` is the first key in every reply and is `false` for a plan. A model
skimming the result cannot mistake one for the other.

### What the client sees during a long run

A DAG of N shots takes minutes, and a `tools/call` that blocks silently for ten
of them is its own bug. Three things address it:

- **`notifications/progress`**, one per node reaching a terminal state, carrying
  `progress`/`total` and a message naming the shot, its status and the cost
  billed so far. It is emitted **only when the client puts a `progressToken` in
  the request's `_meta`**, which is what the spec requires and what makes adding
  it a no-op for every client that exists today. The notifications are written
  under the same lock as responses — the newline is the framing on this
  transport, and an interleaved write would be unrecoverable.
- **A run journal, always.** `run_id` is in the reply and the file is at
  `~/.openflix/runs/<run_id>.json`, written incrementally per node. It survives
  a crash, a disconnect and a timeout.
- **A wall-clock bound.** `timeout_seconds` (default 900, max 3600) stops
  dispatch and returns what completed. It **pauses** rather than cancels,
  because a paused project is resumable and a cancelled one is refused by the
  status gate — timing out must never be the thing that strands a run. The
  per-shot poll timeout is capped to the remaining budget so one shot cannot
  consume the whole call.

Honest limitation: while a tool call is executing, the server is not reading
stdin, so a `notifications/cancelled` sent mid-run is not seen until the call
returns. `timeout_seconds` is the bound that actually exists. And a client that
sends no `progressToken` sees nothing until the reply — inherent to a blocking
request/response call.

### Partial failure is the normal case

Shot 3 of 7 fails; 4-7 are downstream of it. The reply says so:

- `status` is the project's — `partial_failure`, `failed`, `paused`. `succeeded`
  requires zero failures; a run in which everything failed is never reported as
  a success.
- counts for succeeded / failed / skipped / pending, plus **every** shot with its
  provider, model, generation id, `openflix://generation/<id>` URI, cost and
  error — not just the failures.
- `actual_cost_usd` against `cost_ceiling_usd`.
- `next_step`: what to fix and the exact resume call.

`resume: true` resets three groups back to pending — shots left `.dispatched`/
`.processing`/`.evaluating` by a dead run, `.failed` shots, and shots the drain
marked `.skipped` **with its own "Blocked by upstream failure" marker**. That
third group is easy to miss and expensive to get wrong: without it a resume
fixes shot 3, leaves 4-7 dead, and then reports `succeeded` because
`failed == 0`. Shots skipped for any other reason are left alone.

### Refusals are in-band

Every refusal above is a tool result with `isError: true` and a JSON body naming
the `error` code and the numbers to build the corrected call — not a JSON-RPC
`error`. That layer is for protocol failures, which a client may treat as a
transport problem; "I will not spend your money without a cost ceiling" is a
result the model must read and act on.

### What it does **not** do

It adds no path to a provider. Execution is `DAGExecutor` → `GenerationEngine.submit`,
where the budget pre-flight, the prompt-safety check, the reference-image rule
and the pre/post-generate hooks live. There is no second route, and the plan
reaches nothing at all.

## Structured results

Tools that return a record declare an `outputSchema` and return
`structuredContent` alongside the existing text block, so a result is chainable
rather than prose an agent has to re-parse. The text block stays for clients that
never learned to read the typed one.

## Resources

Three fixed resources plus two templates:

```
openflix://providers
openflix://metrics
openflix://budget
openflix://generation/{id}      ← also a clickable openflix:// deep link
openflix://recipe/{id}          ← also a clickable openflix:// deep link
```

The two templates use the same `openflix://` grammar the OpenFlix app accepts as
a deep link, so one string is simultaneously a resource an agent can
`resources/read` and a link a human can click to open the record in the app.

Ids are validated (`[A-Za-z0-9._-]`, no leading dot, ≤128) **before** they reach
the stores, which resolve an id straight into `~/.openflix/<kind>/<id>.json`. An
id arriving over MCP is a string a model chose, possibly while reading someone
else's text; real ids are UUIDs, so nothing legitimate is refused.

## Prompts — your recipes, as slash commands

Every saved `.openflix` recipe is exposed as an MCP prompt. The mapping is
one-to-one, because a recipe already *is* a prompt template with typed arguments:

| Recipe | MCP prompt |
|---|---|
| `promptText` with `{{name}}` placeholders | the rendered message |
| `RecipeArg.name` / `.description` | `PromptArgument.name` / `.description` |
| `RecipeArg.default` **absent** | `PromptArgument.required == true` |
| `RecipeArg.choices` (enum) | `completion/complete` values |
| recipe `name` | prompt `title` (identifier stays `recipe_<id>`, stable across renames) |

Plus two built-ins: `compare_providers` (generate the same prompt on two
providers, cost-check first, then feed the winner back through `submit_vote`) and
`budget_check`.

Substitution goes through **the kit's** `RecipeArgResolver.substitute`, not a
second implementation. That resolver is single-pass on purpose: a per-key loop
rescanned already-substituted text, so an argument *value* containing
`{{other}}` was expanded or not depending on dictionary order. An agent supplies
those values, so single-pass is an anti-injection property and this is precisely
the path that must not fork.

**Rendering a prompt never submits anything.** It returns the text a generation
would use, with the note that submitting means calling `generate`, which spends
real money and is budget-checked first. Every path that reaches a provider goes
through `GenerationEngine.submit`, where the budget pre-flight, the prompt-safety
check, the reference-image rule and the pre/post-generate hooks live.
