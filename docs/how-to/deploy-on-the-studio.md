# How-to: deploy on the studio

Run the gateway as a durable service behind Caddy with a real TLS certificate.
Assumes the [dependencies](install-dependencies.md) are installed. All commands
run on the studio (`ssh operator@inference.example.com`).

The shape you're building:

```
:443 Caddy (LE cert, DNS-01/DigitalOcean)
   → 127.0.0.1:9292  space-inference-gateway (launchd KeepAlive)
   → 127.0.0.1:8080  llama-server (spawned by the gateway)
```

Both Caddy and the gateway run under **launchd** with `KeepAlive` so they come
back after a crash or reboot.

> **Naming note:** the production box currently runs an older copy at
> `~/local-inference-proxy` with the launcher calling `bin/local-inference-proxy`.
> The repo has since been renamed to `space-inference-gateway`
> (`bin/space-inference-gateway`). Paths below use the current names; reconciling
> the deployed copy is a [roadmap](../../ROADMAP.md) item. There is no GitHub
> deploy remote — the laptop repo is synced to the box with `rsync`.

## 1. Sync the gateway to the box

```sh
rsync -a --delete \
  --exclude .git --exclude tmp \
  ~/path/to/space-inference-gateway/ \
  operator@inference.example.com:~/space-inference-gateway/
```

Then on the box:

```sh
cd ~/space-inference-gateway
bundle install
bundle exec rspec && bundle exec rubocop    # green before you wire launchd
```

## 2. The gateway launcher

`~/space-inference-gateway/run-proxy.sh`:

```sh
#!/bin/bash
# Reap any orphaned llama-server holding our managed port. The supervisor spawns
# the child in its own process group (pgroup:true), so a launchd restart can
# leave the old child on :8080, blocking the new gateway (→ 502). Kill it first.
pkill -f "llama-server.*--port 8080" 2>/dev/null
sleep 1

export PORT=9292
export ADVERTISED_MODEL="qwen3-35b-a3b"
export LLAMA_SERVER_BINARY="$HOME/.unsloth/llama.cpp/llama-server"   # or the brew path
# MODEL_CONFIG_PATH unset → uses the repo's committed config/models.yml
RUBYBIN="$HOME/.local/share/mise/installs/ruby/4.0.5/bin"
export PATH="$RUBYBIN:/opt/homebrew/bin:/usr/bin:/bin"
cd "$HOME/space-inference-gateway" || exit 1
exec env -u RUBYOPT bundle exec ruby bin/space-inference-gateway
```

```sh
chmod +x ~/space-inference-gateway/run-proxy.sh
```

See [configuration](../reference/configuration.md) for what each env var does.

## 3. The gateway launchd agent

`~/Library/LaunchAgents/com.example.local-inference-proxy.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.example.local-inference-proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/operator/space-inference-gateway/run-proxy.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/operator/Library/Logs/local-inference-proxy.log</string>
  <key>StandardErrorPath</key><string>/Users/operator/Library/Logs/local-inference-proxy.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.local-inference-proxy.plist
launchctl kickstart -k gui/$(id -u)/com.example.local-inference-proxy   # (re)start
```

## 4. Caddy: `Caddyfile`, launcher, agent

`~/.config/caddy/Caddyfile`:

```caddyfile
{
	email eric@ebj.dev
}

inference.example.com {
	tls {
		dns digitalocean {env.DIGITAL_OCEAN_API_KEY}
		resolvers ns1.digitalocean.com ns2.digitalocean.com ns3.digitalocean.com
		propagation_delay 45s
		propagation_timeout 5m
	}
	reverse_proxy 127.0.0.1:9292
}
```

`~/.config/caddy/run-caddy.sh`:

```sh
#!/bin/bash
set -a
[ -f "$HOME/.do.env" ] && . "$HOME/.do.env"     # provides DIGITAL_OCEAN_API_KEY
set +a
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
exec "$HOME/caddy-build/caddy" run --config "$HOME/.config/caddy/Caddyfile" --adapter caddyfile
```

`~/Library/LaunchAgents/com.example.caddy.plist` mirrors the gateway agent
(label `com.example.caddy`, runs `run-caddy.sh`, logs to
`~/Library/Logs/caddy.log`). Bootstrap and kickstart it the same way.

## 5. Verify the deployment

```sh
# locally on the box
curl -s http://127.0.0.1:9292/v1/models | jq        # gateway up
# through the edge (valid LE cert)
curl -s https://inference.example.com/v1/models | jq # Caddy → gateway
curl -sv https://inference.example.com/v1/models 2>&1 | grep -i "issuer\|expire"
```

A live inference call through `:443`:

```sh
curl -s https://inference.example.com/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3-35b-a3b","messages":[{"role":"user","content":"hi"}]}' | jq
```

## 6. Watch logs / restart

```sh
tail -f ~/Library/Logs/local-inference-proxy.log     # gateway + supervisor
tail -f ~/Library/Logs/caddy.log                     # edge / ACME
# llama-server's own stdout/stderr:
tail -f "${TMPDIR:-/tmp}/space-inference-gateway/"*.log

# restart after a config/code change:
launchctl kickstart -k gui/$(id -u)/com.example.local-inference-proxy
```

## Common pitfalls

- **`https://…/v1/models` returns 200 with an empty body.** Caddy matches the
  HTTP `Host` header, not just SNI. A client that sends `Host: 127.0.0.1`
  (a naive byte-pipe) gets an empty 200. The loopback shim
  ([connect clients](connect-clients.md)) rewrites `Host` to
  `inference.example.com`; cURL with the real hostname is fine.
- **First request 502s after a restart.** An orphaned `llama-server` is holding
  `:8080`. The launcher's `pkill` handles this; if you run the gateway by hand,
  reap it yourself.
- **Cold-start latency on the first request.** Expected — the gateway is
  spawning `llama-server` and waiting on `/health`. Preload with
  `POST /v1/load` to move that cost off the first user request.

Now point the clients at it: [connect clients](connect-clients.md).
