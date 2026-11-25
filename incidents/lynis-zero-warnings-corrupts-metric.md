---
date: 2026-08-26
resolved: 
severity: minor
kind: incident
hosts: []
backfilled: true
---

# `lynis_warnings_total`/`lynis_suggestions_total` corrupted when the count is exactly zero

## What broke

While checking why the Grafana/Prometheus lynis warning count showed **2** on the Database VM
(`10.10.161`) against **1** everywhere else in the fleet, the "2" itself turned out to be stale (see
below) — but re-running the audit manually to refresh it (`/usr/local/bin/lynis-audit.sh`) uncovered a
separate, real bug in the wrapper script installed by
`Scripts/setup-lynis.sh` (see that doc and
`Scripts/README.md` for the script's normal role —
it's the fleet-wide host-posture audit built 2026-08-25, related to the four bugs already documented in
`system-posture-dashboard-no-data.md`).

The original script computed the metric value as:

```bash
WARNINGS=$(grep -c '^warning\[\]=' "$REPORT" 2>/dev/null || echo 0)
```

`grep -c` always prints a count — even `0` — as long as the file exists, but it also **exits with status 1**
whenever that count is zero (this is standard `grep` behavior: exit 1 means "no lines matched", regardless of
`-c`). Bash's `||` triggers on that exit status, not on empty output, so the moment a host had zero lynis
warnings, both branches ran: `grep -c` printed `0`, *and* `|| echo 0` printed a second `0`. The command
substitution captured both lines, so `$WARNINGS` became the literal two-line string `0\n0`, and the emitted
Prometheus textfile looked like:

```
lynis_warnings_total 0
0
```

— a bare `0` on its own line with no metric name, which is invalid Prometheus exposition format. Whether
`node_exporter`'s textfile collector drops just this file or the point is silently mis-scraped, a host that
achieves the *best* possible lynis result (zero warnings) is the one case guaranteed to break its own metric.
This exact fragility (strict textfile-collector parsing) is the same class of bug as bug #4 in
`system-posture-dashboard-no-data.md` (repeated HELP/TYPE headers breaking the trivy metric).

Confirmed live on `database` (10.10.161) after it hit zero warnings for the first time.

A first attempted fix — dropping the `|| echo 0` fallback entirely in favor of a bash parameter-expansion
default — introduced a *worse* regression: `WARNINGS=$(grep -c ... 2>/dev/null); WARNINGS=${WARNINGS:-0}`
still runs under the script's `set -euo pipefail`, and a bare `VAR=$(cmd)` assignment where `cmd` exits
non-zero aborts the whole script right there (before the fallback expansion even runs), because `set -e`
inspects the exit status of the assignment, not just literal command lines. This silently skipped the
`.prom` file rewrite completely, leaving old/stale metric data in place with no error visible from the cron
job's perspective (`lynis-audit.sh` itself exited non-zero, but the cron log is the only place that's ever
surfaced).

## Root cause

Two compounding shell pitfalls in `Scripts/setup-lynis.sh`'s embedded audit wrapper:
1. `grep -c` conflates "count" (stdout) with "match found" (exit status) — treating a zero count as a failure
   condition via `||` double-prints output.
2. Under `set -e`, a failing command inside a `VAR=$(...)` assignment aborts the script even with no `||`
   chain visibly present on that line, because the assignment's own exit status is the substituted command's.

## Fix

`Scripts/setup-lynis.sh` (both `WARNINGS` and `SUGGESTS`) now uses:

```bash
WARNINGS=$(grep -c '^warning\[\]=' "$REPORT" 2>/dev/null || true); WARNINGS=${WARNINGS:-0}
```

`|| true` neutralizes `grep -c`'s exit status without adding any output of its own (unlike `|| echo 0`), so
the single line `grep -c` already printed is preserved; `${WARNINGS:-0}` only kicks in for the genuine
file-missing case, where `grep` prints nothing at all. Redeployed fleet-wide via `bash
scripts/rollout-lynis.sh` (2026-08-26) — this overwrites `/usr/local/bin/lynis-audit.sh` on all 23 hosts
unconditionally (the script's cron-file idempotency check doesn't gate the wrapper rewrite). Verified by
manually re-running `/usr/local/bin/lynis-audit.sh` on both a zero-warning host (`database`) and a
one-warning host (`infra`) and confirming single-line, correctly-formatted output in both cases.

## Why the original "2 vs 1" discrepancy existed (unrelated, already resolved)

Separately from the metric bug: the Database VM's lynis report that prompted this whole check was simply
**stale**. It had been generated at 00:25 UTC that morning while the VM was still running kernel
`7.0.0-28-generic` with `7.0.0-30-generic` already installed on disk (pending a reboot) — hence the extra
`KRNL-5830` "reboot needed" warning on top of the fleet-wide baseline `PKGS-7392` (pending package updates).
The VM was rebooted onto the new kernel before this was investigated; the stale report just hadn't been
regenerated yet (lynis only runs weekly via cron, Sun 04:00 UTC). No live problem — re-running the audit
after the reboot resolved it (and is what surfaced the metric-corruption bug above).

## Status

Closed 2026-08-26. Fix deployed fleet-wide (23/23 hosts); verified on both a zero-warning and a
one-warning host.
