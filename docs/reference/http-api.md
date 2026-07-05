# Reference: HTTP API

The gateway (`SpaceInferenceGateway::App`) is a Rack app served by Falcon. All
endpoints are unauthenticated — the security boundary is the private VLAN plus
TLS at the Caddy edge, not a bearer token. Unknown routes return `404`; an
unhandled error returns `500`. Bodies are JSON; streaming endpoints return SSE.

Base URL in production: `https://inference.example.com` (via Caddy → gateway
`:9292`). Locally: `http://localhost:$PORT`.

## Endpoints

| Method | Path                    | Purpose                                          |
|--------|-------------------------|--------------------------------------------------|
| POST   | `/v1/chat/completions`  | OpenAI-flavored chat completion (stream / not)   |
| POST   | `/v1/messages`          | Anthropic-flavored message (stream / not)        |
| GET    | `/v1/models`            | List registered model aliases                    |
| POST   | `/v1/load`              | Ensure a model is running (preload)              |
| POST   | `/v1/unload`            | Stop the running `llama-server`                  |
| GET    | `/v1/load-progress`     | Readiness phase of the current model             |

### POST `/v1/chat/completions`

OpenAI Chat Completions. Request is forwarded to `llama-server`; the response is
normalized. Set `"stream": true` for SSE.

**Non-stream response** (validates `Schemas::OAI_COMPLETION`):

- `model` is the requested alias (or the advertised default), never the gguf path.
- `choices[].message.content` is clean (no `<think>` tags).
- `choices[].message.reasoning_content` carries reasoning when the model emits it.
- `usage` is exactly `{prompt_tokens, completion_tokens, total_tokens}` (integers).
- `system_fingerprint` passes through only if the upstream sent it.
- Upstream extras (`timings`, token-detail sub-hashes) are stripped.

**Stream response** (each event validates `Schemas::OAI_CHUNK`): a sequence of
`data: {chat.completion.chunk}\n\n` lines — `reasoning_content` deltas, then
`content` deltas, a final `finish_reason` chunk — terminated by
`data: [DONE]\n\n`. Chunks of `type: "diffusion_frame"` are dropped.

### POST `/v1/messages`

Anthropic Messages. Set `"stream": true` for SSE.

**Non-stream response** (validates `Schemas::ANT_MESSAGE`): `content` is an array
of blocks — a `thinking` block (when present) and a `text` block. The `signature`
field is **always stripped** from thinking blocks (the upstream emits an empty
one, which fails strict Anthropic validation). `model` is the alias; `usage` is
`{input_tokens, output_tokens}` plus cache counters when present.

**Stream response**: native Anthropic SSE — `message_start` → `content_block_*`
for the thinking block (`thinking_delta`) → `content_block_*` for the text block
(`text_delta`) → `message_delta` → `message_stop`. Interleaved upstream blocks
are de-interleaved; empty `signature_delta` events are dropped. (Note: the
Anthropic stream does **not** emit a `[DONE]` sentinel — that's OpenAI-only.)

### GET `/v1/models`

Returns `{"object":"list","data":[…]}` (validates `Schemas::MODELS_LIST`). One
entry per registry alias: `{id, object:"model", created:0, owned_by:"local"}`.

### POST `/v1/load`

Body: `{"model":"<alias>"}` (also accepts `model_path`). Ensures that model's
`llama-server` is running, blocking until `/health` is ready. On success returns
`{"status":"loaded","model_path":"<gguf>"}` (validates `Schemas::LOAD_RESPONSE`).
Errors: see the status table below.

### POST `/v1/unload`

Body: `{}` (optionally `{"model_path":"…"}`). Stops the running child (TERM→KILL
the process group). Returns `{"status":"unloaded","model_path":"<gguf>"}`
(validates `Schemas::UNLOAD_RESPONSE`).

### GET `/v1/load-progress`

Readiness synthesized from supervisor state (validates `Schemas::LOAD_PROGRESS`):

- running: `{"phase":"ready","bytes_loaded":0,"bytes_total":0,"fraction":1.0}`
- stopped: `{"phase":null,"bytes_loaded":0,"bytes_total":0,"fraction":0.0}`

(Byte counts are placeholders — `llama-server` doesn't expose load-byte progress;
the field is `ready`/not-ready.)

## Model resolution

The gateway resolves the request's `model` field before serving:

- **Known alias** → swap to it if not already active (lazy auto-swap).
- **Unknown or `nil`** → keep whatever model is already running; if nothing is
  running, start the registry **default**.

This is deliberate: real clients (Claude Code, opencode) send their own model
names, which won't match your aliases. Rather than 404, the gateway serves them
from the running/default model. Explicit `POST /v1/load`, by contrast, requires a
**registered** alias and returns `422` for unknown ones.

## Status codes

| Status | When                                                                 |
|--------|----------------------------------------------------------------------|
| 200    | Success.                                                              |
| 404    | Unknown route.                                                        |
| 409    | Model swap refused — a generation is in flight (`model_busy`).        |
| 422    | Explicit load of an unregistered alias (`invalid_request_error`).     |
| 500    | Unhandled internal error.                                             |
| 502    | Upstream `llama-server` error, or a swap upstream error.             |
| 504    | Model load timed out waiting on `/health` (`upstream_error`).         |

Error bodies are `{"error":{"message":…,"type":…}}`.

## Concurrency semantics

- Model swaps are **serialized** (`Async::Semaphore(1)`): one swap at a time.
- A swap requested **while a generation is in flight is refused with `409`** — no
  surprise cancellation. The in-flight count is held across the **entire** stream
  lifetime (begun when the stream opens, ended when the streaming body closes),
  so a swap can't slip in mid-stream.

See the [architecture explanation](../explanation/architecture.md) for the why.
