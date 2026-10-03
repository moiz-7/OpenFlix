# Let an agent on another machine use OpenFlix: the HTTP bridge

`openflix mcp` serves an agent on **this** Mac over stdio. The bridge is for an
agent somewhere else: a home server, a Mac mini running an assistant, anything
on your tailnet that speaks HTTP and JSON.

```
agent (another machine) ──HTTPS over your tailnet──▶ tailscale serve ──▶ openflix serve (127.0.0.1)
                                                                             │
                                                            the running app ◀┘ (its own socket, if enabled)
```

It also speaks MCP (Streamable HTTP) at `/mcp` for agents such as OpenClaw and
Hermes, with spending as two tool calls (`request_spend`, then `confirm_spend`);
see [`agent-integrations.md`](agent-integrations.md).

The bridge offers the same actions, with the same argument validation, as
`openflix mcp` and `openflix action run`. It also relays the running app's
library and player tools, when the app allows it.

## 1. Give the agent a grant

```bash
openflix agents grant harbor --effects read,refresh,control
```

This prints a token **once**. Store it in the agent's own secret store, such as
macOS Keychain, never in a file or a prompt. Only a SHA-256 of it is kept here,
in `~/.openflix/agents.json` (`0600`).

A grant allows actions by **effect**, so "may look things up" and "may spend
money" are separate decisions:

| Effect | What it covers |
|---|---|
| `read` | Library search, generations, budget, providers, metrics |
| `refresh` | Polling a generation that was already paid for |
| `control` | Driving the app's player (play, pause, seek, open) |
| `local_write` | Local quality scores |
| `destructive` | Cancelling a generation |
| `spend` | Starting paid generations. Needs `--daily-cap` |
| `share` | Sending a vote to the community registry |

To let it spend up to $5 a day:

```bash
openflix agents grant harbor --effects read,refresh,control,spend --daily-cap 5
```

`openflix agents list` shows every grant and what each has spent today.
`openflix agents revoke harbor` stops its token immediately. Granting the same
name again replaces the token.

## 2. Run the bridge, and put your tailnet in front of it

```bash
openflix serve                                   # listens on 127.0.0.1:18790 only
tailscale serve --bg http://127.0.0.1:18790      # HTTPS on your tailnet, not the internet
```

The bridge never listens on a network interface. Tailscale Serve handles TLS
and makes it reachable only from your own devices. Don't use Tailscale Funnel,
which would publish it to the internet.

## 3. Call it

Every route but `/v1/health` needs `Authorization: Bearer <token>`.

| Route | What it does |
|---|---|
| `GET /v1/health` | Liveness. No auth, says nothing private |
| `GET /v1/manifest` | The actions **this grant** may call, each with its JSON Schema, effect, MCP annotations and host (`openflix-cli` or `openflix-app`) |
| `POST /v1/actions/<name>` | Run one action. The body is a JSON object of arguments |
| `POST /v1/actions/<name>:preflight` | Quote a spending action (see below) |

```bash
curl -s -H "Authorization: Bearer $TOKEN" https://your-mac.tailnet.ts.net/v1/manifest
curl -s -H "Authorization: Bearer $TOKEN" -X POST \
     --data '{"query":"they land on the beach"}' \
     https://your-mac.tailnet.ts.net/v1/actions/library_search
```

Every answer uses one envelope (`openflix.action_result.v1`):

```json
{"contract":"openflix.action_result.v1","action":"library_search","status":"ok","data":{…}}
{"contract":"openflix.action_result.v1","action":"…","status":"refused",
 "error":{"code":"GRANT_DENIED","class":"policy","message":"…","retryable":false}}
```

`refused` means nothing was attempted, and the call can be corrected at no
cost. `failed` means it was attempted and something broke. The HTTP status
follows `error.class`:

| Status | Class |
|---|---|
| 400 | `invalid_input` |
| 403 | `policy` |
| 404 | `not_found` |
| 409 | `conflict` |
| 428 | `approval_required` |
| 429 | `rate_limited` |
| 502 | `upstream` |
| 503 | `unavailable` |

## 4. Spending: quote, approve, run once

Money never moves on a single call.

1. **Quote.** `POST /v1/actions/generate_submit:preflight` with the arguments.
   The answer names the provider, the model, the estimated cost and how much of
   today's cap is left, along with a single-use `op_hash` that expires in 15
   minutes. A `route: "smart"` request is resolved to a concrete provider and
   model here, so what you approve is what runs.
2. **Approve.** Your agent shows that summary to you and waits for a yes.
3. **Run.** `POST /v1/actions/generate_submit` with the **same arguments** and
   two headers:
   - `OpenFlix-Quote: <op_hash>`
   - `Idempotency-Key: <a new unique value>`

The bridge refuses to run a spend in each of these cases:
- No quote was given (428 `QUOTE_REQUIRED`).
- The arguments differ from the quoted ones (409 `QUOTE_MISMATCH`).
- The quote was already used, has expired, or was issued to another agent (409 `QUOTE_STALE`).
- Today's spending plus this call would pass the grant's cap (403 `AGENT_CAP_EXCEEDED`). The cap is checked at the quote **and** again at the run.

A retry with the same `Idempotency-Key` returns the first answer, with the
header `Idempotent-Replayed: true`, and never runs the spend twice.

Everything still passes the gates every generation passes: the prompt-safety
check, your OpenFlix budget, the reference-image rule, and your
`pre-generate` hook.

Available to remote agents:
- `generate_submit` (then poll with `generate_poll`)
- `retry_generation`

Not available to remote agents:
- `generate` blocks for minutes.
- `project_run` and `evaluate_quality` spend in ways one quote cannot cover.

## 5. The app's tools

When the OpenFlix app is running **and** agent access is on in its Settings
(Settings → AI Agents → Let an Agent Use OpenFlix), the bridge relays its tools
over the app's own socket. Those tools are `library_search`, `player_state`,
`player_control` and `generation_list`.

- The app's own setting still applies. At "Read only", `player_control` is
  refused by the app, whatever the grant says.
- `player_control` also needs the `control` effect in the grant.
- If the app is closed, its actions answer 503 `APP_UNAVAILABLE`, and the
  manifest says why.
- Titles, file names and transcript lines come from your media, not from
  OpenFlix. Every app action is marked `returns_untrusted_text: true`, so an
  agent treats that text as data, not instructions.

## 6. What it will not do

- **Listen on the network.** It uses `127.0.0.1` only. Reaching it from another
  machine takes a tunnel you chose.
- **Answer a browser.** A request carrying an `Origin` header gets 403, so a web
  page cannot drive it.
- **Store or log tokens, prompts or arguments.** The bridge logs one metadata
  line per request (agent, action, status) to `~/.openflix/logs/openflix.log`.
- **Spend without a quote, or past a cap.** See §4.
