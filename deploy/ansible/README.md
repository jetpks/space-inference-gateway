# deploy/ansible

Ansible playbook to deploy and keep the gateway alive on `studio.slush.systems`
(macOS, user-level, no root/become). Replaces the retired rsync + manual
launchctl workflow documented in `docs/how-to/deploy-on-the-studio.md`.

## Pre-requisites (operator, one-time)

1. **1Password CLI auth** — place a service-account token at
   `~/.config/secret/op` (mode 0600) as a shell snippet:
   `export OP_SERVICE_ACCOUNT_TOKEN=ops_...`. `op` does not read this file
   automatically, so `run-caddy.sh` sources it to load the token before
   calling `op read 'op://...'`. The playbook does not create or read this
   file; it only verifies `op` is reachable.
2. **HF model cache** — model artifacts live in `~/.cache/huggingface/hub`.
   The playbook ensures the directory exists; the operator moves the actual
   model files from the old user's cache (one-time, manual).
3. **Ansible collections** — `ansible-galaxy collection install -r deploy/ansible/requirements.yaml`
   (all are already present on `brew install ansible`).

## How to apply

Use the wrapper at `deploy/run.sh`, which invokes `ansible-pull` so the
playbook runs from a fresh clone rather than the live `~/src/space-inference-gateway`
checkout it is itself updating (avoids the self-modifying-playbook problem):

```sh
# from anywhere on the studio (no local checkout needed):
ssh eric@studio.slush.systems 'bash -s' < deploy/run.sh

# or, after a clone:
./deploy/run.sh
```

The wrapper bootstraps a small controller venv (`~/.venv-ansible`) for
`packaging`/`virtualenv` (Homebrew's pythons are PEP-668 externally-managed),
prepends `/opt/homebrew/bin` to PATH for non-interactive SSH, and pins
`ansible_python_interpreter` to that venv. Override the repo with
`GATEWAY_REPO=…` or pass extra vars with `ANSIBLE_EXTRA=…`.

## What the playbook manages

| Scope item | Result |
|---|---|
| Homebrew PATH | `/opt/homebrew/bin` added to `~/.zprofile` |
| op CLI | verified on PATH; service-account token sourced at apply time from `~/.config/secret/op` (operator-managed) |
| mise + Ruby | `ruby@4.0.5` installed and set as global via mise |
| Gateway checkout | `~/src/space-inference-gateway` cloned/pulled each apply (runtime checkout; the playbook itself runs from the ansible-pull clone) |
| bundle install | runs before every gateway restart (load-bearing guard) |
| Gateway launchd agent | `com.slushsystems.space-inference-gateway` on port 9292, KeepAlive |
| optiq venv | `~/.venv-optiq` with `mlx-optiq` (path matches `config/models.yml`) |
| mlx venv | `~/.venv-vllm-metal` with `mlx-lm` (path matches `config/models.yml`) |
| HF cache dir | `~/.cache/huggingface/hub` created, ownership set |
| Caddy | xcaddy build with DO plugin → `~/caddy-build/caddy`; `com.slushsystems.caddy` launchd agent on :443 |

## Caddy vhost routing

`Caddyfile.j2` path-routes `studio.slush.systems`: `/v1/* /metrics` goes to
the gateway (`reverse_proxy` with `flush_interval -1` so streaming completions
aren't buffered), and everything else falls through to
`import {{ caddy_config_dir }}/caddy.d/*.caddy` — a glob import that is a
no-op until another role drops a `*.caddy` snippet (e.g. a catch-all `handle`
for a separate app) into `~/.config/caddy/caddy.d/`. The playbook ensures
that directory exists so the import always has a home, even before any
snippet is present.

## Secrets

No secret values are committed. The DigitalOcean API key for Caddy's DNS-01
challenge is fetched at runtime via `op read '{{ caddy_do_api_key_ref }}'`
in `run-caddy.sh`. Override `caddy_do_api_key_ref` in a vars file if the
1Password item path differs.
