# space-inference-gateway

A small, fast **Falcon/async-Ruby gateway in front of a local `llama-server`
(llama.cpp)**. It supervises the model process, swaps models on demand, and
normalizes the upstream's output so that both **Claude Code** (Anthropic
`/v1/messages`) and **opencode** (OpenAI `/v1/chat/completions`) "just work" —
with chain-of-thought lifted into the proper reasoning channel and non-standard
fields stripped so strict client parsers don't choke.

```
Claude Code / opencode
   → 127.0.0.1 loopback TLS shim        (laptop; Apple python3, TCC-exempt)
   → inference.example.com:443           (Caddy, Let's Encrypt cert, DNS-01/DigitalOcean)
   → space-inference-gateway :9292       (this gem — Falcon; normalizes OAI + Anthropic)
   → llama-server                        (llama.cpp; spawned & supervised by the gateway)
```

The gateway is the box you build and run. Caddy and the loopback shim are
solved-problem infrastructure documented in the how-to guides.

## What it does

- **Supervises `llama-server`** — spawn → readiness-gate on `/health` (503→200)
  → expose its base URL → TERM/KILL the process group on stop → serialized
  model swaps (`Async::Semaphore(1)`). No external orchestrator.
- **Two API flavors, one upstream** — serves OpenAI `/v1/chat/completions` and
  Anthropic `/v1/messages`, streaming and non-streaming, from a single
  `llama-server`.
- **Separated reasoning** — consumes llama.cpp's native reasoning channel
  (`--jinja`): OpenAI `reasoning_content`, Anthropic `thinking` blocks. Falls
  back to lifting inline `<think>…</think>` (split-tag-safe across SSE chunks).
- **Schema conformance** — output validates against strict OpenAI/Anthropic
  `dry-schema`s; non-standard fields (`timings`, gguf-path `model`, empty
  `signature`, token-detail sub-hashes) are stripped.
- **A model control plane** — lazy auto-swap on the request's `model` field,
  plus explicit `GET /v1/models`, `POST /v1/load`, `POST /v1/unload`,
  `GET /v1/load-progress`; a friendly alias registry (`config/models.yml`).

## Stack

Modern async Ruby (`async`, `async-http`, `async-process`, `falcon`) + `dry-rb`
(`dry-schema`, `dry-monads`). Fibers, not threads. Ruby ≥ 3.3 (4.0.5 in
production). See [`docs/explanation/architecture.md`](docs/explanation/architecture.md)
for the why.

## Quick start (local dev)

```sh
bundle install
bundle exec rspec        # the suite
bundle exec rubocop      # the linter/formatter gate

# run it (needs a real llama-server + gguf on this machine — see the tutorial)
PORT=3001 bundle exec ruby bin/space-inference-gateway
```

For an end-to-end first run (model, gateway, a real request) start with the
**tutorial**.

## Documentation

Organized by the [Diátaxis](https://diataxis.fr) framework:

| If you want to…                              | Read                                                                        |
|----------------------------------------------|-----------------------------------------------------------------------------|
| Learn by doing — first end-to-end run        | [Tutorial](docs/tutorial.md)                                                |
| Install the dependencies (brew, mise, Caddy) | [How-to: install dependencies](docs/how-to/install-dependencies.md)         |
| Deploy on the studio under launchd           | [How-to: deploy on the studio](docs/how-to/deploy-on-the-studio.md)         |
| Point Claude Code / opencode at it           | [How-to: connect clients](docs/how-to/connect-clients.md)                   |
| Add a model or tune the context window       | [How-to: add & tune models](docs/how-to/add-and-tune-models.md)             |
| Look up an endpoint, env var, or schema      | [Reference: HTTP API](docs/reference/http-api.md) · [Configuration](docs/reference/configuration.md) |
| Understand the design and the trade-offs     | [Explanation: architecture](docs/explanation/architecture.md)              |
| See what's next                              | [ROADMAP](ROADMAP.md)                                                        |

## Status

Deployed and working: TLS-terminated, multi-flavor local inference that Claude
Code and opencode consume with no per-client workarounds. The gateway
supervises `llama-server` directly; nothing else is in the serving path.
