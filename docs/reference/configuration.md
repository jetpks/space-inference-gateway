# Reference: configuration

All the knobs: environment variables, the model registry file, how the
`llama-server` command line is assembled, and the component map.

## Environment variables

Read at process start (`bin/space-inference-gateway` and `App`):

| Variable              | Default                          | Effect                                                                 |
|-----------------------|----------------------------------|------------------------------------------------------------------------|
| `PORT`                | `3001`                           | Port Falcon listens on. Production uses `9292` (behind Caddy).          |
| `ADVERTISED_MODEL`    | `local-inference`                | Fallback `model` echoed in responses when the request's alias is unknown. Production: `qwen3-35b-a3b`. |
| `MODEL_CONFIG_PATH`   | `config/models.yml` (in the gem) | Path to the model registry YAML. Unset in production → committed file is the single source of truth. |
| `LLAMA_SERVER_BINARY` | `llama-server` (`DEFAULT_BINARY`)| `llama-server` path when a registry entry has no `binary:`. Resolved from `PATH` if left as the default. |

## The model registry — `config/models.yml`

```yaml
default: qwen3-35b-a3b      # alias started when nothing is running

models:
  <alias>:
    gguf:        <path>     # required; ~ expanded & made absolute
    port:        <int>      # required; llama-server child port
    ctx:         <int>      # → -c        (0/omitted → -c 0)
    parallel:    <int>      # → --parallel (default 1); per-slot ctx = ctx / parallel
    offload:     fit | ngl  # fit → --fit on; ngl → -ngl -1; omit → neither
    binary:      <path>     # optional; ~ expanded; overrides LLAMA_SERVER_BINARY
    extra_args:  [<str>…]   # optional; appended verbatim
    supports_reasoning: <bool>   # optional; default true
```

- `gguf` and `binary` are the **only** keys with `~` expansion (`PATH_KEYS`) —
  argv goes straight to `exec`, which never expands a shell `~`.
- `supports_reasoning: false` turns off reasoning separation for that model
  (content passes through unsplit; no `reasoning_content`/`thinking` lifting).

See [add & tune models](../how-to/add-and-tune-models.md) for worked examples and
context-window guidance.

## How the `llama-server` command line is built

`LlamaServerSupervisor#build_argv` assembles, in order:

```
<binary> -m <gguf> --port <port> -c <ctx|0> --parallel <parallel|1> \
  --flash-attn on --no-context-shift --jinja \
  [--fit on | -ngl -1]  <extra_args…>
```

`--flash-attn on`, `--no-context-shift`, and `--jinja` are **always** present.
`--jinja` is load-bearing: it applies the model's chat template so `llama-server`
emits its native reasoning channel (`reasoning_content` / `thinking`), which the
normalizers consume. Without it the server emits the legacy inline `<think>`
shape and the whole reasoning pipeline is bypassed.

## Supervisor timeouts

`LlamaServerSupervisor::Timeouts` (a `Data` value, `Timeouts.default`):

| Field           | Default | Meaning                                                        |
|-----------------|---------|----------------------------------------------------------------|
| `readiness`     | 120 s   | Max wait for the child's `/health` to return 200 before `504`. |
| `stop_grace`    | 5 s     | Grace after `TERM` before escalating to `KILL`.                |
| `poll_interval` | 0.5 s   | `/health` poll cadence during readiness.                       |

Not env-configurable; override by constructing the supervisor with a custom
`Timeouts` (used in tests). Child logs are written to
`$TMPDIR/space-inference-gateway/<alias>.log`.

## Process / file layout

| Path                                   | What                                                       |
|----------------------------------------|-----------------------------------------------------------|
| `bin/space-inference-gateway`          | Entry point — boots Falcon with `cache: false`.            |
| `config.ru`                            | Rack entry (`run App.new`) for `falcon serve` / rackup.    |
| `config/models.yml`                    | The model registry.                                        |
| `lib/space_inference_gateway/`         | The library (see component map below).                     |
| `$TMPDIR/space-inference-gateway/*.log`| Per-model `llama-server` stdout/stderr.                    |

> Falcon's `Async::HTTP::Cache` is **disabled** (`cache: false` in
> `bin/space-inference-gateway`). It would replay cacheable GETs (`/v1/models`,
> `/v1/load-progress`) with an empty body in front of this dynamic API.

## Component map

| Class                    | Responsibility                                                                 |
|--------------------------|-------------------------------------------------------------------------------|
| `App`                    | Rack routing; request/response normalization wiring; the `StreamBody` SSE relay. |
| `ModelController`        | Control-plane policy: lazy auto-swap, 409-busy guard, generation accounting, load/unload/progress. dry-monads `Result`. |
| `LlamaServerSupervisor`  | Owns the `llama-server` child: spawn (`async-process`, `pgroup:true`), `/health` readiness gate, TERM→KILL stop, serialized swap (`Semaphore(1)`). |
| `ModelRegistry`          | Loads `models.yml`; resolves alias → entry; `~` expansion; default alias.       |
| `UpstreamClient`         | `async-http` client to the live child; buffered `call` + non-buffering `open_stream`; callable `base_url`. |
| `OaiNormalizer`          | OpenAI in/out: reasoning → `reasoning_content`, field stripping, stream + non-stream. |
| `AntNormalizer`          | Anthropic in/out: reasoning → `thinking` blocks, `signature` strip, stream de-interleave. |
| `ReasoningParser`        | Split-tag-safe `<think>…</think>` extractor (the fallback path).                |
| `Schemas`                | `dry-schema` definitions the output is validated against.                       |

Details in the [architecture explanation](../explanation/architecture.md).
