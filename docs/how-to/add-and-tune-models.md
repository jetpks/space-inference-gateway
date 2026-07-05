# How-to: add a model and tune the context window

Everything model-related lives in one file: `config/models.yml`, the **registry**
that maps a friendly alias to a concrete gguf and `llama-server` launch args.
The gateway builds the `llama-server` command line from a registry entry; you
never write that command line yourself.

## Add a model

Add an entry under `models:`. The alias (the key) is what clients pass as
`model`, what `GET /v1/models` lists, and what the responses echo back.

```yaml
default: qwen3-35b-a3b

models:
  qwen3-35b-a3b:
    gguf: ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-MTP-GGUF/snapshots/<sha>/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
    port: 8080
    ctx: 524288
    parallel: 2
    offload: fit
    binary: ~/.unsloth/llama.cpp/llama-server

  my-other-model:
    gguf: ~/models/other.gguf
    port: 8081
    ctx: 32768
    parallel: 1
```

Field reference:

| Key          | Meaning                                                                 |
|--------------|------------------------------------------------------------------------|
| `gguf`       | Path to the model file. `~` is expanded and made absolute.             |
| `port`       | Localhost port the `llama-server` child listens on.                     |
| `ctx`        | Total context (KV) across all slots → `-c`. `0`/omitted → `-c 0`.       |
| `parallel`   | Concurrent slots → `--parallel`. **Per-slot context = `ctx / parallel`.** |
| `offload`    | `fit` → `--fit on`; `ngl` → `-ngl -1`; omit → neither.                  |
| `binary`     | Optional per-model `llama-server` path (`~` expanded). Falls back to `$LLAMA_SERVER_BINARY`, then `llama-server` on `PATH`. |
| `extra_args` | Optional array appended verbatim to the command line.                   |
| `supports_reasoning` | Set `false` to disable reasoning separation for a non-reasoning model (default: enabled). |

Every spawn always gets `--flash-attn on`, `--no-context-shift`, and **`--jinja`**
(applies the model's chat template so reasoning comes back on its own channel —
the gateway's normalization depends on it). The full assembled command line is
documented in the [configuration reference](../reference/configuration.md#how-the-command-line-is-built).

After editing the file, restart the gateway (locally: stop/start; on the studio:
`launchctl kickstart -k …` — see [deploy](deploy-on-the-studio.md)). To switch
the live model without editing config, just send a request with a different
registered `model` (lazy auto-swap) or `POST /v1/load`.

## Tune the context window

The two knobs are `ctx` (total KV across slots) and `parallel` (slots).
**Per-request context = `ctx / parallel`.** KV memory scales with total `ctx`.
The per-slot maximum is the model's trained window (`n_ctx_train`).

For the reference Qwen3.6-35B-A3B (trained window 262144), values tried during
bring-up:

| `ctx`    | `parallel` | per-slot | Outcome                                                      |
|----------|------------|----------|-------------------------------------------------------------|
| 8192     | 2          | 4096     | ❌ Claude Code's ~25k-token prompt overflowed → 502         |
| 32768    | 1          | 32768    | ✅ loads; single slot                                        |
| 262144   | 4          | 65536    | ✅ four 64k slots                                            |
| **524288** | **2**    | **262144** | ✅ **production** — two slots, each the full trained window |

The production setting (`524288 / 2`) gives every request the model's full 262k
window with two concurrent. Measured live: child RSS ≈ 31.6 GB (this MoE has
aggressive GQA, ≈ 27 KB/token KV), box at ~39 GB free.

To change it:

```sh
# edit config/models.yml ctx + parallel, then on the studio:
rsync ...                                  # sync the change to the box (see deploy)
launchctl kickstart -k gui/$(id -u)/com.example.local-inference-proxy
```

Rules of thumb:

- **Clients see "context overflow" / 502** → per-slot too small. Raise `ctx` or
  lower `parallel`.
- **OOM / won't load** → total `ctx` too large for VRAM/RAM. Lower `ctx`.
- **Need more concurrency** → raise `parallel`, but watch per-slot size and KV
  growth.
- Never set per-slot (`ctx / parallel`) above the model's `n_ctx_train`.

## Verify

```sh
curl -s http://127.0.0.1:9292/v1/models | jq           # new alias listed?
curl -s -XPOST http://127.0.0.1:9292/v1/load -d '{"model":"my-other-model"}' | jq
tail -f "${TMPDIR:-/tmp}/space-inference-gateway/my-other-model.log"   # child boot log
```
