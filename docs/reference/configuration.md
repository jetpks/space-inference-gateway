# Reference: configuration

Every knob the gateway reads, and where. There are two configuration
surfaces: environment variables (process-level) and `config/models.yml`
(the model registry).

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `PORT` | `3001` | gateway listen port (production sets `9292` — the only var set there) |
| `ADVERTISED_MODEL` | `local-inference` | `model` echoed in responses when the request's alias isn't in the registry |
| `MODEL_CONFIG_PATH` | `config/models.yml` (in the gem) | registry file location |
| `ENGINE_LOG_DIR` | `~/Library/Logs/space-inference-gateway` | per-alias engine child logs (`<alias>.log`) — deliberately not a tmpdir, so crash forensics have somewhere stable to look |
| `ZOMBIE_RESTART_THRESHOLD` | `2` | consecutive no-response generation failures before the watchdog restarts the child |
| `UPSTREAM_IDLE_TIMEOUT` | `1400` (s) | per-socket-operation idle gap to the engine; resets on every read/write, so a stream that keeps emitting never times out |
| `UPSTREAM_HEADERS_TIMEOUT` | `300` (s) | wall-clock bound on waiting for response headers when opening a stream |
| `UPSTREAM_BUFFERED_TIMEOUT` | `1800` (s) | end-to-end deadline for a buffered (non-streaming) call; independent of the streaming idle-gap above |

Fixed constants worth knowing (not env-tunable): SSE keepalive comments after
**8 s** of upstream silence (`App::KEEPALIVE_INTERVAL`, chosen well under
pi's 300 s idle timeout); supervisor timeouts below.

## The model registry

```yaml
default: qwen3-27b-optiq   # served when a request names no known alias and nothing is running

models:
  <alias>:                 # what clients send, what /v1/models lists
    engine: mlx | optiq    # which child the supervisor spawns
    model: <HF repo id>    # passed to --model verbatim (never ~-expanded)
    port: 8080             # child's listen port
    venv: <path>           # mlx: python interpreter; optiq: the optiq binary
    supports_reasoning: true|false   # default true; false = normalizer passthrough
    stop_tokens: [<str>, …]          # merged into every request's stop field
    extra_args: [<str>, …]           # appended verbatim to the child argv
    readiness_timeout: <seconds>     # per-model readiness budget; default 120
    # mlx only:
    decode_concurrency: <int>
    prompt_concurrency: <int>
    prompt_cache_size: <int>
    # optiq only:
    mtp: true|false
    mtp_depth: <int>
    max_concurrent: <int>
```

Path-valued keys (`venv`, plus legacy `gguf`/`binary`) get `~` expanded to an
absolute path — argv goes straight to exec, which never expands a shell `~`.
`model` is deliberately **not** expanded: it's an HF repo id (or local path)
that must pass through verbatim.

`supports_reasoning: false` is for models whose chat template emits content
only (e.g. `hermes-4-70b`): it keeps the normalizer from misreading a literal
`<think>` in ordinary output. `stop_tokens` exists for the mlx_lm 0.31.3
eos-stop bug, and `readiness_timeout` for ≥100B models the flat 120 s budget
would kill mid-load (the registry sets 300 s on `qwen3-122b-a10b` and
`nemotron-3-super`) — see [add & tune models](../how-to/add-and-tune-models.md).

## How the engine command line is built

mlx (`venv` is a Python interpreter):

```
<venv> -m mlx_lm.server --model <model> --host 127.0.0.1 --port <port>
       [--decode-concurrency N] [--prompt-concurrency N] [--prompt-cache-size N] <extra_args…>
```

optiq (`venv` is the optiq binary):

```
<venv> serve --model <model> --host 127.0.0.1 --port <port>
       [--mtp [--mtp-depth N]] --no-auth [--max-concurrent N] <extra_args…>
```

Children always bind loopback. stdout+stderr append to
`$ENGINE_LOG_DIR/<alias>.log`.

## Supervisor timeouts, and the zombie watchdog

`InferenceServerSupervisor::Timeouts.default` — not env-configurable;
override by constructing a `Timeouts` in tests:

| | Default | Meaning |
|---|---|---|
| `readiness` | 120 s | max wait for the child's `/health` to answer 200 after spawn; expiry → the child is stopped and the load fails 504. Overridable per model via `readiness_timeout:` |
| `stop_grace` | 5 s | after TERM, before escalating to KILL (signals go to the whole process group — `async-process` spawns with `pgroup: true` and kills `-pid`) |
| `kill_grace` | = `stop_grace` | post-KILL reap wait, and the wait for the port to be confirmed released |
| `probe_timeout` | 5 s | connect+read bound on a single `/health` or port-liveness check — no probe can park the readiness loop (or a swap holding the semaphore) indefinitely |
| `poll_interval` | 0.5 s | poll cadence for readiness and the bounded waits above (raw `TCPSocket`, fiber-friendly) |

Stops are **verified**: TERM, bounded wait; KILL if still running, bounded
wait; then the port itself is confirmed released — not just that the child
object believes itself dead. A successor is only spawned once its port is
verified free, so readiness can never be satisfied by a still-alive
predecessor. On the first spawn to a given port, the supervisor also reaps
any pre-existing listener there (via `lsof`, engine-agnostic, once per port
per process) — covering a prior gateway's orphaned engine child after a
crash-restart.

**Zombie watchdog** (request-path): a wedged engine child can accept TCP and
still answer `/health`, but never write a generation response — its generate
thread died. So the watchdog counts request-path evidence, stream-agnostic:
a streaming open that times out before headers, or a buffered call that
times out with no response, is a strike; any real response (any status,
either path) resets the streak. At `ZOMBIE_RESTART_THRESHOLD` consecutive
strikes the active child is restarted (bypassing the 409-busy guard — a
zombied child dooms in-flight generations anyway). Restarts appear in
`sig_child_zombie_restarts_total`.

## Process and file layout (production)

| Path | What |
|---|---|
| `~/src/space-inference-gateway` | runtime checkout (Ansible-managed) |
| `~/src/space-inference-gateway/run-gateway.sh` | launchd launcher (templated; sets `PORT=9292`) |
| `~/Library/LaunchAgents/com.slushsystems.space-inference-gateway.plist` | gateway launchd agent |
| `~/Library/Logs/space-inference-gateway.log` | gateway stdout/stderr |
| `~/Library/Logs/space-inference-gateway/<alias>.log` | engine child logs |
| `~/.venv-optiq`, `~/.venv-vllm-metal` | engine venvs (paths matched by `models.yml`) |
| `~/.cache/huggingface/hub` | model artifacts |

## Boot path

Production runs `bundle exec ruby bin/space-inference-gateway` — Falcon
embedded, not `falcon serve`:

```ruby
server = Falcon::Server.new(Falcon::Server.middleware(app, cache: false), endpoint)
```

`cache: false` is load-bearing: `Async::HTTP::Cache::General` would replay
cacheable GETs (`/v1/models`, `/v1/load-progress`) with an empty body. The
bin traps SIGTERM/SIGINT and tears the engine child down before exit
(`App#shutdown`), so a gateway restart doesn't orphan a ~tens-of-GB engine
process. A `config.ru` exists for rack-compatible tooling but is not the
production path.

## Component map

| Class | Job |
|---|---|
| `App` | Rack seam: routing, request rewrites, ANT→OAI translation, error mapping, stream lifecycle |
| `ModelRegistry` | loads `models.yml`, resolves aliases, `~`-expands path keys |
| `ModelController` | single-flight engine transitions (one `Async::Semaphore(1)` gate makes the active/busy check, swap, and generation reservation atomic), busy-409 policy, zombie-strike accounting |
| `InferenceServerSupervisor` | spawn/stop/swap the engine child; readiness gate; verified kill + port-release confirmation; stale-listener reap |
| `UpstreamClient` | async-http client with idle + headers timeouts |
| `OaiNormalizer` / `AntNormalizer` | strict-schema output conformance; reasoning lifting; OAI→ANT synthesis (non-stream + SSE) |
| `ReasoningParser` | streaming-safe `<think>` extraction (holds back partial tags across chunk boundaries) |
| `ErrorRelay::Oai` / `::Mlx` | upstream error relay per client flavor; `Mlx` reshapes string-shaped errors (`Oai` retained for a future true-OAI upstream) |
| `Schemas` | dry-schema output contracts (plus the hand-rolled ANT key check that tolerates arbitrary `tool_use.input`) |
| `Metrics` / `GenerationObserver` | Prometheus registry; per-generation phase/TTFT/usage taps ([metrics reference](metrics.md)) |
