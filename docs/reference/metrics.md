# Reference: metrics

`GET /metrics` serves Prometheus text exposition (0.0.4). No auth — in
production it's routed through Caddy TLS (`/metrics` is in the vhost's `@api`
matcher) and the VLAN is the boundary. All families are `sig_`-prefixed.

Two design principles shape what you'll see:

- **Usage is upstream-verbatim, never fabricated.** `sig_usage_tokens_total`
  only counts what the engine reports; a stream whose upstream omits usage
  contributes nothing. For rates, `sig_stream_deltas_total` is the proxy —
  one delta ≈ one token for the token-by-token mlx/optiq upstreams.
- **The store is `SingleThreaded`** — safe because the gateway is one Falcon
  reactor of cooperative fibers and metric increments never await; no mutex
  overhead.

## Request traffic

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `sig_requests_total` | counter | `flavor`, `stream` | inference requests accepted (`flavor`: `oai`/`ant`) |
| `sig_request_duration_seconds` | histogram | `flavor`, `stream` | non-stream: whole request; streaming: observed at stream teardown, so it spans the full generation |
| `sig_time_to_first_token_seconds` | histogram | `flavor` | stream open → first delta (prefill duration) |
| `sig_generation_phase` | gauge | `phase` | streaming generations currently in `prefill` vs `decode` |
| `sig_active_generations` | gauge | — | streaming generations in flight |
| `sig_stream_deltas_total` | counter | `flavor`, `channel` | streamed deltas by channel (`reasoning`/`content`/`tool_args`) |
| `sig_usage_tokens_total` | counter | `flavor`, `kind` | upstream-reported tokens (`prompt`/`completion`) |
| `sig_generation_stops_total` | counter | `flavor`, `stop_reason` | end-of-output events, upstream's verbatim finish/stop reason |

## Engine child

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `sig_child_up` | gauge | — | 1 while the engine child runs |
| `sig_child_pid` | gauge | — | child PID (0 when stopped) |
| `sig_child_rss_bytes` | gauge | — | child RSS via `ps -o rss=` (sampled on scrape) |
| `sig_child_starts_total` | counter | — | successful child starts |
| `sig_child_zombie_restarts_total` | counter | — | watchdog-triggered restarts ([how it fires](configuration.md#supervisor-timeouts-and-the-zombie-watchdog)) |
| `sig_active_model_info` | gauge | `alias`, `engine` | info-style: the active model's label combo is 1, at most one at a time |

## Control plane and errors

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `sig_model_operation_results_total` | counter | `operation`, `result` | load/unload outcomes (`success`/`busy`/`timeout`/…) |
| `sig_upstream_errors_total` | counter | `status`, `flavor` | engine errors relayed to clients; includes the silent mid-stream 504s an already-200 SSE response can't carry |
| `sig_keepalive_comments_total` | counter | `flavor` | `: keepalive` SSE comments emitted during upstream silence |

## Scraping and dashboard

Prometheus scrapes **through the TLS edge** — that's why `/metrics` shares
the Caddy route with `/v1/*`. The operator-applied snippet lives at
[`deploy/observability/prometheus-scrape.yml`](../../deploy/observability/prometheus-scrape.yml):

```yaml
scrape_configs:
  - job_name: space_inference_gateway
    scheme: https
    metrics_path: /metrics
    static_configs:
      - targets: [studio.slush.systems:443]
    scrape_interval: 15s
    scrape_timeout: 10s
```

Merge it into `prometheus.yml` and reload (`POST /-/reload` or `kill -HUP`).

A ready-made Grafana dashboard (uid `space-inference-gateway`, rows: Request
Traffic / Child Process / Control Plane / Errors & Keepalives) is at
[`deploy/observability/grafana-dashboard.json`](../../deploy/observability/grafana-dashboard.json)
— import it against the Prometheus datasource.
