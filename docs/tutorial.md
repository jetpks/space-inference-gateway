# Tutorial: your first end-to-end run

By the end of this page you will have the gateway running locally, supervising
a real `mlx_vlm.server`, and answering OpenAI-wire requests — including
separated reasoning. Everything happens on one machine;
no Caddy, no shim, no deploy.

## What you need

- An Apple-silicon Mac with enough free disk and RAM for a real model (the
  demo model below is a ~27 GB download and wants ~32 GB of memory headroom).
- Ruby ≥ 4.0 (`mise use -g ruby@4.0` matches production — see
  [install dependencies](how-to/install-dependencies.md)).
- A Python 3.12 venv with mlx-vlm at the path the registry expects:

  ```sh
  /opt/homebrew/bin/python3.12 -m venv ~/.venv-mlx-vlm
  ~/.venv-mlx-vlm/bin/pip install 'mlx-vlm==0.6.13'
  ```

  `config/models.yml` points at this venv, so keep the name (or edit the
  registry's `venv:` keys to match yours). The `mlx`-engine entries in the
  registry use a differently-named venv (`~/.venv-vllm-metal` — historical);
  you only need it if you load one of those aliases.

## 1. Install and prove the code works

```sh
bundle install
bundle exec rspec        # the whole suite runs against fake upstreams — no model needed
bundle exec rubocop
```

## 2. Meet the model registry

Open [`config/models.yml`](../config/models.yml). Each entry maps a friendly
**alias** (what clients put in the request's `model` field) to an engine launch
recipe:

```yaml
qwen3.8-27b-mxfp8-concurrent4:
  engine: mlx-vlm                           # which child to spawn
  model: mlx-community/Qwen3.8-27B-mxfp8    # HF repo id, passed to --model
  port: 8080                                # child's listen port
  venv: ~/.venv-mlx-vlm/bin/mlx_vlm.server  # engine binary, invoked directly
  enable_thinking: true
  max_num_seqs: 4
  supports_reasoning: true
```

We'll use `qwen3.8-27b-mxfp8-concurrent4` — the batch-tuned operating point
of a 27B checkpoint at mxfp8, a reasonable size for a first run. Note that
`venv:` means different things per engine: the `mlx` engine wants the python
interpreter, while `mlx-vlm` (like `optiq`) wants the engine's own
console-script binary, invoked directly. The full key reference is in
[configuration](reference/configuration.md).

## 3. Pre-fetch the model

The engine downloads the model from Hugging Face on first launch — but the
supervisor only waits **120 seconds** (the default readiness budget; big
models raise it via `readiness_timeout:`) for the child to become healthy,
and a 27 GB download won't finish inside that window. Fetch it ahead of time with
the venv's own CLI:

```sh
~/.venv-mlx-vlm/bin/huggingface-cli download mlx-community/Qwen3.8-27B-mxfp8
```

(If you skip this, the first `load` will 504 with `Model load timed out` while
the download continues in the background; retrying after it finishes works,
but pre-fetching is kinder.)

## 4. Boot the gateway

```sh
PORT=3001 bundle exec ruby bin/space-inference-gateway
```

You'll see `space-inference-gateway listening on http://localhost:3001`. No
engine is running yet — children spawn lazily, on the first request or an
explicit load.

## 5. Look around the control plane

```sh
curl -s http://localhost:3001/v1/models | jq
```

Every registry alias is listed. Now load the model explicitly (this is also
what you'd do in production to take the cold start off the first request):

```sh
curl -s -X POST http://localhost:3001/v1/load \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3.8-27b-mxfp8-concurrent4"}' | jq
```

This blocks while the supervisor spawns `mlx_vlm.server` and polls its
`/health` endpoint, then returns
`{"status":"loaded","model_path":"mlx-community/Qwen3.8-27B-mxfp8"}`.
Watch the child's own logs in another terminal if you're curious (the alias's
dots are sanitized to underscores in the filename):

```sh
tail -f ~/Library/Logs/space-inference-gateway/qwen3_8-27b-mxfp8-concurrent4.log
```

`GET /v1/load-progress` reports `"phase":"ready"` once it's up.

## 6. First generation

```sh
curl -s -X POST http://localhost:3001/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen3.8-27b-mxfp8-concurrent4",
    "messages": [{"role": "user", "content": "What is 17 times 23?"}],
    "max_tokens": 512
  }' | jq
```

Note the shape of `choices[0].message`: the model's chain-of-thought is in
`reasoning_content`, the answer alone is in `content`. Nothing non-standard
survives — the response validates against a strict OpenAI schema.

## 7. Streaming

```sh
curl -sN -X POST http://localhost:3001/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "qwen3.8-27b-mxfp8-concurrent4",
    "messages": [{"role": "user", "content": "Count to five."}],
    "stream": true, "max_tokens": 256
  }'
```

SSE chunks stream out with `reasoning_content` deltas first, then `content`
deltas, then a `finish_reason` chunk and `data: [DONE]`. If the engine goes
quiet for 8 s (long prompts spend a while in prefill), you'll see
`: keepalive` comment lines — SSE-legal, ignored by client SDKs, and the
reason idle HTTP timers don't kill long generations.

## 8. Peek at the telemetry

```sh
curl -s http://localhost:3001/metrics | grep -E '^sig_' | head -20
```

Requests, child PID/RSS, generation phases, token usage — the whole
[metrics surface](reference/metrics.md), no setup required.

## 9. Clean up

```sh
curl -s -X POST http://localhost:3001/v1/unload -H 'content-type: application/json' -d '{}' | jq
```

The supervisor TERMs (then KILLs, if needed) the engine's process group.
Ctrl-C the gateway; nothing is left running.

## What you just saw

One supervised engine child served the OpenAI wire, with reasoning separated
and schemas enforced, plus a control plane for loading and swapping models.
That's the whole idea. From here:

- Wire up your real clients: [connect clients](how-to/connect-clients.md).
- Put it behind TLS under launchd: [deploy on the studio](how-to/deploy-on-the-studio.md).
- Register your own models: [add & tune models](how-to/add-and-tune-models.md).
- Understand why it's shaped this way: [architecture](explanation/architecture.md).
