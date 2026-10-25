# ROADMAP

## Recently landed (context)

- **2026-10 — single wire.** The synthesized second-wire layer — its
  normalizer, request translation, token-count estimate, and error-relay
  arms, plus the now-redundant per-client metric label — is removed entirely
  (decision record: BRIEF §2). pi is the client of record and speaks the
  OpenAI wire. Future second-wire support would be a `fast-messages`
  sibling gem, not in-gateway synthesis.
- **2026-08-05 — single-flight swap + wedge-proof supervision (I01/I02).**
  Engine transitions (active/busy check, swap, generation reservation) are
  atomic behind one gate, closing the swap TOCTOU and the cross-alias
  busy-guard race. Kills are verified (TERM→KILL, bounded waits, port
  confirmed released); the supervisor reaps stale listeners on its engine
  port itself (`lsof`, engine-agnostic — the launcher's optiq-only `pkill`
  is gone); the zombie watchdog now also feeds from buffered (non-stream)
  requests; the bin traps SIGTERM/SIGINT and tears the engine down on exit;
  ≥100B models get per-model `readiness_timeout` budgets.
- **2026-08 — inference telemetry.** Prometheus `/metrics` with generation
  phases, TTFT, verbatim usage; Grafana dashboard in `deploy/observability/`.
- **2026-07 — engine re-home: llama.cpp → mlx/optiq.** The gateway began
  supervising `mlx_lm.server` and `optiq serve` (both OpenAI-HTTP upstreams)
  and synthesized a second client wire on top of them (that synthesis layer
  was removed in 2026-10). `ErrorRelay::Oai` and the `spec/fixtures/llamacpp/`
  captures were deliberately retained so a future llama-server registry entry
  works again without archaeology.
- **2026-07 — Ansible deploy.** `deploy/run.sh` → `ansible-pull` replaced the
  rsync + manual-launchctl workflow. See
  [deploy/ansible/README.md](deploy/ansible/README.md).

## Open

- **Vendor `forward_tls.py`.** The connect-clients guide installs the loopback
  shim from outside the repo; there is no canonical versioned copy. It belongs
  in-repo (not in the gem — it must run under `/usr/bin/python3` on the laptop).
- **Gemspec `spec.files` omits `config/models.yml`** even though
  `ModelRegistry::DEFAULT_CONFIG_PATH` points into the gem. Harmless while we
  run from a checkout; wrong the day the gem is installed standalone.
- **No context-window knob.** The llama.cpp-era `ctx`/`parallel` tuning has no
  mlx/optiq analogue exposed in the registry; `extra_args` is the escape hatch.
  Add first-class keys if a real need shows up.
- **Shared fixture-path constant.** The normalizer spec defines a top-level
  `LLAMACPP_FIXTURE_PATH`; harmless, but hoist to a shared spec helper if
  another spec ever needs it.
