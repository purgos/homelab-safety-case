---
date: 2026-09-25
resolved: 2026-09-25
severity: degraded
kind: security
hosts: []
backfilled: true
---

# NPM access list's `satisfy any` silently bypasses Authentik forward-auth

**Status: resolved 2026-09-25 (caught before the hostname had DNS, so never exposed).**

## Symptom
New `npm-community-infra` proxy host `image.home.example.org` (SD Forge, id 19) had Authentik's single-app
forward-auth snippet in its advanced config and access list #1 `tailnet-only` attached. An unauthenticated
request from a tailnet IP to `/sdapi/v1/sd-models` returned **200**, i.e. Forge was served with no login at all.

## Root cause
When an NPM access list is attached, NPM generates this inside `location /`:

```
allow 100.64.0.0/10;
deny all;
satisfy any;
```

`satisfy any` means **any one** access module passing is enough. The tailnet IP passes `allow`, so nginx never
enforces the server-level `auth_request` inherited into that location. NPM emits `satisfy any` because its access
lists are designed around "IP allowlist OR HTTP basic auth", which also defeats every other access-phase module
such as `auth_request`.

Hosts on **NPM-Local** carrying the same snippet (`sd.legacy.example.net`) weren't affected: they have no access list,
so the default `satisfy all` applied.

## Fix
Host 19: access list removed (`access_list_id: 0`). The tailnet restriction moved into the advanced config at
server level, where the default `satisfy all` requires **both** the IP match and `auth_request`:

```
allow 100.64.0.0/10;
deny all;
auth_request /outpost.goauthentik.io/auth/nginx;
...
```

Verified: `/` and `/sdapi/v1/sd-models` both `302` → `/outpost.goauthentik.io/start` → auth-local `/authorize/` →
login flow `200`.

## Rule
**Never combine an NPM access list with a forward-auth snippet.** Do the IP restriction in the advanced config
instead. After creating any forward-auth host, test an unauthenticated request to a deep API path, not only `/`,
and expect a `302`/`401`, never a `200`.

A second gotcha on the same host: with "WebSockets" enabled, NPM already emits `proxy_http_version 1.1` and the
`Upgrade`/`Connection` headers at server level. Repeating them in the advanced config makes nginx fail its config
test (`"proxy_http_version" directive is duplicate`), and NPM saves the host but silently writes no `.conf`
(`meta.nginx_online: false`, error in `meta.nginx_err`), so the host just times out.
