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

## Smaller carry-forwards

These are tracked from the build and are non-blocking:

- **Startup orphan-reap belongs in the supervisor.** `run-proxy.sh` currently
  `pkill`s a stray `llama-server --port 8080` before launch. A startup reap
  inside `LlamaServerSupervisor` (kill anything already bound to the target
  port) would make the gem self-sufficient and drop the launcher's hard-coded
  port.
- **Shared fixture-path constant.** Both normalizer specs define a top-level
  `LLAMACPP_FIXTURE_PATH`, producing a harmless "already initialized constant"
  warning in the combined suite. Hoist to one shared spec helper.
- **Anthropic stream stop-dispatch ignores event `index`.** Correct for the
  current 2-block (thinking + text) shape; revisit if `llama-server` ever emits
  more than two content blocks.
- **TOCTOU between `ensure_active_if_known` and `begin_generation`.** Two
  concurrent first-requests can both pass the busy-guard. Single-user in
  practice; tighten if the gateway grows real concurrency.
