---
date: 2026-10-22
resolved: 2026-10-22
severity: minor
kind: incident
hosts: []
backfilled: true
---

# Trivy + Lynis never ran after setup (cron.d file missing trailing newline)

**Status:** resolved 2026-10-22 (~00:35 UTC). Found while adding CVE email alerts.

## Symptoms

- Every host's `trivy_last_run_timestamp_seconds` was ~57 days old (2026-08-25, the setup day); only 6 hosts
  exported Trivy metrics at all. Grafana's CVE counts were two months stale.
- `lynis.prom` likewise last written 2026-08-25 on every host.
- Nothing alerted on staleness, so it went unnoticed for two months.

## Root cause

`setup-trivy.sh` and `setup-lynis.sh` built the cron line with `read -r -d '' CANONICAL <<'CRON'` (which strips
the trailing newline) and wrote it with `printf '%s'`, so `/etc/cron.d/trivy-scan` and `/etc/cron.d/lynis-audit`
had no final newline. Cron rejects such a file, and the only sign is a line in syslog on every cron (re)load:

```
cron[...]: (*system*trivy-scan) ERROR (Missing newline before EOF, this crontab file will be ignored)
```

The one-off manual runs during setup (2026-08-25) worked, which is why metrics existed at all.

## Resolution

- Both setup scripts now write `printf '%s\n'` (and compare the same way). Rolled out to all 22 hosts with
  `rollout-trivy.sh` / `rollout-lynis.sh`, whose host lists were also stale (removed retired
  friendica/matrix/nextcloud/edge; added purgos-infra, purgos-door, community-door, community-ops). Verified every
  host's two cron files end in `\n` and cron logs no errors for them.
- Trivy moved from 05:00 UTC (01:00 ET, inside the dyonisis vzdump window) to **11:00 UTC + 0-60 min random
  jitter**, so 22 VMs don't scan on the same disks at once. Scan JSONs older than 14 days are now deleted.
- Added `trivy_critical_total{image}` (CRITICAL only) next to the existing HIGH+CRITICAL gauge.
- Ran a jittered catch-up Lynis + Trivy pass on every host the same night.
- **Alerts** (`Docker/purgos/monitoring/prometheus-rules/security.yml`): `TrivyScanStale` (>2 days) and
  `LynisAuditStale` (>8 days) so this can't silently happen again, plus `TrivyNewCriticalCVE`.

## Lesson

Any script that writes `/etc/cron.d/*` must end the file with a newline. `grep "Missing newline" /var/log/syslog`
is the quick check.
