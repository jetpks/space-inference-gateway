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
#
# Concurrent runs are serialized via a lock dir at ~/.deploy-run.lock: a
# second invocation refuses to start while a live run holds it, and reclaims
# it automatically if the previous holder's pid is dead.

set -euo pipefail

GATEWAY_REPO="${GATEWAY_REPO:-https://github.com/jetpks/space-inference-gateway.git}"
PLAYBOOK="deploy/ansible/site.yaml"
INVENTORY="deploy/ansible/hosts"
ANSIBLE_VENV="$HOME/.venv-ansible"

# /opt/homebrew/bin is absent from PATH over non-interactive SSH; prepend it
# so ansible-pull, op, mise, go, etc. are resolvable.
export PATH="/opt/homebrew/bin:$PATH"

# Concurrency lock — a future cron ansible-pull could overlap with a manual
# run and interleave applies. macOS has no flock(1), and shlock isn't
# guaranteed present on every target host, so an atomic `mkdir` is the lock
# primitive (atomic, POSIX, nothing to install). This script runs as
# `ssh ... 'bash -s' < deploy/run.sh`, so there's no file on disk to derive a
# lock path from $0 — use a fixed path under $HOME instead. The locker's pid
# is stored inside so a dead previous run's lock is detected and reclaimed
# rather than wedging deploys forever. Reclaiming a dead lock re-attempts the
# same guarded `mkdir` used for the fast path, so the only way to own the
# lock is a `mkdir` call this process itself made succeed; a waiter that
# loses that race refuses instead of assuming ownership.
LOCK_DIR="$HOME/.deploy-run.lock"
LOCK_OWNED=0

release_lock() {
  [ "$LOCK_OWNED" = 1 ] && rm -rf "$LOCK_DIR"
  return 0
}
trap release_lock EXIT INT TERM

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ >"$LOCK_DIR/pid"
    LOCK_OWNED=1
    return
  fi

  local locker_pid
  locker_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$locker_pid" ] && kill -0 "$locker_pid" 2>/dev/null; then
    echo ">> deploy already running under pid $locker_pid ($LOCK_DIR) — refusing to start" >&2
    exit 1
  fi

  echo ">> reclaiming stale lock left by dead pid ${locker_pid:-unknown} ($LOCK_DIR)"
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo ">> lost the race to reclaim the stale lock ($LOCK_DIR) to another waiter — refusing to start" >&2
    exit 1
  fi
  echo $$ >"$LOCK_DIR/pid"
  LOCK_OWNED=1
}

acquire_lock

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
ansible-pull \
  --url "$GATEWAY_REPO" \
  --checkout main \
  --inventory "$INVENTORY" \
  --extra-vars "ansible_python_interpreter=$ANSIBLE_VENV/bin/python" \
  ${ANSIBLE_EXTRA:-} \
  "$PLAYBOOK"
