# Security audit: an active scan of the fleet, and what it found

Date: 2026-09-07

Ran a real security audit of the homelab — live `nmap` + `curl` probing from `tomo` (on both the LAN
and the tailnet), not just a config read — followed by a remediation pass. This is the narrative; the
findings are written up one-per-issue under `Troubleshooting/` and the
deferred items are Forgejo issues on `purgos/Homelab`.

## Method

`tomo` (`10.10.25`) sits on the LAN and the tailnet, so it's the right vantage for "what can a
device already inside see". ARP sweep of `10.10.0/24`, then `nmap -sT --top-ports 1000` against
every host, then `-sV` + targeted `curl` against everything interesting. External surface checked by
scanning Edge's public IPs and resolving every `*.old.example.com` / `*.legacy.example.net` name against
`1.1.1.1` to see what's actually public vs. Pi-hole-internal.

## The theme: the network is flat and over-trusted

`ufw-docker`'s stock `DOCKER-USER` chain `RETURN`s **all** RFC1918 source traffic, so every published
container port on every VM is reachable from the entire LAN. And `infra` is the Tailscale subnet
router for `10.10.0/24` with SNAT on (`"NoSNAT": false`), so tailnet devices that "Accept routes"
reach those same ports too — appearing as `10.10.36`. Net effect: "internal" means the whole LAN
*plus* every tailnet device, including personal phones and the about-to-be-gifted `tomo`.

That structural issue is its own project (a per-service `ufw route` model + dropping subnet-route
SNAT). This pass did the high-value, low-risk items and scripted the rest.

## Fixed same day

- **`dyonisis` `rpcbind`** — the Proxmox host (no firewall) was exposing `111/tcp+udp` to the LAN, an
  amplification/info-leak vector. Confirmed nothing in the fleet uses NFS (Storage is SSHFS), so:
  `systemctl disable --now rpcbind.socket rpcbind.service` + `systemctl mask rpcbind.socket` (the
  socket kept re-triggering the service until masked). Port 111 now closed; mounts unaffected. Folded
  into `Troubleshooting/dyonisis-node-exporter-unprotected.md`.

- **Forgejo self-registration** — `git.old.example.com` had open signup with email confirmation. Added
  `FORGEJO__service__DISABLE_REGISTRATION=true` + `REQUIRE_SIGNIN_VIEW=true`, recreated. Verified:
  `/user/sign_up` → "Registration is disabled", `/explore` + API require sign-in. One gotcha — the
  container took ~90s to come back (a pending DB migration on the `forgejo` schema ran on startup),
  long enough that NPM served 502s in the meantime.

## Portainer agent secret — fixed live

Every `portainer_agent` in the fleet ran with **no `AGENT_SECRET`**, binding `/:/host` + the docker
socket — anyone who could reach `:9001` (the whole LAN, plus tailnet via the subnet route) could
adopt the agent from their own Portainer and get host root, fleet-wide. `Scripts/audit-20260907-portainer-agent-secret.sh`
sets one shared secret on the server + every agent (network-independent, so it isn't limited by the
flat-network problem). Verified after: server healthy, every environment reconnected, `:9001` ACCEPT
counters climbing from the server's IP only.

## Grafana anonymous access — fixed live

Anon Viewer (added 2026-09-05 so `sakura`'s wall display and `metrics.old.example.com` render without a
login) could use Grafana's Loki datasource proxy to read **all fleet logs**. Moved anon into a
dedicated **Kiosk** org that has only a Prometheus datasource + a copy of the (already 100%-Prometheus)
`hardware-fleet` dashboard; Main Org. now requires login. Two gotchas: `docker compose up -d` doesn't
restart Grafana for a bind-mounted config change (`docker restart grafana` does), and the copied
dashboard kept Main Org's Prometheus datasource UID until remapped. The compose's
`GF_SECURITY_ADMIN_PASSWORD` was stale (only applied on first init) so the local `admin` password had
to be reset with `grafana cli admin reset-admin-password` first. Verified: anon `/api/org` → Kiosk,
Loki queries → 404, only `hardware-fleet` visible, `metrics.old.example.com` still 200.

## port-scoping.sh — shipped, ran, reverted

`Scripts/audit-20260907-port-scoping.sh` was meant to `ufw route`-scope `:2375`/`:9001`/`:8080`, the
Matrix ports, and the metrics stack. It was a mistake to ship it as a blanket per-host script: its
`deny ... to any port <p>` rules on `infra` also drop traffic *from containers on infra* —
`homepage-local` queries every other host's `dockerproxy`, and its pre-MASQUERADE source is the bridge
IP, not `10.10.36` — so the homepage Docker-widget grid went dark fleet-wide. Reverted with
`Scripts/audit-20260907-REVERT-port-scoping.sh`. Port scoping is now issue #19: it needs a per-host
design accounting for infra's own containers + the subnet-route SNAT, rolled out incrementally.

## Still to run

- **`edge-dns-rule.sh`** on `edge` (cosmetic — swaps the dead `on eth0` rule for `ens6`) + the real
  fix, an **IONOS support ticket** to disable DNS on `203.0.113.10` / `203.0.113.11` (issue #23).

## Verified already-good

MaxScale admin API default cred already rotated (401); qBittorrent/SABnzbd enforce auth; Edge's public
surface is otherwise just 443; `*.old.example.com` admin hostnames are `NXDOMAIN` on public DNS; the
`10.10.78` "unknown host" is `sakura`'s dock IP (documented in `Scripts/README.md`); the
`dyonisis` `node_exporter` iptables scoping from 2026-08-25 works as intended.

## Deferred (Forgejo issues, filed 2026-09-07)

**#18** shared DB ports unscoped · **#19** flat network / per-port scoping needs a real project ·
**#20** AI-app forward-auth bypass on the LAN · **#21** `dyonisis` host firewall · **#22** Edge's
undocumented 4th public IP · **#23** Edge open-resolver IONOS ticket · **#24** plaintext secrets in
git (accepted per `CLAUDE.md`, tracked anyway) · **#25** Home Assistant SMB/WSD/rpcbind.

## Status

Fixed live: `dyonisis` rpcbind, Forgejo signup, Portainer `AGENT_SECRET`, Grafana anon → Kiosk org.
Reverted: port-scoping. Outstanding: `edge-dns-rule.sh` + IONOS ticket, and issues #18–#25.
