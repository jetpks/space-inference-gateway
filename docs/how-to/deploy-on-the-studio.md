# How-to: deploy on the studio

Deploy the gateway and its Caddy TLS edge on `studio.slush.systems` (macOS,
user-level launchd — no root, no `become`). The whole deploy is one Ansible
playbook; the [manual prerequisites](install-dependencies.md) (Homebrew
packages, the 1Password token file) must exist first.

## Deploy

```sh
# from anywhere, no checkout needed:
ssh eric@studio.slush.systems 'bash -s' < deploy/run.sh

# or on the studio, from a clone:
./deploy/run.sh
```

That's the entire procedure — edit config, commit, push, run it again to
roll out. Details of the machinery are in
[deploy/ansible/README.md](../../deploy/ansible/README.md); the short version:

- `deploy/run.sh` wraps **`ansible-pull`**, which clones the repo into a fresh
  temp checkout and runs the playbook from *there* — not from
  `~/src/space-inference-gateway`, which the playbook itself updates
  (avoiding the self-modifying-playbook problem).
- Concurrent runs are serialized by an atomic-`mkdir` lock at
  `~/.deploy-run.lock` (macOS has no `flock(1)`); a dead holder's lock is
  reclaimed automatically.
- A small controller venv (`~/.venv-ansible`) is bootstrapped on first run —
  Homebrew's Pythons are PEP-668 externally-managed, so the modules ansible
  needs (`packaging`, `virtualenv`) get their own interpreter.
- `force_handlers = True`: a mid-run failure still flushes restarts rather
  than leaving stale config running.
- Overrides: `GATEWAY_REPO=…` for the repo URL, `ANSIBLE_EXTRA='-e k=v'` for
  extra vars.

An apply converges, in order: Homebrew `PATH` in `~/.zprofile` → `op` CLI
verified → Ruby 4.0.5 via mise → git pull of `~/src/space-inference-gateway`
→ **`bundle install`** (load-bearing: always before a gateway restart) →
engine venvs (`~/.venv-optiq`, `~/.venv-vllm-metal`) → gateway launchd agent →
HF cache dir → xcaddy build + Caddy launchd agent. Restarts only fire on
change, via handlers.

## What ends up running

Two launchd user agents, both `RunAtLoad` + `KeepAlive`:

| | gateway | caddy |
|---|---|---|
| label | `com.slushsystems.space-inference-gateway` | `com.slushsystems.caddy` |
| runs | `~/src/space-inference-gateway/run-gateway.sh` | `~/.config/caddy/run-caddy.sh` |
| listens | `127.0.0.1:9292` | `:443` |
| log | `~/Library/Logs/space-inference-gateway.log` | `~/Library/Logs/caddy.log` |

**`run-gateway.sh`** (templated by the playbook) puts the mise Ruby and
Homebrew on `PATH` explicitly (launchd provides no login shell), exports
`PORT=9292`, and `exec env -u RUBYOPT bundle exec ruby bin/space-inference-gateway`.
Only `PORT` is set — every other [env var](../reference/configuration.md)
runs at its code default in production. Orphan cleanup needs no launcher
help: the supervisor reaps any stale listener on the engine port before its
first spawn, and the gateway tears its engine child down on SIGTERM/SIGINT.

**`run-caddy.sh`** sources `~/.config/secret/op` and fetches the DigitalOcean
key via `op read` before exec'ing `~/caddy-build/caddy`. One trap worth
knowing: `PATH` must include `/opt/homebrew/bin` **before** the `op read`
call — launchd starts agents with a minimal `PATH` where `op` isn't
resolvable, and exporting the key before fixing `PATH` silently sets it
empty, after which Caddy gets 401s from DigitalOcean.

**The Caddyfile** path-routes the domain: `/v1/*` and `/metrics` reverse-proxy
to `127.0.0.1:9292` with `flush_interval -1` (no buffering, so streaming
completions flow), and everything else falls through to a
`~/.config/caddy/caddy.d/*.caddy` glob import for other apps on the box.

## Verify

```sh
curl -s https://studio.slush.systems/v1/models | jq          # TLS edge → gateway
curl -s https://studio.slush.systems/metrics | grep sig_child_up
launchctl print gui/$(id -u)/com.slushsystems.space-inference-gateway | grep state
```

Then take the cold start off the first real request:

```sh
curl -s -X POST https://studio.slush.systems/v1/load \
  -H 'content-type: application/json' -d '{"model":"qwen3-27b-optiq"}'
```

## Operating it

- **Manual restart** (the escape hatch when you don't want a full apply):

  ```sh
  launchctl kickstart -k gui/$(id -u)/com.slushsystems.space-inference-gateway
  launchctl kickstart -k gui/$(id -u)/com.slushsystems.caddy
  ```

  First-time registration, if an agent was never loaded:
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`.

- **Logs.** Gateway stdout/stderr:
  `~/Library/Logs/space-inference-gateway.log`. Each engine child gets its own
  file: `~/Library/Logs/space-inference-gateway/<alias>.log` (spawn output,
  model load progress, per-request engine logs). Caddy/ACME:
  `~/Library/Logs/caddy.log`.

## Common pitfalls

- **Orphaned engine child holding `:8080` after a hard crash.** Handled
  automatically: the supervisor reaps any pre-existing listener on the engine
  port (via `lsof`, engine-agnostic) before its first spawn, and confirms the
  port is released before starting a successor. If you ever see a persistent
  502 anyway, check `lsof -i tcp:8080` by hand.
- **Empty 200s through the edge.** Caddy matches the HTTP `Host` header, not
  just SNI — a client (or hand-rolled forwarder) that doesn't send
  `Host: studio.slush.systems` gets a 200 with no body. The
  [loopback shim](connect-clients.md) rewrites `Host` for exactly this reason.
- **First request hangs ~a minute or more.** That's the lazy engine spawn
  plus the `/health` readiness poll (up to the model's readiness budget —
  120 s default, 300 s for the ≥100B entries). Preload with `POST /v1/load`
  after deploys.
- **Caddy up but certs failing.** Almost always the empty-`DIGITAL_OCEAN_API_KEY`
  trap above, or a stale token in 1Password — check `~/Library/Logs/caddy.log`.
