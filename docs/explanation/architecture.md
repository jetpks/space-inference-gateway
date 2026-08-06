# Explanation: architecture and design

This is the understanding-oriented document — why the gateway is shaped the
way it is, and the trade-offs behind the decisions. For commands see the
[how-to guides](../how-to/install-dependencies.md); for exact contracts see
the [reference](../reference/http-api.md).

## The problem

Running a local LLM for daily use with Claude Code and opencode hits three
walls at once:

1. **Reasoning leaks into content.** Local engines emit chain-of-thought
   either inline as `<think>…</think>` mixed into visible text, or on
   engine-specific fields no client knows about. Clients render the model's
   scratchpad as the answer.
2. **Strict parsers meet loose dialects.** opencode validates responses with
   zod; Claude Code expects an exact Anthropic shape. "OpenAI-compatible"
   engines bolt on extra fields, shape errors as bare strings, and — in mlx's
   case — don't speak the Anthropic dialect at all.
3. **The LAN is privacy-gated.** macOS blocks signed CLI binaries from
   reaching a private-IP host, so the clients can't even connect to the
   studio directly.

The gateway solves 1 and 2 in one place — a normalization proxy — so no
client needs a per-client workaround. Problem 3 is structural to macOS and
solved with a loopback shim (below), not by the proxy.

## The serving path

```
Claude Code / opencode
   → 127.0.0.1 loopback TLS shim         (laptop; Apple python3)
   → studio.slush.systems:443            (Caddy; LE cert via DNS-01/DigitalOcean)
   → space-inference-gateway :9292       (this gem; Falcon)
   → mlx_lm.server / optiq serve :8080   (Apple-silicon engines; spawned & supervised)
```

Each hop earns its place:

- **The loopback shim** exists only to defeat the macOS LAN gate (see below).
- **Caddy** terminates TLS with a real, auto-renewing certificate. ACME
  DNS-01 + DigitalOcean + auto-renew is a solved problem — we use Caddy
  (built with the `caddy-dns/digitalocean` plugin via `xcaddy`) rather than
  hand-rolling ACME in Ruby. Ruby is reserved for the custom normalization
  logic.
- **The gateway** is the only bespoke component: serve both flavors and own
  the model lifecycle.
- **The engine** does the inference. The gateway supervises it as a child
  process.

## One upstream protocol, two client flavors

The central architectural fact: **both engines speak OpenAI HTTP only**, so
the Anthropic surface is *synthesized*, not proxied. `/v1/chat/completions`
is normalize-and-forward; `/v1/messages` never reaches an engine — the
gateway translates the request ANT→OAI (system message placement, tool
definitions, `tool_use`/`tool_result` blocks), calls the engine's OAI
endpoint, and emits a spec-shaped Anthropic response — including the full
streaming event grammar (`message_start` → `content_block_*` →
`message_delta` → `message_stop`) built from OAI deltas on the fly.

This sounds like more machinery than proxying two dialects, but it's less:
there is exactly one upstream protocol to capture fixtures for, and the
Anthropic output is *our* output — schema-conformant by construction, checked
by `dry-schema` in the suite, never at the mercy of an engine's
approximation of Anthropic's SSE grammar. When llama.cpp was the engine it
did speak both dialects, and the gateway proxied `/v1/messages` natively;
that passthrough path (and `ErrorRelay::Oai`, and the `llamacpp` fixtures)
is retained so a future true-OAI/ANT engine can slot back in.

Engine quirks are absorbed at this seam too, invisibly to clients: mlx
validates the request's `model` field (and would try to fetch unknown names
from Hugging Face), so the gateway rewrites it to the loaded HF repo id; mlx
shapes errors as `{"error": "<string>"}`, so `ErrorRelay::Mlx` reshapes them;
mlx_lm 0.31.3 sometimes misses its own eos stop, so registry `stop_tokens`
are injected into requests.

## Two orthogonal problems, never conflated

The codebase keeps two concerns strictly separate:

**Normalization** (the `*Normalizer` classes + `ReasoningParser` +
`Schemas`). Pure input→output transforms over captured response shapes.
Reasoning is lifted to the correct channel per flavor (OpenAI
`reasoning_content`; Anthropic `thinking` blocks), and output validates
against strict `dry-schema`s. Critically, the parser is **streaming-safe**: a
`<think>` tag split across two SSE chunks must never leak a partial tag, so
`ReasoningParser` holds back the last few bytes of its buffer until it can
decide.

**Model lifecycle** (`ModelController` + `InferenceServerSupervisor` +
`ModelRegistry`). The gateway *is* the orchestrator: it spawns the engine,
gates on readiness, swaps models, and stops them.

These never mix: normalizers don't know about processes; the supervisor
doesn't know about JSON shapes. The `App` is the thin seam that wires a
normalizer to the live upstream per request.

## Reasoning channels, per model

Where reasoning comes from is a **registry property, not a global**: mlx
emits a native `reasoning` field for models whose chat template separates
thinking, and the `<think>` parser handles models that tag it inline
(`deepseek-r1-70b`, `nemotron-3-super`). Both paths feed the same output
channels. For models that don't reason at all (`hermes-4-70b`),
`supports_reasoning: false` keeps the normalizer in passthrough so a literal
`<think>` in prose is never misclassified.

A lesson that survives every engine change: **capture fixtures from a live
server, never assume field shapes.** An earlier normalizer written against
LM-Studio-shaped fixtures silently dropped thousands of characters of
reasoning and emitted schema-invalid Anthropic output (empty `signature`).
Real captures closed both defects, and each engine era has left its fixture
directory (`spec/fixtures/llamacpp/`, `mlx/`, `optiq/`) as the ground truth
its code was written against.

## The pivots: how the shape emerged

The gateway has survived two engine pivots, and its shape is largely the
residue of what each one taught:

1. **Orchestrator → supervisor.** Originally model swaps were driven through
   Unsloth Studio's HTTP load API. That API was unusable on this box
   (auth-walled; its load orchestration wedged), and since it merely
   orchestrated `llama-server` underneath, the orchestration moved into the
   Ruby app. That's why the gateway supervises its engine directly and no
   external orchestrator exists.
2. **llama.cpp → mlx/optiq.** Apple-silicon-native engines (mlx-lm, then
   optiq with multi-token prediction for the default model) replaced
   `llama-server`. Because the supervisor/normalizer split already existed,
   the re-home was mostly a new argv builder and the ANT-synthesis path —
   the registry grew an `engine:` key and each entry carries its engine's
   launch recipe.

The trace of pivot 1 still matters operationally: swaps are in-process, so a
gateway crash could orphan an engine child holding `:8080`. Two mechanisms
close that: the bin traps SIGTERM/SIGINT and tears the child down before
exit, and the supervisor reaps any stale listener on its engine port (via
`lsof`, engine-agnostic) before its first spawn — so even a hard kill leaves
nothing a restart can't recover from.

## Supervision and the control plane

The supervisor spawns the engine per its registry entry and polls its
`/health` with a raw `TCPSocket` (chosen to sidestep a client-pool drain
hang and stay fiber-scheduler-friendly) for up to the model's readiness
budget — 120 s default, raised per-model via `readiness_timeout:` for ≥100B
models a flat budget would kill mid-load. Every probe is itself bounded, so
a child that accepts TCP but never answers can't park the readiness loop.
Stops are **verified**: TERM, then KILL, with bounded waits — signals go to
the whole process group (`async-process` spawns with `pgroup: true` and
signals `-pid`) — and finally the port itself is confirmed released, so a
successor never spawns onto a port a corpse still holds (nor can readiness
be satisfied by a still-alive predecessor answering on its behalf).

Swap policy lives in `ModelController`, and every engine transition is
**single-flight**: one gate makes the active/busy check, the swap, and the
generation reservation atomic, so concurrent same-alias requests coalesce
onto one transition and no request can slip through the gap between "not
busy" and "generation counted" (a TOCTOU diagnosed live on the studio).
Known aliases lazy-swap on request; unknown model names are served by the
running/default model (real clients send their own model names — refusing
them would break every client); swaps are refused with 409 while generations
are in flight, never cancelling work.

The **zombie watchdog** exists because a wedged engine child fails in the
worst possible way: it accepts TCP, still answers `/health`, but never
writes a generation response — its generate thread died. Liveness can't be
probed from the outside, so the watchdog counts *request-path* evidence,
stream-agnostic: a streaming open that times out before headers, or a
buffered call that times out with no response, is a strike; any real
response resets the streak. Two strikes and the supervisor restarts the
child, deliberately bypassing the busy guard (a zombied child has doomed its
in-flight generations anyway).

## Streaming resilience

Streaming is where local inference actually breaks, so several mechanisms
exist purely to keep long generations alive and observable:

- **Keepalive comments.** optiq can spend minutes in prompt prefill emitting
  zero bytes; client HTTP idle timers (pi defaults to 300 s) would abort the
  stream. After 45 s of upstream silence the gateway emits a `: keepalive`
  SSE comment — spec-legal, and verified ignored by the OpenAI and Anthropic
  SDK decoders.
- **Two-phase upstream timeouts.** Opening a stream is bounded by a headers
  timeout (300 s — this is what catches zombies); once streaming, only an
  idle *gap* over 600 s times out, so a stream that keeps emitting never
  dies. A mid-stream timeout can't carry a 5xx on an already-200 SSE
  response, so it ends silently on the wire but is counted in
  `sig_upstream_errors_total` — observable even when invisible.
- **Stream lifetime is the unit of accounting.** Falcon consumes a streaming
  body lazily *after* the handler returns, so the in-flight generation count
  is held from stream open until the body's idempotent `close` — teardown
  closes upstream response before client (so pool drain doesn't hang),
  observes duration, and releases the counter exactly once. Getting this
  wrong (the count dropping to zero before relay) was a real regression
  caught and fixed during the build.
- **The pipe trick.** The normalizer drains in a scheduler fiber writing to
  an `IO.pipe`, and the Rack body reads it with `IO.select` timeouts —
  because Falcon drives the body from an Enumerator fiber where
  `Async::Task.current` doesn't exist. `IO.select` works in any fiber on the
  scheduler's thread; an `Async::Notification` wouldn't.

## Why a loopback shim — the TCC gate {#the-tcc-gate}

macOS Tahoe's Local Network privacy gate keys on the **destination IP being
private**. `studio.slush.systems` resolves to a LAN address, so the signed
`claude` binary is blocked regardless of hostname or TLS — the reverse proxy
does **not** fix this. Two facts make the shim work:

- **Loopback (`127.0.0.1`) is exempt.** Client → shim plaintext is fine.
- **The exemption is per-binary-identity, and Apple-platform binaries are
  exempt** on the LAN. `/usr/bin/python3` qualifies; a Ruby/mise forwarder
  would itself be gated.

So the shim is `forward_tls.py` — stdlib-only (so it runs under the system
`python3`), HTTP-aware, keep-alive, SSE-streaming. It rewrites the request
`Host:` to `studio.slush.systems` (Caddy matches on the HTTP `Host` header,
not just SNI — a mismatched Host yields an empty 200) and originates TLS to
`:443`. The clients talk plaintext to loopback; the shim carries the bytes,
encrypted, across the VLAN. This is the one piece that can't move to Ruby.

## Concurrency model: fibers, not threads

Everything async-owned is cooperative concurrency on fibers (`async`,
`async-http`, `async-process`, Falcon) — one process, no threads in our code.
Model swaps are serialized with `Async::Semaphore(1)`; the single-reactor
model is also why the Prometheus store can be `SingleThreaded` with no mutex.
Control-plane flow uses `dry-monads` `Result`
(`Success`/`Failure(:busy)`/`Failure(:unknown_model)`/`Failure(:timeout)`)
rather than exceptions-as-control-flow, and `App` maps failures to HTTP
status in one place (`swap_error_response`). This is the house style:
confident, declarative Ruby with the type/coercion boilerplate pushed to the
edges.

## Non-goals (deliberately out of scope)

- **Auth beyond the VLAN.** The private ~3-host VLAN plus TLS is the
  responsible bar; the dummy API key the clients send is ignored (and
  `/metrics` is likewise open inside the boundary).
- **Clients beyond Claude Code + opencode.** The surface is general (standard
  OpenAI + Anthropic), but only these two are validated end-to-end.
- **Translating every OpenAI↔Anthropic semantic.** Translation is scoped to
  what CC/opencode actually send — tool calls, system placement, the stop
  reasons they read — not a general dialect bridge.
- **Precise token counting.** `count_tokens` is chars/4 by design; it feeds
  the client's context accounting, not billing.
- **Rewriting the Python shim in Ruby.** It can't be — the TCC exemption is
  per-binary (see above).

## Where to go next

- Stand it up locally: the [tutorial](../tutorial.md).
- Exact endpoint and config contracts: the
  [HTTP API](../reference/http-api.md),
  [configuration](../reference/configuration.md), and
  [metrics](../reference/metrics.md) references.
- What's planned: the [ROADMAP](../../ROADMAP.md).
