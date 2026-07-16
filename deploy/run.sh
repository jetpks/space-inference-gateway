#!/usr/bin/env bash
# deploy/run.sh — provision studio.slush.systems via ansible-pull.
#
# ansible-pull clones the repo into a fresh temp checkout (~/.ansible/pull/…)
# and runs the playbook from THERE, not from ~/src/space-inference-gateway.
# This matters because the playbook's own `clone or pull gateway repository`
# task updates the runtime checkout at ~/src/space-inference-gateway — if the
# playbook ran from that same checkout, a pull would mutate the playbook's
# source files mid-run and ansible would execute a stale in-memory copy
# (the self-modifying-playbook problem). ansible-pull removes that hazard.
#
# Invoke from anywhere on the studio (no local checkout required):
#
#   ssh eric@studio.slush.systems 'bash -s' < deploy/run.sh
#
# or locally after a clone:
#
#   ./deploy/run.sh
#
# Env overrides:
#   GATEWAY_REPO   — repo URL to pull from (default: upstream HTTPS)
#   ANSIBLE_EXTRA  — extra vars appended to ansible-pull (e.g. '-e foo=bar')

set -euo pipefail

GATEWAY_REPO="${GATEWAY_REPO:-https://github.com/jetpks/space-inference-gateway.git}"
PLAYBOOK="deploy/ansible/site.yaml"
INVENTORY="deploy/ansible/hosts"
ANSIBLE_VENV="$HOME/.venv-ansible"

# /opt/homebrew/bin is absent from PATH over non-interactive SSH; prepend it
# so ansible-pull, op, mise, go, etc. are resolvable.
export PATH="/opt/homebrew/bin:$PATH"

# Homebrew's pythons are PEP-668 externally-managed, so the ansible controller
# interpreter (auto-discovered as python3.14) is missing `packaging` and
# `virtualenv`, which the pip/venv modules require. Use a small dedicated
# controller venv, bootstrapping it on first run.
if [ ! -x "$ANSIBLE_VENV/bin/python" ]; then
  echo ">> bootstrapping ansible controller venv at $ANSIBLE_VENV"
  /opt/homebrew/bin/python3.12 -m venv "$ANSIBLE_VENV"
  "$ANSIBLE_VENV/bin/pip" install --quiet packaging virtualenv
fi

# Pin the controller interpreter to the venv python and put it on PATH so the
# `pip` module can find `virtualenv` when creating the optiq/mlx venvs.
export PATH="$ANSIBLE_VENV/bin:$PATH"

# ansible-pull clones into a temp dir and runs the playbook from there. The
# collections (community.general, ansible.posix) ship with `brew install
# ansible` and live in the homebrew ansible's collection path, so no
# ansible-galaxy step is needed.
exec ansible-pull \
  --url "$GATEWAY_REPO" \
  --checkout main \
  --inventory "$INVENTORY" \
  --extra-vars "ansible_python_interpreter=$ANSIBLE_VENV/bin/python" \
  ${ANSIBLE_EXTRA:-} \
  "$PLAYBOOK"
