---
date: 2026-10-02
resolved: 
severity: minor
kind: incident
hosts: []
backfilled: true
---

# vm-backups bucket at 23.7 TiB — retention prune never matched any file

**Found:** 2026-10-02

## Symptoms
Mega S4 `vm-backups` bucket held 23.7 TiB / 3,272 objects, with backups back to 2026-08-14 for every VM
(~150 objects per VM) despite the 7-daily + 30-day-Sunday retention policy.
`/var/log/s4-vm-backup-prune.log` on Infrastructure said "nothing to prune" every day since 2026-08-24.

## Root cause
`NAME_RE` in `s4-vm-backup-prune.py` (and the original `mega-prune.sh`) used `-\d{6}\.` for the time part, but
Proxmox names files `vzdump-qemu-100-2026_08_14-01_00_02.*` (underscores). Nothing matched, so the script
saw an empty set and exited cleanly. Present since the 2026-08-16 port.

## Resolution
- Regex fixed to `-\d{2}_\d{2}_\d{2}\.` in the live script and `Hardware/dyonisis/backup/mega-prune.sh`.
- Added a guard: remote has files but none match -> exit non-zero instead of "nothing to prune".
- Dry-run before first real run: keep 815 objects (6.9 TiB), delete 2,457 (16.8 TiB).
- Old live script backed up as `/root/scripts/s4-vm-backup-prune.py.bak-2026-10-02`.

## Lesson
A prune job that always reports "nothing to prune" needs a sanity check against the bucket size.
