# How-to: add and tune models

Register a new model, pick the right engine flags, and roll it out. The
registry is [`config/models.yml`](../../config/models.yml); the alias key is
what clients pass in the request's `model` field, what `GET /v1/models`
lists, and what responses echo back. The full key schema lives in the
[configuration reference](../reference/configuration.md#the-model-registry).

## Add an mlx model

```yaml
models:
  my-new-model:
    engine: mlx
    model: mlx-community/Some-Model-4bit      # HF repo id, passed to --model verbatim
    port: 8080
    venv: ~/.venv-vllm-metal/bin/python       # the interpreter that runs mlx_lm.server
    decode_concurrency: 32
    prompt_concurrency: 8
```

Then decide two things:

**1. Does it reason?** If the model emits `<think>…</think>` (DeepSeek-R1
distills, Nemotron, most "reasoning" finetunes), leave `supports_reasoning`
unset (defaults on) — the gateway lifts the tags onto the proper reasoning
channel. If it's a plain instruct model whose chat template emits content
only (e.g. `hermes-4-70b`), set `supports_reasoning: false` to keep the
normalizer in passthrough; otherwise a literal `<think>` in ordinary output
would be misclassified as reasoning.

**2. Does its tokenizer hit the mlx eos-stop bug?** mlx_lm 0.31.3 has a bug
where the `eos_token_id`-based stop doesn't fire for some models — observed
with Llama-3.3-tokenizer models (`hermes-4-70b`, `deepseek-r1-70b`), which
generate straight past `<|eot_id|>`. String-based stop detection is
unaffected, so inject the eos token as an explicit stop sequence:

```yaml
    stop_tokens:
      - <|eot_id|>
```

The gateway merges `stop_tokens` into every request's `stop` field
(de-duplicated) for that model. If a new model runs past where it should
stop, check its tokenizer's eos token and add it here.

## Add an optiq model

```yaml
models:
  my-optiq-model:
    engine: optiq
    model: mlx-community/Some-Model-OptiQ-4bit
    port: 8080
    venv: ~/.venv-optiq/bin/optiq             # NB: the optiq BINARY, not a python
    mtp: true                                  # multi-token prediction
    mtp_depth: 2
    max_concurrent: 8
```

Note the `venv` asymmetry: for mlx it's a Python interpreter (the supervisor
runs `<venv> -m mlx_lm.server …`); for optiq it's the optiq binary itself
(`<venv> serve …`). The supervisor always adds `--no-auth` for optiq.

## Know the model-field semantics per engine

- **mlx validates the request's `model` field** against what it loaded — and
  tries to *fetch unknown names from Hugging Face*. So the gateway rewrites
  the field to the entry's HF repo id before forwarding; your alias never
  reaches the engine.
- **optiq's single-model mode accepts any value** — the field is a label, no
  rewrite needed.

Either way clients keep using the alias; this is engine plumbing, documented
so a surprising engine log line ("fetching model …") makes sense.

## Tune concurrency

There is no context-window knob (that was a llama.cpp-era concept); the
levers are request concurrency:

| Engine | Key | Meaning |
|---|---|---|
| mlx | `decode_concurrency` | parallel decode slots |
| mlx | `prompt_concurrency` | parallel prefill slots |
| mlx | `prompt_cache_size` | prompt-cache entries |
| optiq | `max_concurrent` | total concurrent requests |
| optiq | `mtp`, `mtp_depth` | multi-token prediction (speculative decode depth) |
| both | `readiness_timeout` | per-model readiness budget in seconds (default 120) — set it for ≥100B models a flat budget would kill mid-load; the 120B entries use 300 |
| both | `extra_args` | verbatim extra argv for anything else |

Current practice from the registry: big MoE models run 32/8
(`qwen3-122b-a10b`, `nemotron-3-super`); dense 70Bs run 8/4.

## Roll it out

```sh
bundle exec rspec                      # the registry is loaded by the suite; typos surface here
git commit -am 'registry: add my-new-model'
git push
ssh eric@studio.slush.systems 'bash -s' < deploy/run.sh
```

The apply pulls the runtime checkout and restarts the gateway. (Local
escape hatch: edit `~/src/space-inference-gateway/config/models.yml` on the
studio and `launchctl kickstart -k gui/$(id -u)/com.slushsystems.space-inference-gateway`
— but the next apply will overwrite uncommitted edits.)

## Verify

```sh
curl -s https://studio.slush.systems/v1/models | jq            # alias listed?
curl -s -X POST https://studio.slush.systems/v1/load \
  -H 'content-type: application/json' -d '{"model":"my-new-model"}'
```

Watch the child boot in `~/Library/Logs/space-inference-gateway/my-new-model.log`
on the studio. First load of an uncached model downloads from HF and will
likely 504 the readiness gate (120 s default; `readiness_timeout` raises it
per model) — pre-fetch with the venv's `huggingface-cli download <repo-id>`,
or let the download finish and load again. Then send a real generation and check the reasoning separation looks
right for your `supports_reasoning` choice. The active model is also visible
in the metrics: `sig_active_model_info{alias="my-new-model",engine="mlx"} 1`.

## Change the default

The `default:` key at the top of the registry names the model served when a
client sends an unknown/absent `model` and nothing is running yet — which is
the normal case for real clients (they send their own model names, not your
aliases). Point it at whatever the studio should wake up serving.
