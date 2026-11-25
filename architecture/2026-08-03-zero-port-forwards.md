# Getting the home router down to zero port forwards

## What was planned

Not actually planned in advance — this fell out of a side conversation while reviewing the Front End VPS
migration (`Blog/2026-08-02-front-end-public-edge.md`). Asked whether
Plex could be proxied through the Front End too, and the real answer turned out to be "the actual goal is zero
forwards on the home router, period" — not just Minecraft and web traffic. Plex was the last one standing.

## How it went

Checked the router's actual current state first rather than trusting this repo's docs, which turned out to be
stale — `Networking/router/README.md` still listed a port 80/443 forward that had already been removed weeks
earlier during the Front End web migration. Only one real forward remained: `32400` → Plex.

Built the same kind of tunnel already used for Minecraft, but simpler: a raw TCP passthrough instead of a
protocol-aware proxy. Plex handles its own TLS/certs and remote-access handshake, so putting it behind NPM's
HTTP reverse proxy would fight with Plex's own cert scheme (WebSocket upgrade headers, `X-Forwarded-For`,
etc.) — a dumb byte-for-byte forward sidesteps all of that, same idea as how Velocity already does raw
Minecraft-protocol passthrough rather than anything HTTP-aware. Implementation: a one-line `socat` container on
the Front End (`TCP-LISTEN:32400,fork,reuseaddr TCP:<plex-tailscale-ip>:32400`), reusing the Tailscale ACL rule
that already existed from the original Front End planning (it had been added early for a homepage-widget status
check, never used for actual traffic until now).

Verified the tunnel worked end-to-end before touching anything else — curled Plex's `/identity` endpoint
through the container locally on the VPS, then again from outside against the VPS's public IP. Both came back
clean before asking for the home router forward to be removed.

## Problems hit, and how they got fixed

- **Removing the forward "worked" but Plex kept using the old path anyway.** Turned out Plex's own automatic
  remote-access detection doesn't know about the new address — it needed to be told explicitly via Plex's
  "Custom server access URL" setting before it would advertise the new path to clients at all.
- **The setting didn't save the first time.** Checked Plex's actual live preferences via its own API
  (`customConnections` was empty) rather than trusting the UI had taken the change — caught it before assuming
  it was working. Second attempt saved correctly.
- **Even with the custom URL live, a stale connection kept showing up at the home IP** — on a different port
  than the one that was removed. Root cause: Plex has its own automatic UPnP port-mapping feature that opens
  a forward directly with the router, completely independent of anything configured in the router's own admin
  UI. Removing the manual forward didn't touch it — Plex just had the router open a new one on its own. Full
  writeup in
  `Troubleshooting/plex-upnp-silently-reopened-forward.md`.
  This Plex version had no UI toggle for it in either the obvious settings tabs, so the fix went through
  Plex's own HTTP API directly (`PUT /:/prefs?ManualPortMappingMode=1`) instead of hunting for a relocated
  control.
- **Confirming it was actually gone needed a real test, not just checking a setting.** Flipping Plex's
  preference stops it from *maintaining* the UPnP mapping, but doesn't retroactively force the router to drop
  the existing one — that's a separate NAT rule on the router's side. Ended up disabling UPnP entirely at the
  router level (Plex's UI gave no obvious way to delete just the one stale entry) and confirmed with a direct
  connection test against the home WAN IP: clean `connection refused`, not just a timeout.

## Where it stands

The home router has **zero WAN→LAN port forwards** — Minecraft, web, and now Plex all route in through the
Front End VPS over Tailscale instead. UPnP is off at the router entirely, so nothing can silently re-open a
forward the way Plex just did. The one tradeoff that doesn't go away: remote Plex streams now go through the
Front End's ~$5/mo VPS pipe instead of home's own uplink — judged an acceptable trade for actually hitting zero
exposed ports, but worth knowing if remote streaming quality ever regresses.

Docs updated to match: `Networking/router/README.md` (port forward table
replaced with the zero-forward state + new UPnP-disabled note),
`VMs/Infrastructure/README.md`, and
`VMs/Edge/README.md` (which also
turned out to be stale in a couple of other places while re-checking it — the Minecraft DNS cutover and port
30061 removal it still listed as open items had, in fact, already happened).
