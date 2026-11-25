# Locking down the tailnet: default-deny ACL, two admin identities, one door for everyone else

Date: 2026-09-25

## What was planned

An outside review by a sysadmin/architect friend put "each person and service can reach only what it needs"
first. Checking it against the live setup
(`Planning/Strategies/security-review-2026-09.md`) found
the Headscale ACL was **allow-all**: every tag, including the internet-facing NPM on `cloud-edge`, could reach
every host on the home LAN through `Subnet-Router`'s route.

The design settled with Purgos in conversation:
- **Two admin identities.** `akadmin` = `example.org` admin (the community cloud stack). `purgos` = personal
  account + `home.example.org` admin (the home lab). This mirrors the repo's `Docker/community-wtf/` vs `Docker/purgos/` split.
- **Connected households wear two tags**: a universal role (`tag:router` / `tag:lab`) and a per-house
  `tag:home-<house>`. Groups can only hold people, so "per-home grouping" is done with a second tag.
- **One door**: everyone except Purgos reaches the home LAN only through `community-infra`'s NPM on 443, which
  gets a media dashboard of its own. Plex is being retired, so it's Jellyfin.
- **Exit nodes and subnet routes belong to their owner.** No other user gets them.

## How it went

1. **Fixed `community-infra` first.** It had `accept-routes` on again (the 2026-09-18 bug), which was silently
   breaking LAN access to it, and its public sites only worked by hairpinning through the Subnet-Router.
   Turning default-deny on first would have taken them down.
2. **Mapped every tailnet dependency** before writing any rule: Prometheus targets, the metrics-bridge
   socats, Promtail→Loki, NPM forward-auth, Kuma's DB, homepage widgets. Kuma only checks public URLs, which kept that part simple.
3. **Wrote the policy, validated it with `headscale policy check --file`, swapped it in**, and tagged
   `downloads` (previously a user-owned server) in the same step so it wouldn't be cut off. `akadmin` stays
   in `group:purgos` *temporarily*, so the phone (still `akadmin`-owned) doesn't lose home access before it's moved.
4. **Verified with real connections**: allow + deny matrices from every cloud box, then three disposable
   tagged Tailscale containers standing in for a niece's router, her homelab, and another house's homelab.
5. **Built the door**: `*.home.example.org` DNS-01 cert on `community-infra`'s NPM, a `tailnet-only` access
   list, proxy hosts for Jellyfin/Jellyseerr/Kavita/Audiobookshelf, a `homepage-media` dashboard at
   `media.home.example.org`, and a `status.example.org/status/media` Kuma page.
6. **DNS stayed private.** The names live only in Headscale `extra_records`. Public records pointing at
   `100.64.x` would be dropped by GL.iNet's DNS-rebind protection, and would advertise the service names anyway.

## Troubleshooting along the way

- **My own SSH broke first.** `~/.ssh/config` jumped to the cloud boxes through `miku`, which is `purgos`,
  and `purgos` is exactly what's no longer allowed there. `tomo` (`akadmin`) now connects directly.
- **Three monitoring paths had been silently dead for days**: Loki behind a stale `ufw-docker` IP rule,
  Headscale's metrics listening on the container's loopback, and CrowdSec's metrics lost to the tailnet-IP boot race.
  The write-up is in `Troubleshooting/2026-09-25-community-infra-accept-routes-and-silent-monitoring-gaps.md`.
- **A false "allowed" in testing.** The fake router seemed to reach `cloud-auth:9000`. Tailscale leaves peers the
  ACL gives no path to out of the netmap, so the container's packet fell back through the Docker bridge and left
  via cloud-edge's *own* (allowed) identity. `ip route get` inside the container showed it. A real router at
  someone's house would have sent it to its ISP.
- **Tightening `cloud-auth`'s firewall on a box with no console**: added the specific rules first, removed
  the blanket rule last, with a `systemd-run` auto-restore armed and cancelled only after a fresh SSH worked.

## Outcome

Live and verified. The internet-facing box can now reach only its three upstreams. A household router can
reach only the media door, and can't see any exit node, subnet router, or another house. Remaining: move `tomo` +
`phone` to `purgos` and drop the transitional `akadmin` membership; migrate the media apps' SSO to
`auth.example.org`; the rest of the security review (backups + restore drill, MFA, external alerting).

## Addendum, same night: identities settled

- `tomo` and the phone moved to `purgos`. That surfaced a redacted-placeholder OIDC secret on Headscale (browser
  logins had been broken since 09-23), then a duplicate `purgos` user that stopped Headscale from starting. Both were
  fixed, with ~7 min of control-plane downtime in total (see the two Troubleshooting docs dated 2026-09-25).
- Final model: `purgos` is the only tailnet user (personal + both admin groups). The Authentik superuser
  `akadmin` was renamed **`purgos-admin`** and taken off the tailnet entirely. A disabled `akadmin` placeholder keeps
  Authentik's first-time-setup flow locked (a plain rename would have re-opened it).
- App admin rights (Authentik, Nextcloud, Grafana) all hinge on `authentik Admins`, which only `purgos-admin` is in.
- Next step (planned, not built): a jump box for SSH to the cloud boxes plus an Authentik gate in front of the
  tailnet-only admin pages, so `purgos` stops needing direct SSH to the cloud stack.
