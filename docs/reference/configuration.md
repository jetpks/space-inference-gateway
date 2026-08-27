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
    engine: mlx | optiq | mlx-vlm    # which child the supervisor spawns
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
    # mlx-vlm only — environment-backed (no CLI flag on the child):
    apc_enabled: true|false
    apc_exact_cache_entries: <int>   # 2 x concurrent conversations
    thinking_budget: <int>           # max tokens inside a think block
    max_num_seqs: <int>              # continuous-batch width
    # mlx-vlm only — argv flags (see MlxVlmFlags::TUNING):
    enable_thinking: true|false
    draft_model: <HF repo id>
    draft_kind: dflash | eagle3 | mtp
    draft_block_size: <int>
    max_tokens: <int>
    prefill_step_size: <int>
    vision_cache_size: <int>
    max_kv_size: <int>               # tokens; see the caveat below
    kv_bits: <int>                   # and kv_key_bits / kv_value_bits
    kv_quant_scheme: uniform | turboquant   # and kv_key_scheme / kv_value_scheme
    kv_group_size: <int>
    quantized_kv_start: <int>
    thinking_start_token: <str>
    thinking_end_token: <str>
    # mlx-vlm only — applied by the gateway to the request, not the child:
    reasoning_effort: <str>              # default effort injected per request
    reasoning_effort_values: [<str>, …]  # what this model's template accepts
    preserve_thinking: true|false        # false drops reasoning_content from history
```

Path-valued keys (`venv`, plus legacy `gguf`/`binary`) get `~` expanded to an
absolute path — argv goes straight to exec, which never expands a shell `~`.
`model` is deliberately **not** expanded: it's an HF repo id (or local path)
that must pass through verbatim.

### KV-cache keys are architecture-dependent

`max_kv_size` and the `kv_*` family are handed to the child, but whether they do
anything depends on the model. `make_prompt_cache` defers to the model's own
`make_cache` when it defines one, **ignoring `max_kv_size` entirely** — so on a
hybrid-attention model like `qwen4_exp` (Qwen3.8-Flash-Next), which builds its
own mix of per-layer cache types, `max_kv_size` is inert. Setting it there reads
as a memory guard while doing nothing. Check the model before relying on it.

Where it *is* honoured, note it is a `RotatingKVCache`: it silently discards the
oldest tokens past the bound rather than erroring, so it trades context for
memory rather than enforcing a limit.

KV quantization has its own architecture caveat: `qwen4_exp`'s `QSAKVCache`
carries the QSA indexer's unprojected keys, and only the **uniform** scheme has
a matching quantized cache. `turboquant` and hybrid schemes leave that cache in
float — quantization silently does nothing rather than failing.

### Reasoning controls

`reasoning_effort` is passed by mlx-vlm straight into `apply_chat_template`, so
the accepted vocabulary belongs to the **model's template**, not to OpenAI.
Qwen3.8-Flash-Next accepts only `xhigh`/`medium`/`low` and raises on anything
else, which turns a stock client's `reasoning_effort: "high"` into a 500. An
entry declares what its template accepts (`reasoning_effort_values`) and what to
fall back to (`reasoning_effort`); the gateway coerces anything outside the set,
rewriting both the flat field and the nested `reasoning: {effort:}` form, since
mlx-vlm reads the nested one first. Efforts meaning "off" (`none`, `off`,
`disabled`, `false`, `0`) pass through so a client can still disable thinking.
Entries with no `reasoning_effort` are untouched.

`preserve_thinking: false` drops `reasoning_content` from assistant history
before forwarding. Qwen templates otherwise replay every prior turn's full
chain-of-thought into the prompt, growing context by reasoning rather than by
answers; mlx-vlm does not forward the template's own `preserve_thinking`, so the
gateway does the equivalent.

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

mlx-vlm (`venv` is the `mlx_vlm.server` console script, invoked directly):

```
<venv> --model <model> --host 127.0.0.1 --port <port>
       [--enable-thinking] [--draft-model X] [--draft-kind K]
       [tuning flags, in MlxVlmFlags::TUNING order] <extra_args…>
```

`extra_args` is appended last for every engine, so it overrides anything the
typed keys emitted — the escape hatch for a flag the registry has no key for.

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
| `~/src/space-inference-gateway/run-gateway.sh` | launcher (templated; sets `PORT=9292`) |
| `~/Library/LaunchAgents/com.slushsystems.space-inference-gateway.plist` | launchd agent — installed, but see below |
| `~/Library/Logs/space-inference-gateway.log` | gateway stdout/stderr under launchd |
| `~/Library/Logs/space-inference-gateway-nohup.log` | gateway stdout/stderr under nohup |
| `~/Library/Logs/space-inference-gateway/<alias>.log` | engine child logs |
| `~/.venv-optiq`, `~/.venv-vllm-metal`, `~/.venv-mlx-vlm` | engine venvs (paths matched by `models.yml`) |
| `~/.cache/huggingface/hub` | model artifacts |

### launchd vs. nohup

The plist sets `KeepAlive: true`, which is right for unattended serving and
wrong while measuring a model that can exhaust memory: an OOM-kill gets an
instant respawn, and the respawned gateway lazily loads an engine again on the
next request that names one. For that work, bootout the job and run the same
launcher under `nohup` instead, so a stopped gateway stays stopped:

```sh
launchctl bootout gui/$(id -u)/com.slushsystems.space-inference-gateway
launchctl disable gui/$(id -u)/com.slushsystems.space-inference-gateway
cd ~/src/space-inference-gateway && nohup ./run-gateway.sh \
  > ~/Library/Logs/space-inference-gateway-nohup.log 2>&1 &
```

`launchctl enable` + `bootstrap gui/$(id -u) <plist>` puts it back. Note the
`gui/` domain is only reachable from a login-session shell — an agent or a
non-GUI context gets `125: Domain does not support specified action`.

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
