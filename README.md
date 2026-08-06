# space-inference-gateway

A small, fast **Falcon/async-Ruby gateway in front of local Apple-silicon
inference engines** (`mlx_lm.server` and `optiq`). It supervises the engine
process, swaps models on demand, and serves both **Claude Code** (Anthropic
`/v1/messages`) and **opencode** (OpenAI `/v1/chat/completions`) from a single
OpenAI-speaking upstream — synthesizing the Anthropic flavor itself, lifting
chain-of-thought onto the proper reasoning channel, and conforming output to
the strict schemas both clients parse.

```
Claude Code / opencode
   → 127.0.0.1:3001 loopback TLS shim     (laptop; Apple python3, TCC-exempt)
   → studio.slush.systems:443             (Caddy, Let's Encrypt cert, DNS-01/DigitalOcean)
   → space-inference-gateway :9292        (this gem — Falcon; OAI native, ANT synthesized)
   → mlx_lm.server / optiq serve :8080    (Apple-silicon engines; spawned & supervised)
```

The gateway is the box you build and run. Caddy and the loopback shim are
solved-problem infrastructure documented in the how-to guides.

## What it does

- **Supervises the engine** — spawn `mlx_lm.server` or `optiq serve` per
  registry entry → readiness-gate on `/health` → expose its base URL →
  TERM/KILL the process group on stop → serialized model swaps
  (`Async::Semaphore(1)`). No external orchestrator.
- **Two API flavors, one OpenAI upstream** — serves OpenAI
  `/v1/chat/completions` natively and **synthesizes** Anthropic `/v1/messages`
  (request translation including tools, streamed event synthesis) — the
  engines only ever see OpenAI HTTP.
- **Separated reasoning** — consumes mlx's `reasoning` field when present,
  else lifts inline `<think>…</think>` (split-tag-safe across SSE chunks) into
  OpenAI `reasoning_content` / Anthropic `thinking` blocks, gated per model by
  `supports_reasoning`.
- **Schema conformance** — output validates against strict OpenAI/Anthropic
  `dry-schema`s; engine quirks (mlx string-shaped errors, eos-stop bugs,
  `model`-field validation) are absorbed here, not in the clients.
- **A model control plane** — lazy auto-swap on the request's `model` field,
  plus explicit `GET /v1/models`, `POST /v1/load`, `POST /v1/unload`,
  `GET /v1/load-progress`; a friendly alias registry (`config/models.yml`);
  a zombie watchdog that restarts a wedged engine child.
- **Observability** — Prometheus `/metrics` (`sig_*` families: traffic,
  child health, generation phases, time-to-first-token, verbatim token usage)
  plus a Grafana dashboard under `deploy/observability/`.

## Stack

Modern async Ruby (`async`, `async-http`, `async-process`, `falcon`) + `dry-rb`
(`dry-schema`, `dry-monads`) + `prometheus-client`. Fibers, not threads.
Ruby ≥ 3.3 (4.0.5 in production). See
[`docs/explanation/architecture.md`](docs/explanation/architecture.md) for the why.

## Quick start (local dev)

```sh
bundle install
bundle exec rspec        # the suite
bundle exec rubocop      # the linter/formatter gate

# run it (needs an engine venv + model on this machine — see the tutorial)
PORT=3001 bundle exec ruby bin/space-inference-gateway
```

For an end-to-end first run (venv, model, gateway, a real request) start with
the **tutorial**.

## Documentation

Organized by the [Diátaxis](https://diataxis.fr) framework:

| If you want to…                                | Read                                                                        |
|------------------------------------------------|-----------------------------------------------------------------------------|
| Learn by doing — first end-to-end run          | [Tutorial](docs/tutorial.md)                                                |
| Install the dependencies (brew, mise, venvs)   | [How-to: install dependencies](docs/how-to/install-dependencies.md)         |
| Deploy on the studio (Ansible + launchd)       | [How-to: deploy on the studio](docs/how-to/deploy-on-the-studio.md)         |
| Point Claude Code / opencode at it             | [How-to: connect clients](docs/how-to/connect-clients.md)                   |
| Add a model or tune engine concurrency         | [How-to: add & tune models](docs/how-to/add-and-tune-models.md)             |
| Look up an endpoint, env var, or schema        | [Reference: HTTP API](docs/reference/http-api.md) · [Configuration](docs/reference/configuration.md) |
| Look up a metric or wire up scraping           | [Reference: metrics](docs/reference/metrics.md)                             |
| Understand the design and the trade-offs       | [Explanation: architecture](docs/explanation/architecture.md)               |
| See what's next                                | [ROADMAP](ROADMAP.md)                                                        |

## Status

Deployed and working: TLS-terminated, multi-flavor local inference that Claude
Code and opencode consume with no per-client workarounds. The gateway
supervises the engine child directly (optiq by default, mlx for the swap
aliases); nothing else is in the serving path.
