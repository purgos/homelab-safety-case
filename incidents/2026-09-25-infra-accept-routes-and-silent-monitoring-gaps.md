---
date: 2026-09-25
resolved: 2026-09-25
severity: outage
kind: incident
hosts: []
backfilled: true
---

# 2026-09-25: three silent monitoring gaps + a repeat LAN outage, found while locking down the tailnet

**Status: closed 2026-09-25.** None of these alerted. All were found while mapping dependencies before
switching the Headscale ACL to default-deny.

## 1. `community-infra` LAN-unreachable (repeat of 2026-09-18)
- **Symptom**: ping/SSH to `10.10.243` timed out from the LAN; it was reachable only via `100.64.0.3`.
  Home Prometheus failed every scrape of the metrics bridge (19100–19106) → **no home-side metrics for the
  cloud boxes for ~3 days**.
- **Root cause**: `tailscale` `RouteAll=true` (accept-routes) on a host that lives *on* the advertised LAN.
  Table 52's `10.10.0/24 dev tailscale0` captured the replies. It was probably re-enabled around the 2026-09-22 reboot.
- **Fix**: `tailscale set --accept-routes=false`; table 52 came back clean by itself. Checked the other 5 LAN nodes
  on Headscale: all `RouteAll=false`.
- **Why it mattered for the ACL**: its public sites only worked because NPM reached LAN backends *through*
  Subnet-Router. Default-deny would have broken them. Fix order matters.

## 2. Loki not ingesting since 2026-09-22 02:02
- **Symptom**: Promtail on `cloud-edge`/`cloud-auth`: `context deadline exceeded` pushing to `100.64.0.3:3100`.
- **Root cause**: after the reboot Loki's container IP moved `172.20.0.2 → .5`, but the `ufw-docker` allow
  rule still targeted `.2`, so `DOCKER-USER` dropped it. That's the same class as `infra-npm-ufw-docker-stale-ip.md`.
- **Fix**: deleted the stale rule, `ufw-docker allow loki-community-wtf 3100/tcp`. Pushes resumed (0 errors).

## 3. Headscale metrics never scrapeable
- **Symptom**: Prometheus target `headscale 100.64.0.1:9090` down.
- **Root cause**: `metrics_listen_addr: 127.0.0.1:9090` listens only on the container's loopback, so the host
  port forward reached nothing.
- **Fix**: `0.0.0.0:9090` inside the container; host binding tightened to `100.64.0.1:9090`. Scrape `200`.

## Bonus: cloud-edge CrowdSec metrics (`100.64.0.1:6060`) missing after the 2026-09-24 reboot
The same tailnet-IP boot race as the NPM outage: CrowdSec started before `tailscaled` had the IP. Fixed with a
`systemctl restart crowdsec`. `ip_nonlocal_bind=1` (now on cloud-edge, cloud-auth, community-infra) prevents it.

## Lesson
Every one of these showed up only as "target down" in a dashboard nobody was watching. External alerting (security
review F5) plus a Prometheus alert on `up == 0` for the cloud jobs would have caught all four within minutes.
