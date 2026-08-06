# How-to: install dependencies

What has to exist on each machine before the gateway runs. The reference
deployment is a Mac Studio (`studio.slush.systems`) serving inference, with
laptops as clients.

**Most studio-side setup is automated.** The
[Ansible playbook](deploy-on-the-studio.md) installs Ruby, the engine venvs,
and the Caddy build on every apply. This page covers the handful of manual
prerequisites the playbook assumes, explains what it installs (so you know
what you're getting), and covers the laptop side, which has no automation.

## On the studio — manual prerequisites

The playbook runs user-level (no root, no `become`) and expects these on the
box already:

1. **Homebrew**, with these packages:

   ```sh
   brew install mise go python@3.12 ansible 1password-cli
   ```

   The playbook invokes `mise`, `go`, and `python3.12` at their
   `/opt/homebrew/bin` paths, uses the Homebrew `ansible` (its bundled
   collections cover everything in `deploy/ansible/requirements.yaml`), and
   *verifies* `op` is present without installing it.

2. **A 1Password service-account token** at `~/.config/secret/op`
   (mode 0600), as a shell snippet:

   ```sh
   export OP_SERVICE_ACCOUNT_TOKEN=ops_...
   ```

   `op` does not read this file on its own — `run-caddy.sh` sources it, then
   fetches the DigitalOcean API key via
   `op read 'op://ansible/digitalocean-certbot-token/token'` for Caddy's
   DNS-01 challenge. The playbook never creates or reads this file.

3. **Model artifacts** in `~/.cache/huggingface/hub`. The engines download
   models from Hugging Face automatically on first load, but the supervisor's
   120 s readiness window won't cover a multi-GB download — pre-fetch big
   models (see the [tutorial](../tutorial.md#3-pre-fetch-the-model)) or let a
   failed first load finish downloading in the background and retry.

## On the studio — what the playbook installs

You don't run these by hand; this is what an apply produces, for orientation
and debugging:

| Piece | Where | Why |
|---|---|---|
| Ruby 4.0.5 via mise | `~/.local/share/mise/installs/ruby/4.0.5/bin` | the launcher puts this on `PATH` explicitly so launchd gets the right interpreter without a login shell |
| Gateway checkout + bundle | `~/src/space-inference-gateway` | runtime checkout, pulled and `bundle install`ed on every apply |
| optiq venv | `~/.venv-optiq` (`mlx-optiq==0.3.5`) | the `optiq serve` engine; the binary is `~/.venv-optiq/bin/optiq` |
| mlx venv | `~/.venv-vllm-metal` (`mlx-lm==0.31.3`) | the `mlx_lm.server` engine. The name is historical — it matches `config/models.yml` `venv:` paths, **do not rename one without the other** |
| Caddy with the DigitalOcean DNS plugin | `~/caddy-build/caddy` | see below |

### Why Caddy is built with xcaddy

TLS at the edge needs a real Let's Encrypt cert, and the studio sits on a
private VLAN with no inbound HTTP-01 path — so the ACME challenge must be
**DNS-01** against DigitalOcean DNS. Homebrew's stock `caddy` ships no
third-party DNS providers, the old caddyserver Homebrew tap is gone (404),
and xcaddy isn't in homebrew-core; hence the playbook does
`go install …/xcaddy@latest` and then:

```sh
xcaddy build --with github.com/caddy-dns/digitalocean
```

Verify a build: `~/caddy-build/caddy list-modules | grep digitalocean` →
`dns.providers.digitalocean`.

## On a client laptop

Two rules, both consequences of the macOS Local Network privacy gate (full
story in the [architecture explanation](../explanation/architecture.md#the-tcc-gate)):

1. **Use the system Python.** The loopback shim must run under
   `/usr/bin/python3` — an Apple-platform binary exempt from the LAN gate. Do
   not substitute a Homebrew/mise Python; it would be gated like any other
   binary. Nothing to install: the shim is stdlib-only precisely so the stock
   interpreter can run it.
2. **Install the clients normally** (`claude`, `opencode`) — they'll talk to
   `127.0.0.1`, never the LAN. Wiring them up is
   [connect clients](connect-clients.md).

## On a dev machine

```sh
brew install mise
mise use -g ruby@4.0.5     # anything ≥ 3.3 works; this matches production
bundle install
bundle exec rspec && bundle exec rubocop
```

The suite runs entirely against fake upstreams — no engine or model required.
Running the real thing locally additionally needs the mlx venv (tutorial,
step 0).

## Verification

| Check | Expect |
|---|---|
| `op --version` | prints a version (playbook hard-fails without it) |
| `test -f ~/.config/secret/op && stat -f %Lp ~/.config/secret/op` | `600` |
| `mise which ruby` | `~/.local/share/mise/installs/ruby/4.0.5/bin/ruby` |
| `~/.venv-optiq/bin/optiq --help` | optiq usage text |
| `~/.venv-vllm-metal/bin/python -c 'import mlx_lm'` | exits 0 |
| `~/caddy-build/caddy list-modules \| grep digitalocean` | `dns.providers.digitalocean` |
| `/usr/bin/python3 --version` (laptop) | the Apple-shipped Python |
