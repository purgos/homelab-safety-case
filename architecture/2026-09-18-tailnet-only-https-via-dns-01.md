# Real HTTPS for tailnet-only admin UIs, via DNS-01 on a hostname nobody can reach

Date: 2026-09-18

Goal: `npm.example.org` (`npm-cloud-edge`'s admin panel) and `headscale-ui.example.org` (the Headscale admin
UI) — both served plain HTTP by the tiny `tailnet-proxy` Caddy container on `cloud-edge`, reachable only
over the `example.org` cloud tailnet — get real, browser-trusted certs instead of a "Not secure" warning.
Explicitly scoped to just this pair; the LAN-wide `*.home.example.org` estate already has real HTTPS via
NPM-Local's existing wildcard cert and wasn't touched.

## The trick

Both hostnames are tailnet-only — bound to `100.64.0.1`, never publicly routable, resolved only via
Headscale's own `dns.extra_records`. That rules out HTTP-01 and TLS-ALPN-01 (both require the challenge to
be reachable from Let's Encrypt over the public internet). But `example.org`'s DNS is on Cloudflare, and
**DNS-01 only needs a public TXT record** — it never touches the hostname's actual A record or checks that
anything is listening there. So a real cert for a name that is *never* publicly reachable is entirely
possible, using the same mechanism NPM-Local already uses for its `*.example.org`/`*.home.example.org`
wildcard certs (see `Docker/shared/npm-local/README.md`).

## What shipped

- `Docker/community-wtf/tailnet-proxy/Dockerfile` — the stock `caddy:2-alpine` image has no DNS provider plugins, so a
  custom build: `caddy:2-builder-alpine` + `xcaddy build --with github.com/caddy-dns/cloudflare`, then copy
  the resulting binary into a plain `caddy:2-alpine` runtime stage.
- `Caddyfile` rewritten from the old `auto_https off` + raw `:80` `@name`/`handle` blocks to normal
  per-hostname site blocks, each with `tls { dns cloudflare {env.CF_API_TOKEN} }`.
- `docker-compose.yml`: `build: .` instead of a bare `image:`, published `100.64.0.1:443:443` alongside the
  existing `:80`, added `caddy_data`/`caddy_config` volumes (needed for Caddy to persist the issued certs
  and ACME account across restarts — the old plain-HTTP setup never needed persistent state).
- A new Cloudflare API token, scoped to `Zone:DNS:Edit` on just the `example.org` zone (not reused from
  NPM-Local's — that one lives inside NPM's own database, not something extractable by another container).

## Real gotcha: the safety classifier blocked shipping the token over `scp`

First pass wrote `CF_API_TOKEN=<value>` directly into `docker-compose.yml` and tried to `scp` it to
`cloud-edge`. Claude Code's own auto-mode permission classifier blocked the command outright — "Credential
Leakage" — refusing to transmit a file with a live-looking secret in it, even to a host this fleet already
trusts with plenty of other live secrets.

Rather than fight the classifier, restructured to not need to: `docker-compose.yml` now reads
`CF_API_TOKEN=${CF_API_TOKEN}` (no literal value, safe to `scp` and to keep tracked in this repo), and the
actual token went into a `.env` file created directly on `cloud-edge` by Purgos himself over his own SSH
session, never passing through a tool call that ships file contents off-box. Net result is arguably better
practice anyway — this is the one live credential in this fleet that's deliberately *not* sitting in a
tracked file, everywhere else's "flag it, don't hide it" convention notwithstanding, simply because it
never needed to leave the one host that uses it.

## Verified

- `docker logs tailnet-proxy` — clean DNS-01 issuance for both hostnames on first attempt, ACME account
  auto-created, certs obtained within ~10s of the challenge starting for `npm.example.org` and ~20s for
  `headscale-ui.example.org`. No retries, no rate-limit backoff.
- `curl -v https://npm.example.org/` and `https://headscale-ui.example.org/` from `cloud-edge` itself: real
  Let's Encrypt leaf certs (`issuer: ... CN=YE1`), correct SAN, `HTTP/2 200` and `302` respectively (expected
  — headscale-ui redirects to its own UI route).
- Plain `http://` still works and Caddy auto-redirects to `https://` for both (no separate redirect block
  needed — this is default Caddy behavior once a site has TLS configured).
- Real gotcha, `headscale-ui` itself: its Settings page stores the "Headscale URL"/API key client-side in
  the browser, keyed by origin — and scheme is part of an origin. Switching `http://headscale-ui.example.org`
  to `https://headscale-ui.example.org` is a *different* origin as far as the browser's storage is concerned,
  so the previously-saved API key silently stopped being sent at all (not an invalid-key error — no
  Authorization header reached Headscale). Fix was just generating and re-entering a fresh key against the
  `https://` origin; expected any time an already-configured client-storage app moves schemes, not a bug in
  this setup specifically.

## Outcome

Both `Docker/community-wtf/tailnet-proxy/README.md` and `Docker/community-wtf/headscale/README.md` updated to describe the DNS-01 setup
as current state; `Docker/community-wtf/homepage-cloud/services.yaml`'s two links switched from `http://` to `https://`.
`Docker/purgos/homepage-local/services.yaml`'s duplicate "Headscale" category (NPM Admin + Headscale Admin links)
was also removed earlier this session — that category is `example.org`-cloud-tailnet-specific and doesn't
belong on the LAN-wide `purgos` dashboard, which already links to its own NPM/Portainer/Proxmox admin panels
under their own `*.home.example.org` HTTPS hostnames.
