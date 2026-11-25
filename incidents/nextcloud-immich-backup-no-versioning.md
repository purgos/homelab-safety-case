---
date: 2026-08-09
resolved: 
severity: degraded
kind: security
hosts: []
backfilled: true
---

# Nextcloud/Immich's Mega S4 backups had no versioning — ransomware could overwrite the offsite copy

## What broke

Nothing was down — this surfaced while redesigning
`Planning/Hardware/offsite-backup-nas.md`'s replacement (see
that doc's superseded banner and
`Planning/Strategies/backup-ransomware-protection.md`).
Checking what the offsite leg for Nextcloud/Immich actually did today (rather than assuming a new box needed
to be built) turned up a live gap in already-deployed automation instead.

## Root cause

`/root/scripts/nextcloud-backup.sh` and `/root/scripts/immich-backup.sh` on the Storage VM
(daily cron, 4:00am/4:15am) were plain two-line `rclone sync` calls pushing `/mnt/storage/Nextcloud` and
`/mnt/storage/Immich` to their own Mega S4 buckets (`nextcloud-community`, `immich-community`) — no versioning, no
history. `rclone sync` mirrors the source: a file that's overwritten locally gets overwritten remotely on the
very next run, and a file that's deleted locally gets deleted remotely too.

That's fine for accidental deletion (the source of truth just doesn't have the file anymore), but it means a
ransomware event that encrypts a file *in place* — same filename, new content — would get faithfully mirrored
over the last-good cloud copy on the next scheduled sync, with nothing to roll back to. This is exactly the
class of risk the 2026-07-11 ransomware incident (see `Hardware/storage/README.md`)
motivated `backup-ransomware-protection.md` to defend against in the first place, but these two scripts
predated that doc and were never brought in line with it.

## Resolution

1. Confirmed live behavior via SSH before changing anything: read both scripts and the crontab on `storage`
   directly, per the repo convention of re-verifying live state over trusting doc prose.
2. Added `rclone --backup-dir` to both scripts, pointed at a **separate bucket per app**
   (`nextcloud-community-versions`, `immich-community-versions`) rather than a subfolder of the existing bucket —
   rclone rejects `--backup-dir` paths that overlap the sync destination (hit this directly: first attempt
   used a `_versions/` subfolder inside the same bucket and failed with `destination and parameter to
   --backup-dir mustn't overlap`). Created both new buckets via `rclone mkdir` (no manual Mega console step
   needed — the existing Pro III credentials already had permission).
3. Anything a daily sync would now overwrite or delete gets moved into a dated
   `<bucket>-versions/<YYYY-MM-DD>/` folder instead of being destroyed.
4. Added `/root/scripts/s4-versions-prune.py` — a single script parametrized by remote/bucket, reused for
   both apps, mirroring the separation of concerns `mega-sync.sh`/`mega-prune.sh` already use for VM backups
   on `dyonisis` (the sync job never deletes; a separate scheduled prune job is the only thing allowed to).
   Deletes dated version folders older than 30 days. Retention is a flat 30 days rather than a multi-tier
   schedule deliberately — every retained version is real cost against the shared 20TB Mega Pro III
   entitlement that VM backups, Nextcloud, Immich, and media backups all draw from, not free space on a
   dedicated disk array.
5. Added two new cron entries (5:00am/5:05am, after both syncs and the existing 4:30am media job) to run the
   prune script daily.
6. Verified end-to-end before trusting it unattended: dry-run on both sync commands first, then a real run
   of each (confirmed via `rclone lsf --dirs-only` that the dated folder appeared, with the one changed
   Nextcloud file — its own log — correctly moved rather than overwritten), then a manual run of the prune
   script (confirmed it exits cleanly reporting nothing to prune, since nothing is 30 days old yet).

## Lesson

A backup job that's technically running successfully (exit 0, files present in the bucket) isn't the same as
one that actually resists the threat it exists to defend against — this pair had been "working" every day
since it was built, and would have kept "working" straight through a ransomware event by faithfully mirroring
the encrypted files offsite. Worth periodically asking not just "is the backup job green" but "what would
this job actually do if the source were compromised right now" for anything protecting irreplaceable data.

Also: `rclone --backup-dir` cannot point inside the same bucket/path it's backing up — confirm this before
writing the change, not after the first production run fails. A separate bucket (or a genuinely separate
remote path) is required.

## Status

Closed 2026-08-09.
