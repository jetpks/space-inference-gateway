# Explanation: architecture and design

This is the understanding-oriented document — why the gateway is shaped the way
it is, and the trade-offs behind the decisions. For commands see the
[how-to guides](../how-to/install-dependencies.md); for exact contracts see the
[reference](../reference/http-api.md).

## The problem

Running a local LLM for daily use with Claude Code and opencode hits three walls
at once:

1. **Reasoning leaks into content.** `llama-server` (and unsloth before it) can
   emit chain-of-thought inline as `<think>…</think>` mixed into the assistant's
   visible text. Clients render the model's scratchpad as the answer.
2. **Non-standard fields break strict parsers.** "OpenAI-compatible" servers bolt
   on extra fields (`timings`, gguf-path `model`, token-detail sub-hashes, empty
   `signature`). opencode validates responses with zod; Claude Code expects a
   strict Anthropic shape. Extra keys → parse errors.
3. **The LAN is privacy-gated.** macOS blocks signed CLI binaries from reaching a
   private-IP host, so the clients can't even connect to the studio directly.

The gateway solves 1 and 2 in one place — a normalization proxy — so no client
needs a per-client workaround. Problem 3 is structural to macOS and solved with a
loopback shim (below), not by the proxy.

## The serving path

```
Claude Code / opencode
   → 127.0.0.1 loopback TLS shim   (laptop; Apple python3)
   → inference.example.com:443      (Caddy; LE cert via DNS-01/DigitalOcean)
   → space-inference-gateway :9292  (this gem; Falcon)
   → llama-server :8080            (llama.cpp; spawned & supervised by the gateway)
```

Each hop earns its place:

- **The loopback shim** exists only to defeat the macOS LAN gate (see below).
- **Caddy** terminates TLS with a real, auto-renewing certificate. ACME DNS-01 +
  DigitalOcean + auto-renew is a solved problem — we use Caddy (built with the
  `caddy-dns/digitalocean` plugin via `xcaddy`) rather than hand-rolling ACME in
  Ruby. Ruby is reserved for the custom normalization logic.
- **The gateway** is the only bespoke component: normalize both flavors and own
  the model lifecycle.
- **`llama-server`** does the inference. The gateway supervises it as a child
  process.

## Two orthogonal problems, never conflated

The codebase keeps two concerns strictly separate:

**Normalization** (the `*Normalizer` classes + `ReasoningParser` + `Schemas`).
Pure input→output transforms over captured response shapes. Reasoning is lifted
to the correct channel per flavor (OpenAI `reasoning_content`; Anthropic
`thinking` blocks), and non-standard fields are stripped so output validates
against strict `dry-schema`s. Critically, the parser is **streaming-safe**: a
`<think>` tag split across two SSE chunks must never leak a partial tag, so
`ReasoningParser` holds back the last few bytes of its buffer until it can decide.

**Model lifecycle** (`ModelController` + `LlamaServerSupervisor` +
`ModelRegistry`). The gateway *is* the orchestrator: it spawns `llama-server`,
gates on readiness, swaps models, and stops them. This was not the original plan
— see the pivot below.

These never mix: normalizers don't know about processes; the supervisor doesn't
know about JSON shapes. The `App` is the thin seam that wires a normalizer to the
live upstream per request.

## Native reasoning, with a fallback

The single most load-bearing detail: the gateway always launches `llama-server`
with **`--jinja`**. That applies the model's chat template, which makes
`llama-server` emit its **native** reasoning channel — `reasoning_content` for
OpenAI, proper `thinking` blocks (and `thinking_delta` stream events) for
Anthropic. The normalizers consume that channel directly and byte-faithfully.

The inline `<think>…</think>` parser is kept as a **fallback** for any model or
mode that still emits the legacy shape. Both paths are exercised by the suite.
This is why the field shapes were *captured from a live server*, never assumed:
an earlier version of the normalizers, written against LM-Studio-shaped fixtures,
silently dropped thousands of characters of reasoning (OpenAI) and emitted
schema-invalid output (Anthropic, empty `signature`). Real captures
(`spec/fixtures/llamacpp/`) closed both defects.

## The pivot: from orchestrator to supervisor

The gateway originally drove model swaps through **Unsloth Studio's** HTTP load
API. That API turned out to be unusable on this box: auth-walled, and its load
orchestration wedged — `POST /v1/load` returned HTTP 000 and spawned nothing,
while read endpoints answered instantly. Since Unsloth merely orchestrates
`llama-server` under the hood, the orchestration was pulled **into the Ruby app**.

Consequence: the gateway now supervises `llama-server` directly and Unsloth is
gone from the serving path. (The binary still happens to be the Unsloth-built
one; replacing it with stock `brew install llama.cpp` is the headline
[roadmap](../../ROADMAP.md) item.) Diffusion models (e.g. diffusiongemma) were
**dropped from scope** at the same time — they aren't plain `llama.cpp` (Unsloth
serves them via a diffusion shim + a special visual binary), so de-coupling them
cleanly wasn't possible. The mission is text models only.

## Why a loopback shim — the TCC gate {#the-tcc-gate}

macOS Tahoe's Local Network privacy gate keys on the **destination IP being
private**. `inference.example.com` resolves to a LAN address, so the signed
`claude` binary is blocked regardless of hostname or TLS — the reverse proxy does
**not** fix this. Two facts make the shim work:

- **Loopback (`127.0.0.1`) is exempt.** Client → shim plaintext is fine.
- **The exemption is per-binary-identity, and Apple-platform binaries are
  exempt** on the LAN. `/usr/bin/python3` qualifies; a Ruby/mise forwarder would
  itself be gated.

So the shim is `forward_tls.py` — stdlib-only (so it runs under the system
`python3`), HTTP-aware, keep-alive, SSE-streaming. It rewrites the request
`Host:` to `inference.example.com` (Caddy matches on the HTTP `Host` header, not
just SNI — a mismatched Host yields an empty 200) and originates TLS to `:443`.
The clients talk plaintext to loopback; the shim carries the bytes, encrypted,
across the VLAN. This is the one piece that can't move to Ruby.

## Concurrency model: fibers, not threads

Everything async-owned is cooperative concurrency on fibers (`async`,
`async-http`, `async-process`, Falcon) — one process, no threads in our code. The
supervisor uses `Async::Process::Child` with `pgroup: true` so that TERM→KILL
reaps the whole process group and never orphans a `llama-server`. Readiness is a
raw-`TCPSocket` `/health` poll (not `async-http`), chosen to sidestep a
client-pool drain hang and stay fiber-scheduler-friendly.

Model swaps are serialized with `Async::Semaphore(1)` — at most one swap at a
time. A swap requested while a generation is in flight is refused with **HTTP
409**, never cancelling work mid-flight. The subtle part is *streaming*: a stream
response returns a `StreamBody` whose upstream body is consumed lazily by Falcon
*after* the handler returns. So the in-flight count is begun when the stream
opens and ended (idempotently) when the `StreamBody` closes — holding the guard
across the entire stream lifetime, not just its setup. Getting this wrong (the
count dropping to zero before relay) was a real regression caught and fixed
during the build.

## Result types over exceptions

Control-plane flow uses `dry-monads` `Result` (`Success`/`Failure(:busy)`,
`Failure(:unknown_model)`, `Failure(:timeout)`, …) rather than
exceptions-as-control-flow. `App` maps those failures to HTTP status codes in one
place (`swap_error_response`). Output validation uses `dry-schema` rather than
hand-rolled checks. This is the house style: confident, declarative Ruby with the
type/coercion boilerplate pushed to the edges.

## Non-goals (deliberately out of scope)

- **Auth beyond the VLAN.** The private ~3-host VLAN plus TLS is the responsible
  bar; the dummy API key the clients send is ignored.
- **Clients beyond Claude Code + opencode.** The surface is general (standard
  OpenAI + Anthropic), but only these two are validated end-to-end.
- **Translating every OpenAI↔Anthropic semantic.** Translation is scoped to what
  CC/opencode actually send; deep tool-call/stop-reason/usage reconciliation is
  not attempted where the clients don't need it.
- **Rewriting the Python shim in Ruby.** It can't be — the TCC exemption is
  per-binary (see above).

## Where to go next

- Stand it up locally: the [tutorial](../tutorial.md).
- Exact endpoint and config contracts: the
  [HTTP API](../reference/http-api.md) and
  [configuration](../reference/configuration.md) references.
- What's planned: the [ROADMAP](../../ROADMAP.md).
