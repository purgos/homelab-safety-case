---
date: 2026-09-07
resolved: 2026-09-07
severity: degraded
kind: security
hosts: []
backfilled: true
---

# Grafana anonymous access let anyone on the LAN/tailnet read all fleet logs

**Status**: **RESOLVED 2026-09-07**. Anonymous access moved to a Prometheus-only "Kiosk" org;
verified anon can no longer reach Loki (`/api/ds/query` + `/api/datasources/proxy/` against the
Loki UID → 404) while `metrics.old.example.com` and the hardware-fleet dashboard still render with no
login. See "Resolution" at the bottom.

## What was found

`grafana.old.example.com` (`10.10.51:3001`, v13.2.0) has `[auth.anonymous] enabled = true`,
`org_role = Viewer`, `org_name = Main Org.` — added 2026-09-05 so `sakura`'s HTML-wallpaper ambient
display and `metrics.old.example.com` render the `hardware-fleet` dashboard without a login.

A Viewer — including the anonymous one — can use Grafana's **datasource proxy**. Verified live from
`tomo` with no credentials:

```
GET /api/datasources/proxy/uid/<Loki-uid>/loki/api/v1/labels   -> 200
GET /api/datasources/proxy/uid/<Prometheus-uid>/api/v1/query    -> 200
GET /api/search                                                  -> 200  (lists every dashboard)
```

So anyone on the LAN, or any tailnet device with "Accept routes" on (personal phones, `sakura`, the
about-to-be-gifted `tomo`, a compromised personal device), can run **arbitrary LogQL against all fleet
logs** in Loki — NPM access logs, Synapse, Authentik, etc., which routinely contain session tokens,
password-reset links, API keys apps log on error, and email addresses. Prometheus (metrics only, not
secret) is also fully queryable.

`grafana.old.example.com` is internal-only (`NXDOMAIN` on public DNS, NPM-Local only) so this is not
internet-exposed — but "internal" here still means the whole flat LAN + tailnet.

## Why the obvious fixes don't work

- The kiosk embeds a live Grafana panel via `<iframe>`; an iframe can't send an `Authorization: Bearer`
  header, so a service-account token can't replace anonymous auth for the embed directly.
- You can't render a live Loki/Prometheus panel for anon without also letting anon hit `/api/ds/query`
  with an arbitrary datasource — Grafana OSS has no per-datasource permissions for the Viewer role.
- The only clean split is **orgs**: anon in a dedicated org that has *only* a Prometheus datasource.

## Resolution (2026-09-07)

`Scripts/audit-20260907-grafana-kiosk-org.sh`, run against a freshly reset `admin`:

1. `docker exec grafana grafana cli admin reset-admin-password <pw>` — the compose's
   `GF_SECURITY_ADMIN_PASSWORD` was stale (Grafana only applies it on first init), so there was no
   working server-admin. The reset restored it (`isGrafanaAdmin: true`); the SSO admin user is separate
   and untouched.
2. Script created org **`Kiosk`** (id 2) with **only** a Prometheus datasource (new uid
   `efxi4z2gk9mv4a`), and copied `hardware-fleet` into it.
3. `sed -i 's/^org_name = Main Org\.$/org_name = Kiosk/'` on
   `/root/monitoring/grafana-auth/grafana.ini`, then **`docker restart grafana`** — note
   `docker compose up -d` does **not** recreate the container for a bind-mounted *file content* change,
   so it kept running the old config until an explicit `docker restart`. That was the one gotcha.
4. The copied dashboard still referenced Main Org's Prometheus uid (`efvxx97ov32tca`), which doesn't
   exist in Kiosk — remapped every `"uid": "efvxx97ov32tca"` → `"efxi4z2gk9mv4a"` in the Kiosk copy
   via `/api/dashboards/db`.

**Verified** (anon, no credentials):
- `/api/org` → `Kiosk` (was `Main Org.`)
- `/api/datasources/proxy/uid/dfw2off7pzfuoa/...` and `/api/ds/query` with the Loki uid → **404**
- `/api/search` → only "Hardware Fleet Overview" (CrowdSec / system-posture / proxmox / etc. no longer listed)
- `/d/hardware-fleet` → 200 with live panel data; `https://metrics.old.example.com/` → 200

The kiosk pages (`/opt/grafana-kiosk/{dashboard,index}.html`) iframe `grafana.old.example.com/d/hardware-fleet/…`
— same UID in both orgs, so no change needed there.
