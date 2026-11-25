---
date: 2026-08-03
resolved: 2026-08-03
severity: degraded
kind: security
hosts: []
backfilled: true
---

# Plex silently re-opened a port forward via UPnP after it was manually removed

**Status**: closed (2026-08-03)

## What broke

While closing out the home router's port forwards (see
`Networking/router/README.md` for the resulting zero-forward state), the manual
32400→Plex forward was removed and a replacement path was built instead (a `socat` TCP passthrough on the
Front End VPS tunneling to Plex over Tailscale, plus a Plex "Custom server access URL" pointing at it).

Querying `https://plex.tv/api/resources` (Plex's own published connection list for the server) still showed a
remote connection at the home WAN IP on a *different* port than before (`25660`, not `32400`) even after the
manual forward was gone and the custom URL had been added successfully.

## Root cause

Plex Media Server has its own automatic UPnP port-mapping feature (`ManualPortMappingMode` preference,
`0` = automatic/UPnP, `1` = manual). With it enabled, Plex asks the router directly via UPnP to open whatever
port it needs for remote access — independent of, and unaffected by, any port forward manually configured (or
removed) in the router's own admin UI. Removing the manual 32400 forward didn't stop this: Plex just had the
router open a *different* external port (`25660`) on its own via UPnP, which is why `LastAutomaticMappedPort`
in Plex's preferences showed `25660` and why the stale connection kept appearing.

This Plex version's Settings UI had no visible toggle for this (checked both Network and Remote Access tabs) —
in earlier/other versions it's usually under Settings → Network → "Enable automatic port mapping" or similar,
but that control has moved around across Plex releases and wasn't present here.

## Resolution

Set the preference directly via Plex's own HTTP API instead of hunting for a relocated UI control:

```bash
curl -X PUT "http://<plex-ip>:32400/:/prefs?ManualPortMappingMode=1&X-Plex-Token=<token>"
```

This stops Plex from *maintaining* the UPnP mapping going forward, but doesn't retroactively guarantee the
router drops the existing one — UPnP mappings are a separate NAT rule living on the router, not something a
preference flip on the application side can force-remove. Confirmed actually closed by disabling UPnP
entirely at the router level (the router had no granular "delete just this UPnP entry" option that was easy to
find either) and verifying with a direct connection test:

```bash
curl -o /dev/null -w '%{http_code}' http://<home-wan-ip>:32400/identity   # -> connection refused
```

## General rule

When removing a manually-configured port forward for a service, check whether that service *also* has its own
automatic UPnP port-mapping feature — many self-hosted media/game server apps (Plex included) do this by
default for "just works" remote access, and it operates completely independently of the router's own forward
list. A forward can look removed in the router UI while the service quietly maintains an equivalent one anyway
via UPnP. If the app's UI doesn't expose a way to turn this off (UI location varies by version and isn't
always present), check whether the app exposes the underlying setting through its own API before assuming
there's no way to disable it.
