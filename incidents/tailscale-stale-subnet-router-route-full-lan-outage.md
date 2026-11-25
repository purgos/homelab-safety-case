---
date: 2026-09-18
resolved: 
severity: outage
kind: incident
hosts: []
backfilled: true
---

# Clearing a Tailscale subnet-router advertisement left a stale kernel route — full LAN outage on `community-infra`

## What broke

While cutting the `10.10.0/24` subnet-router role over from `community-infra`
to a new dedicated box (`Subnet-Router`), the command to make
`community-infra` stop advertising the route (`tailscale set --advertise-routes=`) hung for several minutes,
and once it returned, **`community-infra` was completely unreachable via its LAN IP** — `ping
10.10.243` and `ssh` both timed out with no response at all, from every host tried, including the
Proxmox host (`dyonisis`) itself on the same physical L2 segment.

Its Docker services (NPM, the `metrics-community-wtf` stack, monitoring bridges) never crashed or
restarted — confirmed once reachable again, all showed long, unbroken uptimes. This was purely a
networking-layer outage, not a service failure.

## Root cause

`ip rule show` on `community-infra` showed a rule `5270: from all lookup 52` — Tailscale's own dedicated
routing table for subnet-router functionality, consulted *before* the main table for all outbound
traffic. `ip route show table 52` still contained `10.10.0/24 dev tailscale0`, even though
`tailscale debug prefs` correctly showed `"AdvertiseRoutes": null` — the **control-plane state was
correctly cleared, but the local kernel routing table wasn't cleaned up to match**.

Because that table is checked first, every outbound packet from `community-infra` destined to any
`10.10.0/24` address — including SSH/ICMP *replies* to hosts trying to reach it — got routed into
the `tailscale0` interface instead of `ens18`, and was lost (no route to a random LAN peer exists over
the tailnet, so the packet effectively vanished). New inbound connection attempts (ping, SSH) therefore
appeared to hang/time out with zero response, even though:

- The interface (`ens18`), IP config, default route, and `ufw` rules on `community-infra` all looked
  completely normal on direct inspection.
- ARP resolution for `community-infra`'s address worked fine (`ip neigh` showed `REACHABLE` with the
  correct MAC) — ruling out an L2 problem.
- Existing Tailscale WireGuard sessions to `cloud-auth`/`cloud-edge` (non-`10.10.0/24`
  destinations) kept working perfectly throughout — confirmed via a live `tcpdump` on the VM's Proxmox
  tap interface showing healthy bidirectional UDP traffic on port `41641` the entire time. This is what
  made the fault non-obvious: the box looked "half-alive," which doesn't fit typical total-outage
  patterns (crash, firewall lockout, cable unplugged) and pointed toward something protocol/route-specific
  rather than a full network death.

## Diagnosis path (what actually worked)

1. Ruled out the guest OS/QEMU process being dead: `qm status` showed `running`, host-side `top` showed
   normal, low CPU usage for the VM's `kvm` process — not a crash or hang loop.
2. Ruled out an L2/switching issue: `tcpdump` on the VM's own Proxmox tap interface (`tap107i0`) showed
   real, healthy Tailscale UDP traffic continuing — the VM's network path to the physical bridge was fine.
3. Ruled out ARP: `ip neigh show` on `dyonisis` showed `10.10.243` as `REACHABLE` with the correct
   MAC — L2 resolution was working.
4. **Recovered access via the still-healthy Tailscale path instead of the dead LAN path** —
   `ssh -o ProxyJump=miku root@100.64.0.3` (the VM's Tailscale IP, reachable since that path was never
   affected) — rather than continuing to fight the LAN side blind. This was the key unlock: it let live
   diagnostics run *on* the box despite its LAN interface being unreachable from outside.
5. From there, checked `ip rule show` → found the `lookup 52` rule still present → checked
   `ip route show table 52` → found the stale `10.10.0/24 dev tailscale0` entry despite
   `AdvertiseRoutes` already being `null` at the daemon level.

## Resolution

```
ip route del 10.10.0/24 dev tailscale0 table 52
```

Immediate recovery — `ping`/`ssh` to the LAN IP worked again within seconds, no reboot or `tailscaled`
restart needed. Confirmed in Headscale afterward (`headscale nodes list-routes`) that `community-infra`
correctly shows the route as no longer `Available`/`Serving` (still listed under a stale `Approved`
entry, harmless), while the new `Subnet-Router` node correctly shows as `Serving (Primary)` for both
`10.10.0/24` and the exit-node routes.

## Lesson

**`tailscale set --advertise-routes=` (or any change to advertised routes on an active subnet router)
can leave the kernel-side policy-routing table (`table 52`) out of sync with the daemon's own
`AdvertiseRoutes` preference.** Checking `tailscale debug prefs` alone is not sufficient proof the
change actually took effect at the routing level — always also check `ip rule show` /
`ip route show table <N>` (the table number Tailscale is using; commonly `52`) after any subnet-router
route change, on the box itself, before assuming the cutover is clean. This is a real, reproducible gap
in `tailscaled`'s own route cleanup, not a one-off fluke — treat it as a standard verification step for
any future subnet-router role change, not just this one.

**Also validated as a real recovery technique for next time**: if a subnet-router/gateway box becomes
unreachable via its LAN IP but is still a healthy Tailscale/Headscale node, reach it through the tailnet
itself (via another already-joined peer as a jump host) rather than resorting to a Proxmox console
reboot — this preserves the ability to diagnose and fix the live, running state instead of losing
whatever in-memory context a reboot would reset.

## Status

Resolved 2026-09-18, same session — the stale route was deleted, the cutover to `Subnet-Router`
completed successfully, and end-to-end verification (general LAN reachability through the new box, exit
node egress via real home WAN IP) passed afterward. No data loss, no lasting service impact — `community-infra`'s
own Docker services were never down, only its direct LAN-IP reachability during the affected window.
