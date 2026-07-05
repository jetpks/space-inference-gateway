# Tutorial: your first end-to-end request

By the end of this you will have the gateway running on one machine, serving a
real model, answering both an OpenAI-flavored and an Anthropic-flavored request
with reasoning separated into its own channel. No Caddy, no TLS, no loopback
shim yet — just the gateway and a `llama-server`, talking over plain HTTP on
localhost. That is the smallest thing that proves the whole idea.

This is a learning exercise. For production deployment see the
[deploy how-to](how-to/deploy-on-the-studio.md); for the security model behind
the loopback shim see the [architecture explanation](explanation/architecture.md).

## What you need

- A machine with a GPU/enough RAM to run a small reasoning model.
- Ruby ≥ 3.3 with Bundler.
- A `llama-server` binary and a `.gguf` model file. If you don't have these yet,
  the [install-dependencies how-to](how-to/install-dependencies.md) walks
  through `brew install llama.cpp` and fetching a model.

We'll use a small reasoning model so the `<think>`/reasoning separation is
visible. Any chat model that emits reasoning works; substitute paths freely.

## 1. Get the gateway

```sh
cd space-inference-gateway
bundle install
bundle exec rspec        # sanity: the suite should be green
```

## 2. Tell it about your model

The gateway reads `config/models.yml` — a registry mapping a friendly **alias**
to a concrete gguf path and launch arguments. Edit it to point at your model:

```yaml
default: my-model

models:
  my-model:
    gguf: ~/models/your-model.gguf      # ~ is expanded for you
    port: 8080                          # the llama-server child port
    ctx: 8192                           # context window (per the note below)
    parallel: 1                         # concurrent slots; per-slot ctx = ctx / parallel
    offload: fit                        # "fit" → --fit on; "ngl" → -ngl -1; omit for neither
    binary: ~/.local/bin/llama-server   # optional; omit to use $LLAMA_SERVER_BINARY or PATH
```

> The gateway **spawns `llama-server` itself** — you do not start it. It builds
> the command line from this entry (always adding `--jinja`, which is what makes
> reasoning come back on its own channel).

## 3. Start the gateway

```sh
PORT=3001 bundle exec ruby bin/space-inference-gateway
# space-inference-gateway listening on http://localhost:3001
```

It is now listening, but no model is loaded yet — the gateway loads lazily on
the first request (or you can preload; see step 6).

## 4. Make an OpenAI-flavored request

In another terminal:

```sh
curl -s http://localhost:3001/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
        "model": "my-model",
        "messages": [{"role":"user","content":"What is 17 times 23? Think it through."}]
      }' | jq
```

The **first** call blocks while the gateway spawns `llama-server` and waits for
its `/health` to go green (cold start can take 10–30s). Subsequent calls are
fast. In the response, note:

- `choices[0].message.content` — the clean answer, **no `<think>` tags**;
- `choices[0].message.reasoning_content` — the model's reasoning, lifted out;
- `model` — your alias, not the gguf path;
- `usage` — exactly three integer keys, no upstream `timings`.

## 5. Make an Anthropic-flavored request

Same model, same server, different shape:

```sh
curl -s http://localhost:3001/v1/messages \
  -H 'content-type: application/json' \
  -d '{
        "model": "my-model",
        "max_tokens": 512,
        "messages": [{"role":"user","content":"What is 17 times 23? Think it through."}]
      }' | jq
```

Here the reasoning comes back as a `thinking` content block alongside the `text`
block — the native Anthropic shape Claude Code expects — with no `signature`
field.

## 6. Drive the model lifecycle explicitly (optional)

```sh
curl -s http://localhost:3001/v1/models | jq          # list known aliases
curl -s -XPOST http://localhost:3001/v1/load    -d '{"model":"my-model"}' | jq   # preload
curl -s http://localhost:3001/v1/load-progress | jq   # readiness phase
curl -s -XPOST http://localhost:3001/v1/unload  -d '{}' | jq                     # stop the child
```

## 7. Try streaming

Add `"stream": true` to either request and watch SSE arrive incrementally —
`reasoning_content` deltas then `content` deltas (OpenAI), or `thinking_delta`
then `text_delta` events (Anthropic), ending with `data: [DONE]` on the OpenAI
side.

## What you just proved

One `llama-server`, supervised by the gateway, served two API dialects with
reasoning cleanly separated and schemas conformant. That is the entire mission
in miniature. To make it reachable from another machine securely, add the
[TLS edge and loopback shim](how-to/deploy-on-the-studio.md). To understand why
that shim has to exist at all, read the
[architecture explanation](explanation/architecture.md).
