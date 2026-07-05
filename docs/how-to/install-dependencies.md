# How-to: install the dependencies

This covers every dependency the gateway and its edge need, with the exact
commands. It is split by where the software runs: the **studio** (the Mac that
serves inference) and the **client laptop** (where Claude Code / opencode run).

The reference deployment is a Mac Studio (`inference.example.com`, Apple silicon,
macOS 25) using Homebrew. Adapt paths for your box.

---

## Studio (the inference host)

### 1. Homebrew

If it isn't already present:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Ruby via `mise`

The gateway needs Ruby ≥ 3.3; production runs 4.0.5. We pin it with `mise`
rather than the system Ruby.

```sh
brew install mise
mise use -g ruby@4.0.5     # writes ~/.config/mise/config.toml
ruby -v                    # ruby 4.0.5 ...
```

The launcher (`run-proxy.sh`) puts the mise Ruby on `PATH` explicitly
(`~/.local/share/mise/installs/ruby/4.0.5/bin`) so launchd gets the right
interpreter without a login shell.

Then install the gem's dependencies:

```sh
cd ~/space-inference-gateway
bundle install
bundle exec rspec && bundle exec rubocop    # gate: both should be green
```

### 3. `llama-server` (llama.cpp)

The gateway spawns and supervises a `llama-server` child. **Install the stock
Homebrew build** — it puts `llama-server` on `PATH` and upgrades like any other
formula:

```sh
brew install llama.cpp
llama-server --version
```

> The current production box still uses the binary that shipped with Unsloth
> Studio (`~/.unsloth/llama.cpp/llama-server`, build 9827). Moving to the
> Homebrew build is a tracked roadmap item — see [ROADMAP](../../ROADMAP.md).
> Either way, point `config/models.yml` `binary:` (or `LLAMA_SERVER_BINARY`) at
> the binary you want; omit `binary:` to resolve `llama-server` from `PATH`.

You also need a `.gguf` model file. Fetch one with the Hugging Face CLI
(`brew install hf`) or any method you like, and record its path in
`config/models.yml`. See
[add & tune models](add-and-tune-models.md).

### 4. Caddy with the DigitalOcean DNS plugin (the TLS edge)

Caddy terminates TLS at `:443` with an auto-renewing Let's Encrypt certificate,
obtained over the **DNS-01** challenge against DigitalOcean (the studio is on a
private VLAN with no inbound HTTP-01 path). Homebrew's stock `caddy` omits
third-party DNS providers, so we build a custom Caddy with `xcaddy`.

```sh
brew install go                              # xcaddy needs the Go toolchain
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
#   → installs to ~/go/bin/xcaddy

# build a Caddy that includes the DigitalOcean DNS provider
mkdir -p ~/caddy-build && cd ~/caddy-build
~/go/bin/xcaddy build --with github.com/caddy-dns/digitalocean
#   → produces ./caddy   (verify the module is in)
./caddy list-modules | grep digitalocean    # → dns.providers.digitalocean
./caddy version                              # → v2.11.x ...
```

Caddy needs a DigitalOcean API token (DNS write scope) at runtime. The launcher
sources it from `~/.do.env`:

```sh
printf 'DIGITAL_OCEAN_API_KEY=dop_v1_xxxxxxxx\n' > ~/.do.env
chmod 600 ~/.do.env
```

The `Caddyfile`, `run-caddy.sh`, and launchd setup are in the
[deploy how-to](deploy-on-the-studio.md).

---

## Client laptop (Claude Code / opencode)

### Python 3 — already installed, do not `brew install` it

The loopback shim **must** run under Apple's system `/usr/bin/python3`. macOS's
Local Network privacy gate exempts Apple-platform binaries from the LAN block; a
Homebrew Python (or a mise Ruby) would itself be gated and could not reach the
studio. So the one hard requirement here is the binary you already have:

```sh
/usr/bin/python3 --version     # 3.9.x ships with macOS — this is the one to use
```

The shim (`forward_tls.py`) is **stdlib-only** precisely so it runs under that
interpreter with nothing to install. See
[connect clients](connect-clients.md) for installing the shim and the fish
functions.

### The clients themselves

Install Claude Code and/or opencode however you normally do. No special build is
needed — the whole point of the gateway is that they need no per-client patches.

---

## Quick verification

| Component        | Check                                                  | Expect                          |
|------------------|-------------------------------------------------------|---------------------------------|
| Ruby             | `ruby -v`                                              | `4.0.5` (or ≥ 3.3)              |
| Gem deps         | `bundle exec rspec`                                    | suite green                     |
| llama-server     | `llama-server --version`                              | a build number                  |
| Caddy + DNS      | `~/caddy-build/caddy list-modules \| grep digitalocean` | `dns.providers.digitalocean`  |
| DO token         | `test -f ~/.do.env && echo ok`                        | `ok`                            |
| Client python    | `/usr/bin/python3 --version`                          | system Python 3                 |

With these in place, follow the [tutorial](../tutorial.md) for a first local run
or the [deploy how-to](deploy-on-the-studio.md) for the full TLS deployment.
