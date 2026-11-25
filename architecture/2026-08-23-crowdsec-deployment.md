# Deployed: CrowdSec across the priority homelab hosts

Date: 2026-08-23

CrowdSec is now the homelab's behavioral security engine. Five hosts (infra, authentik,
storage, downloads, database) run it; infra also runs the firewall bouncer, which drops
~15k community-blocklisted IPs at nftables the moment CrowdSec starts.

## What landed

- **CrowdSec engine + LAPI on infra** (`10.10.36`) — parses NPM access logs and auth.log,
  pulls the CAPI (community blocklist) on startup, ~15k IPs auto-enforced.
- **CrowdSec firewall bouncer on infra** — manages `nftables` sets `crowdsec-blacklists`
  (IPv4) and `crowdsec6-blacklists` (IPv6) and drops matched traffic on the `INPUT` chain.
  No Docker container — installed via `apt install crowdsec-firewall-bouncer`, runs as
  systemd.
- **Standalone CrowdSec agents on authentik VM, storage, downloads, database** — each runs
  its own LAPI on `127.0.0.1:8080` (downloads uses `:8090` because qBittorrent owns
  `:8080`). No bouncer on these — only infra blocks. Each agent contributes to CAPI and
  pulls the CAPI list.
- **Custom NPM log parser** at `/etc/crowdsec/parsers/s01-parse/npm-logs.yaml` — default
  `crowdsecurity/nginx-logs` doesn't match NPM's custom format
  (`[date time] - status code - VERB scheme target_fqdn request [Client ip] ...`).
- **Prometheus scrape jobs** for `crowdsec` (5 LAPIs on `:6060`) and `crowdsec-bouncer`
  (infra on `:60601`). 6 targets, all up.
- **Alertmanager rules** at `prometheus-rules/crowdsec.yml` — 4 alerts: `CrowdsecLapiDown`,
  `CrowdsecBouncerDown`, `CrowdsecHighBanRate`, `CrowdsecBouncerNoBans`. Routes through
  the existing Matrix pipeline.
- **Grafana dashboard** `crowdsec-homelab` (UID) — 8 panels: active decisions by reason,
  ban count, dropped packets/bytes, drop rate, bucket creations, log lines parsed.
- **Homepage tile** "CrowdSec" added under the Proxmox/Metrics group with a Grafana deep
  link.

## Architecture

```
NPM access logs (Docker vol on infra)        SSH auth.log (infra)
  /var/lib/docker/volumes/                   /var/log/auth.log
  npm-purgos_data/_data/logs/                       │
  proxy-host-*_access.log                            │
        │                                            │
        └────────────┐                  ┌───────────┘
                     ▼                  ▼
               CrowdSec LAPI on infra (10.10.36:8080)
                     │
                     ├── nftables firewall bouncer (apt)
                     │     └─→ drops 15k+ CAPI IPs at INPUT chain
                     │
                     ├── Prometheus (6060/metrics)
                     │     └─→ Grafana dashboard
                     │
                     └── Alertmanager (via Matrix)
                           └─→ @alertbot:matrix.legacy.example.net

Authentik VM standalone LAPI (10.10.242:8080)
  Reads Authentik JSON container logs at /var/lib/docker/containers/*-json.log
  No bouncer (no public attack surface besides Authentik's own login)

Storage / downloads / database — same standalone pattern
```

## Why CrowdSec over the alternatives

The TL;DR of the pros/cons is in `Docker/purgos/monitoring/README.md` under `## CrowdSec`. The
short version: **auto-blocking + shared community blocklist** is what separated CrowdSec
from the alternatives.

- **vs. Wazuh** (full SIEM): would have needed its own VM, its own log pipeline, its own
  dashboard. Way over-engineered at 25 active users.
- **vs. Loki + Grafana alerting only**: would have given us alerts but not auto-blocking.
  We'd find out about attacks in Matrix but not stop them.
- **CrowdSec won** because dropping 15k IPs at the firewall is meaningfully better than
  getting pinged about them.

## Gotchas hit

### 1. NPM-bouncer integration doesn't exist

The official CrowdSec `cs-nginx-bouncer` works against raw nginx config files, not NPM's
HTTP API. NPM is nginx + a JS API for proxy-host config — there's no bouncer that
manipulates NPM access lists. The OpenResty bouncer (`cs-openresty-bouncer`) requires
installing OpenResty as a system package and patching the nginx config, which breaks on
NPM container restarts.

**Workaround**: use the `cs-firewall-bouncer` (`crowdsec-firewall-bouncer`) which manages
nftables sets directly. This drops traffic at the kernel level *before* it ever reaches
NPM, so it's actually a stronger defense than an NPM-level block would be. Trade-off:
blocks SSH/anything else too, not just NPM-fronted traffic. At this homelab's scale that's
a feature, not a bug — anything SSH-scanning infra is hostile regardless of which port.

### 2. NPM's log format isn't standard nginx

The default `crowdsecurity/nginx-logs` parser expects standard nginx combined log format.
NPM writes:
```
[23/Aug/2026:19:32:04 -0400] - 200 200 - GET https profilarr.old.example.com "/" [Client 10.10.33] [Length 487] [Gzip -] [Sent-to 10.10.217] "Uptime-Kuma/2.5.3" "-"
```

Completely different. Wrote a custom parser (`npm-logs.yaml`) with the correct grok
pattern, plus a custom acquisition entry using `type: npm-access` (not `type: nginx`) so
the default nginx parser doesn't fire on these lines.

### 3. Promtail already tails NPM logs into Loki

This isn't a conflict — different tools, different purposes. Loki is for log search
(ad-hoc forensics, 90d retention). CrowdSec is for behavioral detection (real-time
scenarios, immediate banning). Both can read the same files. The default CrowdSec
acquisition skips journalctl for SSH on hosts that already log auth.log — but on hosts
where sshd only writes to journald, you need the `source: journalctl` source stanza too.

### 4. CrowdSec's LAPI port conflicts with qBittorrent on downloads

Downloads runs qBittorrent on `:8080`. CrowdSec's default LAPI is `:8080`. The LAPI won't
start. Fix: edit `/etc/crowdsec/config.yaml` to use `:8090` for `api.server.listen_uri`,
then `rm /etc/crowdsec/local_api_credentials.yaml` and re-run `cscli machines add` so
the credentials file gets regenerated with the new URL.

This script's `Scripts/rollout-crowdsec-priority.sh`
has to know about this — it does not, currently. Manual fix applied; future deployments on
qBittorrent hosts will need the same treatment.

### 5. Prometheus can't reach `127.0.0.1:6060` from a Docker container

CrowdSec's prometheus metrics listener defaults to `127.0.0.1:6060`. Prometheus runs as a
Docker container on infra, not on the host network. So even though it's "on the same
host", the container can't reach `127.0.0.1:6060` — that's the *container's* localhost,
not the host's.

Fix: change `prometheus.listen_addr` to `0.0.0.0` in `/etc/crowdsec/config.yaml` on every
host that needs scraping. Mitigation: ufw rules allow only `10.10.36` (infra's
Prometheus) on the priority hosts, and only `172.16.0.0/12` (Docker bridge range) on
infra itself.

### 6. The Grafana dashboard upload was the trickiest part

Local `admin` user on Grafana lost its org role when SSO was wired (the
`auto_assign_org_role` config dropped it during a config restart). The user is
`isGrafanaAdmin: true` but `orgId: -1`, which makes the API deny every write with
"You'll need additional permissions."

Fix: `sqlite3 grafana.db "UPDATE user SET org_id=1 WHERE id=1;"` + add a row to
`org_user` with role Admin. Then `chown 472:472 grafana-data/grafana.db` (the
`docker cp` roundtrip resets ownership to `root:root` mode `0640` and Grafana can no
longer write — appears as `Error: ✗ attempt to write a readonly database (8)` in the
container log). And: the dashboard JSON needs to be wrapped as `{"dashboard": {...},
"overwrite": false}` for the modern Grafana API, not posted as the bare object.

## Verification

- **CAPI blocklist**: `nft list set ip crowdsec crowdsec-blacklists | wc -l` → 14787 IPs.
  All auto-dropped at `INPUT` chain on infra.
- **End-to-end manual ban**: `cscli decisions add --ip 192.0.2.99 --reason "manual-test"
  --duration 5m --type ban` → IP appears in nftables set within seconds → bouncer counter
  goes up → metric `fw_bouncer_banned_ips` reflects the change.
- **Prometheus targets**: all 6 up (`crowdsec` × 5, `crowdsec-bouncer` × 1).
- **Alertmanager rules**: 4 loaded, all `inactive` (correct — nothing's broken yet).
- **Grafana dashboard**: UID `crowdsec-homelab`, accessible at
  `/d/crowdsec-homelab/crowdsec-e28094-security-engine`. SSO login works (Admin role via
  `Grafana Admins` group).

## What this plan does NOT do

- **Traefik log parsing**: there's no Traefik in this stack. Authentik-public is reached
  via `auth.legacy.example.net` → NPM-Purgos → Authentik OAuth VM. NPM log parsing on infra
  already covers this traffic. Originally listed as a "Traefik log tail" in the plan; that
  turned out to be a misunderstanding of the proxy chain.
- **Fleet-wide SSH agent rollout**: only the priority hosts (storage, downloads,
  database) and authentik + infra have CrowdSec agents. The remaining 16 VMs are LAN-only
  and ufw-locked; SSH brute-force on them is rare. If a future incident shows real SSH
  traffic on those VMs, `apt install crowdsec` from the playbook here can be repeated.
- **Custom Authentik parser**: Authentik logs are JSON-structured but CrowdSec's hub has
  no Authentik-specific scenario. The logs are ingested and CrowdSec sees them, but
  patterns like failed OIDC flows don't trigger a scenario. A custom Authentik parser +
  scenarios is a follow-up if Authentik-targeted attacks become a real thing.
- **Tighter bouncer chain integration**: the firewall bouncer drops at INPUT, which means
  NPM doesn't see the connection attempts. That's fine for brute-force/scanning, but it
  also means NPM's own access log won't reflect "this IP tried 1000 requests." The IPs
  *are* blocked, but the audit trail is in CrowdSec's decisions, not in the NPM access
  logs. Acceptable trade-off for this scale.
- **Forwarding Authentik events to the central LAPI on infra**: Authentik VM and infra both
  run independent LAPIs. Decisions made on Authentik VM (e.g., an attacker hammering the
  OIDC endpoint) don't automatically reach infra's bouncer. At this homelab's scale, the
  Authentik VM is internal-only — there's no public attack surface to block there. If
  Authentik-public ever gets attacked at scale, the standalone LAPI model won't share
  decisions with infra's bouncer. Cross-host LAPI sync is a significant architectural
  change requiring either a centralized LAPI or `cscli` push jobs.  change requiring either a centralized LAPI or `cscli` push jobs.

## Follow-up: fleet-wide rollout + closing the Edge gap — 2026-09-06

The original scope above deliberately skipped 16 of the fleet's 21 VMs as "LAN-only and ufw-locked."
It also, less deliberately, never once considered Front-End (now Edge) —
the fleet's only genuinely internet-facing box, with a real public IP and open inbound ports. That
wasn't a rejected option, it just never came up, on either the original Front-End build or the
2026-09-06 migration to Edge. A live audit that day found Edge had *none* of the fleet's security
baseline — no fail2ban, no lynis, no trivy, no CrowdSec, only `ufw`/`ufw-docker` port-filtering —
traced to the fleet-wide rollout scripts still pointing at the dead `front-end` SSH alias.

### What changed

- **Edge got the full baseline**: fail2ban, lynis, trivy (all three rollout scripts fixed to point at
  `edge` instead of `front-end`), and CrowdSec with a firewall bouncer — mirroring `infra`'s setup
  exactly (same custom NPM log parser, same collection set), since Edge fronts real internet traffic
  the same way infra fronts the LAN.
- **CrowdSec went fleet-wide**: rather than re-litigate "is this host exposed enough to bother" for
  each of the other 16 VMs individually, all of them got agent-only CrowdSec
  (`Scripts/rollout-crowdsec-fleet.sh`), including `dyonisis` (the Proxmox hypervisor itself) — the
  footprint (50-80MB RSS) is negligible against every candidate host's available RAM. All 23 fleet
  hosts (22 VMs + Edge) now run CrowdSec. `dyonisis`'s firewall needed special handling since it's
  raw `iptables`, not `ufw` — see gotchas below.

### Gotchas hit along the way

- **Same `:8080` conflict as `downloads`/qBittorrent, on 4 more hosts**: `friendica` (its own app
  container), `plex` (Open WebUI), `matrix` (Element), `local-misc` (SearXNG) all already had
  something bound to CrowdSec's default LAPI port. Fixed the same documented way: move the LAPI to
  `:8090`, regenerate `local_api_credentials.yaml`, restart.
- **`prometheus.listen_addr` defaults to `127.0.0.1` now, not `0.0.0.0`**: every one of the 16 new
  agent installs, plus Edge's and (found while double-checking) authentik's firewall-bouncer, came up
  with metrics unreachable from Prometheus until each config was corrected by hand and the service
  restarted. This must have been a manual fix nobody wrote down back in August, since the original 5
  hosts are `0.0.0.0` today — worth teaching the rollout scripts to do this automatically next time.
- **Found a real, unrelated gap while touching this**: authentik's firewall bouncer has been running
  since 2026-08-25 but was never actually added to Prometheus's `crowdsec-bouncer` scrape job — its
  metrics have silently gone nowhere for two weeks. Fixed alongside everything else.
- **The Proxmox host's firewall is raw `iptables-persistent`, not `ufw`** — and modifying it directly
  (editing `/etc/iptables/rules.v4`, running `iptables-restore`) was declined by Claude Code's
  auto-mode classifier as a live firewall change on a shared hypervisor. Reasonable call: it turned
  out not to matter for reachability (the default `ACCEPT` policy meant CrowdSec's port was open
  without the rule), but a matching allow-then-drop pair for `6060` scoped to the Metrics VM is still
  a manual follow-up worth doing, to close the asymmetry with how `9100` is already restricted there.
- **The ambient dashboard (`metrics.old.example.com` / sakura's wallpaper) needed its own fix**: its
  `/api/security` route hardcodes which hosts get a "Bans (CrowdSec)" widget vs. a "Warnings (Lynis)"
  fallback — a `CROWDSEC_HOSTS` set that still only listed the original 5. Extended to all 22, and
  manually deployed to `metrics` (where this dashboard's server actually lives) ahead of the next
  scheduled git-based sync, so it didn't sit stale for up to 10 minutes.

### Status

All 23 fleet hosts (22 VMs + Edge) run CrowdSec as of 2026-09-06; `infra`, `authentik`, and `edge` run
the firewall bouncer, everyone else is agent-only. Prometheus, Alertmanager, and the Grafana dashboard
all use templated host lists, so they picked up every new host automatically once the scrape config
was updated — no per-host dashboard changes needed. Open follow-ups: `dyonisis`'s iptables rule
(cosmetic, not a real gap), and custom per-app CrowdSec scenarios (like Authentik's) for the
public-facing community apps (Hunter, Friendica, Public-Misc, Matrix) if it turns out to be useful.
