# Roadmap

Forward-looking work for `space-inference-gateway`. Done milestones live in the
git history and the mission archive; this file is what's *next*.

## ✅ DONE (2026-06-30): switched to stock `llama.cpp`; dropped the Unsloth build

The gateway now spawns Homebrew's stock `llama-server` (`/opt/homebrew/bin/llama-server`,
build `9840`) instead of the Unsloth-built binary (`~/.unsloth/llama.cpp/llama-server`,
build `9827`). Unsloth is fully out of the serving path.

What was done:

1. `brew install llama.cpp` on the studio (build 9840, `/opt/homebrew/bin/llama-server`).
2. Confirmed it accepts the gateway's exact `build_argv` flags (`--fit`,
   `--flash-attn`, `--no-context-shift`, `--jinja`, `--parallel`).
3. Smoke-tested the stock binary against our gguf on a spare port: `--jinja`
   yields the native reasoning channel (`reasoning_content`), and the extra
   fields it bolts on (`timings`, `prompt_tokens_details`, `system_fingerprint`)
   are exactly the ones the I06 normalizers already strip/handle. No fixture
   re-capture needed.
4. Repointed `config/models.yml` `binary:` → `/opt/homebrew/bin/llama-server`
   (laptop source + studio copy) and updated `run-proxy.sh`'s
   `LLAMA_SERVER_BINARY` to match (`.bak` backups left on the studio).
5. Restarted under launchd; verified live end-to-end through the gateway and
   through Caddy `:443`: OAI `/v1/chat/completions` (reasoning separated, clean
   content, alias echoed, `timings` stripped, 3-key usage) and Anthropic
   `/v1/messages` (`thinking`+`text` blocks, no `signature`, `end_turn`). The
   spawned `:8080` child is the brew binary.

**Remaining optional cleanup:** the `~/.unsloth` tree is left in place as a
rollback safety net (it is no longer referenced). Remove it / uninstall Unsloth
Studio once you're satisfied. Note the gguf lives in `~/.cache/huggingface`, not
`~/.unsloth`, so removing the Unsloth tree does not touch the model.

## Reconcile the deployed names with the rename

The repo was renamed `local-inference-proxy` → `space-inference-gateway`
(executable now `bin/space-inference-gateway`). The studio still runs an older
rsync'd copy at `~/local-inference-proxy` whose `run-proxy.sh` execs
`bin/local-inference-proxy`. Re-sync the current tree, rename the deploy
directory and launcher references, and update the launchd plist label/path to
match. (Until then, the deployed launcher works only because the old binary
name still exists in the rsync'd copy.)

## ✅ DONE (2026-08-05): single-flight swap + wedge-proof supervision (I01)

Closed the swap TOCTOU and the undetectable-zombie wedge, both diagnosed live
on the deployed Mac Studio instance:

- `ModelController`'s active/busy decision, the engine transition, and the
  generation reservation are now atomic (one `Async::Semaphore(1)` gate) —
  concurrent same-alias requests coalesce onto a single transition, and the
  cross-alias 409-busy guard is now race-free (a generation is counted before
  any concurrent swap decision can observe a zero count).
- `InferenceServerSupervisor#stop` always clears tracked state (even for an
  already-dead child), so an externally-crashed engine is observed and the
  next request respawns cleanly. Kill is verified (TERM→KILL, bounded waits)
  and the port is confirmed released before a successor spawns, closing the
  "corpse holds the port, `running?` sticks false forever" wedge.
- The zombie watchdog (I04) now feeds from the buffered (non-stream) request
  path too, not just streaming headers-timeouts — an eval workload (always
  non-streaming) now recovers instead of wedging.
- **Startup orphan-reap belongs in the supervisor** (below) is done: the
  supervisor reaps any pre-existing listener on the configured engine port
  itself (via `lsof`, engine-agnostic), once per port per process lifetime.
  The launcher's `optiq`-only `pkill` in `run-gateway.sh.j2` is removed.
- **TOCTOU between `ensure_active_if_known` and `begin_generation`** (below)
  is done: the reservation now happens atomically as part of the swap
  decision itself.
- `bin/space-inference-gateway` now traps SIGTERM/SIGINT and tears down the
  engine child before exit, so a gateway restart no longer orphans it.
- Per-model readiness budgets (`readiness_timeout:` in `config/models.yml`)
  replace the flat 120s budget for the ≥100B entries.

## Smaller carry-forwards

These are tracked from the build and are non-blocking:

- **Shared fixture-path constant.** Both normalizer specs define a top-level
  `LLAMACPP_FIXTURE_PATH`, producing a harmless "already initialized constant"
  warning in the combined suite. Hoist to one shared spec helper.
- **Anthropic stream stop-dispatch ignores event `index`.** Correct for the
  current 2-block (thinking + text) shape; revisit if `llama-server` ever emits
  more than two content blocks.
