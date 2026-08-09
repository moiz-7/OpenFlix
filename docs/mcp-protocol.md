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
| `cancel_generation` | false | **true** | false | true |
| `generate_poll` | false | false | true | true |
| `evaluate_quality` | false | false | false | true |
| `submit_vote` | false | false | true | true |
| `submit_feedback` | false | false | false | **false** |
| `list_generations`, `get_generation`, `list_providers`, `get_metrics`, `budget_status`, `health_check`, `project_run` | **true** | — | — | **false** |

MCP has no "costs money" hint, and a client uses `destructiveHint` to decide
whether to ask the human first. Marking a tool that charges the user
`destructiveHint: false` would make it **less** guarded than it is today, so
every tool that spends keeps the pessimistic value on purpose.

`destructiveHint` and `idempotentHint` are meaningful only when `readOnlyHint` is
false, so read-only tools do not ship them at all.

`submit_feedback` is `openWorldHint: false` and `submit_vote` is
`openWorldHint: true` — the wire now says which of the two leaves the machine,
which is the whole difference between them.

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
