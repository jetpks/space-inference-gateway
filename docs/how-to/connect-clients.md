# How-to: connect Claude Code and opencode

Point your clients at the deployed gateway. This is laptop-side work. It assumes
the gateway is [deployed behind Caddy](deploy-on-the-studio.md) at
`https://inference.example.com`.

## Why a loopback shim (the one-paragraph version)

macOS's Local Network privacy gate blocks signed CLI binaries (`claude`,
`opencode`) from connecting to a **private LAN IP** — and the studio resolves to
one. The block keys on the destination IP and on the binary's identity, so no
hostname or TLS trick gets `claude` itself onto the LAN. The escape: **loopback
is exempt**, and **Apple's `/usr/bin/python3` is exempt** from the LAN gate. So
the clients talk plaintext to `127.0.0.1`, and a tiny Python forwarder running
under the system interpreter carries the bytes over TLS to the studio. Full
reasoning in the [architecture explanation](explanation/architecture.md#the-tcc-gate).

```
claude / opencode → 127.0.0.1:3001 → forward_tls.py ─TLS→ inference.example.com:443 → Caddy → gateway
```

## 1. Install the loopback TLS shim

`forward_tls.py` is an HTTP-aware, stdlib-only async forwarder. It frames each
request/response (Content-Length / chunked / read-until-close), keeps the
connection alive, streams SSE, and **rewrites the request `Host:` header** to
`inference.example.com` (Caddy needs it — see the deploy pitfalls).

Install it where the launcher expects it:

```sh
mkdir -p ~/.config/claude-local-proxy
cp forward_tls.py ~/.config/claude-local-proxy/forward_tls.py
```

It takes `<listen-port> <upstream-host> <upstream-port>` and must be run with
the system Python:

```sh
/usr/bin/python3 ~/.config/claude-local-proxy/forward_tls.py 3001 inference.example.com 443
```

You won't normally run it by hand — the fish functions below start it on demand.

## 2. The fish functions

Three small functions wire it together. Drop them in
`~/.config/fish/functions/`.

**`ensure-local-proxy.fish`** — starts the shim if `127.0.0.1:3001` isn't
already listening:

```fish
function ensure-local-proxy --description 'Ensure the loopback->studio TLS forwarder is up'
    set -l proxy_py /Users/eric/.config/claude-local-proxy/forward_tls.py
    set -l proxy_log /Users/eric/.config/claude-local-proxy/proxy.log
    set -l listen 3001
    if not nc -z 127.0.0.1 $listen 2>/dev/null
        echo "ensure-local-proxy: starting 127.0.0.1:$listen -> tls://inference.example.com:443" >&2
        nohup /usr/bin/python3 $proxy_py $listen inference.example.com 443 >>$proxy_log 2>&1 &
        disown
        for x in 1 2 3 4 5 6
            nc -z 127.0.0.1 $listen 2>/dev/null; and break
            sleep 0.5
        end
    end
end
```

**`claude-local.fish`** — runs Claude Code against the gateway's native
Anthropic surface:

```fish
function claude-local --description 'Run Claude Code against the local inference gateway'
    ensure-local-proxy
    env ANTHROPIC_BASE_URL=http://127.0.0.1:3001 \
        ANTHROPIC_API_KEY=local-proxy \
        ANTHROPIC_AUTH_TOKEN=local-proxy \
        claude $argv
end
```

The API key is a dummy — the VLAN plus TLS is the security boundary, not a
bearer token (see [non-goals](explanation/architecture.md)).

**`opencode-local.fish`** — runs opencode (which reads its base URL from
`opencode.jsonc`) with the shim guaranteed up:

```fish
function opencode-local --description 'Run opencode against the local inference gateway'
    ensure-local-proxy
    command opencode $argv
end
```

## 3. Point opencode at the gateway

opencode reads its provider base URL from config, not the environment. In your
`opencode.jsonc`, point the local provider's `baseURL` at the shim:

```jsonc
{
  "provider": {
    "local": {
      "options": { "baseURL": "http://127.0.0.1:3001/v1" }
    }
  }
}
```

opencode then hits `127.0.0.1:3001/v1/chat/completions`, which the shim carries
to the studio. Use whatever model id you've registered (e.g.
`qwen3-35b-a3b`) — unknown ids are served by the running/default model anyway
(see the [HTTP API reference](../reference/http-api.md#model-resolution)).

## 4. Use it

```sh
claude-local                                  # interactive Claude Code on local inference
claude-local -p "What is 17 times 23?"        # one-shot
opencode-local                                # opencode on local inference
```

Reasoning shows up separated (Claude Code renders the `thinking` blocks; opencode
shows `reasoning_content` deltas), with no client-side parse errors.

## Troubleshooting

- **`Connection refused` on 3001.** The shim isn't up. Run `ensure-local-proxy`
  and check `~/.config/claude-local-proxy/proxy.log`.
- **Empty replies / 200 with no body.** The `Host` header isn't being rewritten
  — make sure you're on `forward_tls.py`, not a raw byte-pipe forwarder.
- **`claude` hangs or is blocked reaching the LAN.** You bypassed the shim
  (pointed `ANTHROPIC_BASE_URL` at the studio directly). It must point at
  `127.0.0.1:3001`; only `/usr/bin/python3` may cross the LAN gate.
- **TLS/cert errors.** Check the cert at the edge:
  `curl -sv https://inference.example.com/v1/models`. If the cert is bad, look at
  `~/Library/Logs/caddy.log` on the studio (ACME/DNS-01).
