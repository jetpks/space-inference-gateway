# Reference: HTTP API

Exact request/response contracts. Base URL in production:
`https://studio.slush.systems` (Caddy → gateway on `127.0.0.1:9292`); local
dev: `http://localhost:3001`. All bodies are JSON. **No authentication** — any
bearer token or API key sent is ignored; the VLAN plus TLS is the boundary.

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/chat/completions` | OpenAI-flavor generation (stream + non-stream) |
| POST | `/v1/messages` | Anthropic-flavor generation (stream + non-stream) |
| POST | `/v1/messages/count_tokens` | token estimate for Claude Code's pre-flight |
| GET  | `/v1/models` | list registry aliases |
| POST | `/v1/load` | explicitly load/swap to an alias |
| POST | `/v1/unload` | stop the running engine child |
| GET  | `/v1/load-progress` | readiness of the active child |
| GET  | `/metrics` | Prometheus exposition ([metrics reference](metrics.md)) |

Anything else: `404` with an OpenAI-shaped error body.

## Model resolution

Every generation request resolves its `model` field against the registry:

- **Known alias** → lazy auto-swap: if it isn't the active model, the gateway
  stops the current child and starts that one before serving (see the
  concurrency rules below).
- **Unknown or absent** → served by whatever is running; if nothing is
  running, the registry's `default:` alias is started. Real clients send
  their own model names (`claude-…`, etc.), which won't match your aliases —
  rather than 404, the gateway serves them.
- The response's `model` field echoes the request's alias when known,
  otherwise `ADVERTISED_MODEL` (default `local-inference`).

Only the explicit `POST /v1/load` rejects unknown aliases (422).

## POST /v1/chat/completions

Standard OpenAI chat-completion request. Before forwarding to an mlx/optiq
engine the gateway rewrites the request:

- **mlx only:** the `model` field is replaced with the entry's HF repo id
  (mlx validates the field and tries to fetch unknown names from HF).
- `developer`-role messages are normalized to `system`.
- The entry's `stop_tokens` are merged into `stop` (de-duplicated).

**Non-stream response** — a conformant `chat.completion` object, validated
against a strict `dry-schema`. `choices[].message` carries `role`, `content`
(`null` when the model emitted only reasoning), `refusal`, plus
`reasoning_content` when reasoning was separated and `tool_calls` when
present. `usage` is exactly `prompt_tokens` / `completion_tokens` /
`total_tokens`. Engine extras are stripped.

**Streaming** (`"stream": true`) — `text/event-stream` of
`chat.completion.chunk` objects; reasoning arrives as `reasoning_content`
deltas, text as `content` deltas, `tool_calls` deltas pass through verbatim,
then a `finish_reason` chunk and `data: [DONE]`. All chunks share the
upstream's first chunk id.

## POST /v1/messages

Standard Anthropic messages request. **The engines speak OpenAI HTTP only —
this endpoint is never forwarded.** The gateway translates the request
ANT→OAI, calls the engine's `/v1/chat/completions`, and synthesizes a
conformant Anthropic response:

Request translation:

- top-level `system` → leading OAI `system` message; mid-conversation
  `system`-role entries inside `messages[]` (sent by Claude Code ≥ 2.1.214)
  are demoted to `user`, content preserved (mlx/optiq reject non-leading
  system messages).
- `tools` → OAI function tools; assistant `tool_use` blocks → `tool_calls`;
  user `tool_result` blocks → one `{role: "tool"}` message each, leftover
  text following as a `user` message.
- `max_tokens`, `stream`, `temperature`, `top_p` map through;
  `stop_sequences` → `stop`, with registry `stop_tokens` merged in.

Response synthesis:

- content blocks in order: `thinking` (when reasoning was separated), `text`,
  then `tool_use` blocks — tool ids get the `toolu_` prefix Claude Code
  expects to round-trip, and `function.arguments` is parsed into the `input`
  object (falling back to `{}` on unparseable JSON).
- `stop_reason` mapping: `stop` → `end_turn`, `length` → `max_tokens`,
  `tool_calls` → `tool_use`, anything else verbatim.
- `usage`: `prompt_tokens`/`completion_tokens` → `input_tokens`/`output_tokens`.

**Streaming** — a synthesized, spec-shaped Anthropic event sequence:
`message_start` → `content_block_start`/`content_block_delta`/
`content_block_stop` per block (`thinking_delta`, `text_delta`,
`input_json_delta` for tool arguments) → `message_delta` (with `stop_reason`)
→ `message_stop`. Block indexes are sequential in order of first appearance.

## POST /v1/messages/count_tokens

Claude Code calls this before sending, to size the prompt; a 404 makes it
refuse the model. The engines have no native counter, so the gateway returns
a deliberate estimate: `ceil(total chars / 4)` over `system` + `messages` +
`tools` (string content and text-block arrays both counted).

```json
{ "input_tokens": 123 }
```

Good enough for context-window accounting; not billing-grade, and not meant
to be.

## GET /v1/models

```json
{ "object": "list",
  "data": [ { "id": "qwen3-27b-optiq", "object": "model", "created": 0, "owned_by": "local" }, … ] }
```

One entry per registry alias, active or not.

## POST /v1/load

Body: `{"model": "<alias>"}` (`model_path` accepted as a legacy synonym).
Swaps to the alias — stop current child (verified, port confirmed released),
spawn, block until its `/health` readiness poll passes (up to the model's
readiness budget: 120 s default, per-model `readiness_timeout`) — and
returns:

```json
{ "status": "loaded", "model_path": "mlx-community/Qwen3.6-27B-OptiQ-4bit" }
```

`model_path` is the entry's HF repo id. Unknown alias → 422; swap refused
while a generation is in flight → 409; readiness timeout → 504.

## POST /v1/unload

Body optional (a `model_path` is accepted and echoed). Stops the child:

```json
{ "status": "unloaded", "model_path": "…" }
```

## GET /v1/load-progress

Synthesized from supervisor state (the engines expose no byte-level load
progress; byte counts are placeholders):

```json
{ "phase": "ready", "bytes_loaded": 0, "bytes_total": 0, "fraction": 1.0 }
{ "phase": null,    "bytes_loaded": 0, "bytes_total": 0, "fraction": 0.0 }
```

## Concurrency and streaming semantics

- **Swap decisions are single-flight and never cancel work**: the active/busy
  check, the swap, and the generation reservation happen atomically behind
  one gate, so concurrent requests for the same alias coalesce onto a single
  transition, and a swap requested while any generation is in flight is
  refused with 409. The in-flight count is held for the *entire* stream
  lifetime — from stream open to the client closing the response body.
- **SSE keepalive**: after 45 s of upstream silence the gateway emits a
  `: keepalive` comment line (SSE-legal; ignored by the OpenAI and Anthropic
  SDK decoders). optiq can spend minutes in prompt prefill emitting zero
  bytes; without this, client idle timers would abort the stream.
- **Upstream timeouts**: a streaming open that receives no response headers
  within `UPSTREAM_HEADERS_TIMEOUT` (300 s) fails 504; a buffered call that
  times out with no response likewise. Both feed the
  [zombie watchdog](configuration.md#supervisor-timeouts-and-the-zombie-watchdog).
  Mid-stream, an idle gap over `UPSTREAM_IDLE_TIMEOUT` (600 s) ends the
  stream; the SSE response is already 200, so the end is silent on the wire
  but counted as a 504 in `sig_upstream_errors_total`.

## Status codes

| Code | When | Body |
|---|---|---|
| 200 | success | per-endpoint shape above |
| 404 | unknown path | `{"error":{"message":"Not found","type":"invalid_request_error"}}` |
| 409 | swap refused, generation in flight | `type: "model_busy"` |
| 422 | unknown alias on explicit load | `type: "invalid_request_error"` |
| 502 | engine connection/spawn failure | `type: "upstream_error"` |
| 504 | readiness or headers timeout | `type: "upstream_error"` |
| 500 | gateway bug | `type: "internal_error"` |

Engine-originated errors are relayed at their upstream status, reshaped into
the client's flavor: OpenAI callers get `{"error":{"message","type"}}`;
Anthropic callers get `{"type":"error","error":{"type","message"}}` with the
type mapped from status (429 → `rate_limit_error`, 5xx → `api_error`, etc.).
mlx's nonconformant `{"error": "<string>"}` bodies are detected and reshaped
before relay.
