# deploy/ansible

Ansible playbook to deploy and keep the gateway alive on `studio.slush.systems`
(macOS, user-level, no root/become). Replaces the retired rsync + manual
launchctl workflow documented in `docs/how-to/deploy-on-the-studio.md`.

## Pre-requisites (operator, one-time)

1. **1Password CLI auth** — place the service-account token at
   `~/.config/secret/op` (mode 0600). The playbook does not create this file;
   it verifies `op` is reachable and reads secrets at apply time via
   `op read 'op://...'`.
2. **HF model cache** — model artifacts live in `~/.cache/huggingface/hub`.
   The playbook ensures the directory exists; the operator moves the actual
   model files from the old user's cache (one-time, manual).
3. **Ansible collections** — `ansible-galaxy collection install -r deploy/ansible/requirements.yaml`
   (all are already present on `brew install ansible`).

## How to apply

On the studio, from `~/src/space-inference-gateway`:

```sh
ansible-playbook -i deploy/ansible/hosts deploy/ansible/site.yaml
```

Or via ansible-pull (runs unattended; re-applies on every pull):

```sh
ansible-pull -U https://github.com/jetpks/space-inference-gateway.git \
  -i deploy/ansible/hosts deploy/ansible/site.yaml
```

## What the playbook manages

| Scope item | Result |
|---|---|
| Homebrew PATH | `/opt/homebrew/bin` added to `~/.zprofile` |
| op CLI | verified on PATH; token file at `~/.config/secret/op` is operator-managed |
| mise + Ruby | `ruby@4.0.5` installed and set as global via mise |
| Gateway checkout | `~/src/space-inference-gateway` cloned, pulled on re-apply |
| bundle install | runs before every gateway restart (load-bearing guard) |
| Gateway launchd agent | `com.slushsystems.space-inference-gateway` on port 9292, KeepAlive |
| optiq venv | `~/.venv-optiq` with `mlx-optiq` (path matches `config/models.yml`) |
| mlx venv | `~/.venv-vllm-metal` with `mlx-lm` (path matches `config/models.yml`) |
| HF cache dir | `~/.cache/huggingface/hub` created, ownership set |
| Caddy | xcaddy build with DO plugin → `~/caddy-build/caddy`; `com.slushsystems.caddy` launchd agent on :443 |

## Secrets

No secret values are committed. The DigitalOcean API key for Caddy's DNS-01
challenge is fetched at runtime via `op read '{{ caddy_do_api_key_ref }}'`
in `run-caddy.sh`. Override `caddy_do_api_key_ref` in a vars file if the
1Password item path differs.
