---
date: 2026-11-02
resolved: 
severity: degraded
kind: incident
hosts: []
backfilled: true
---

# Mega S4 duplicate keys: corrupt PBS chunks on Mega, `S4ArchiveBucketFailed` (2026-11-02)

## What broke

- **2026-11-02 22:31**: `S4ArchiveBucketFailed{bucket="member-purgos"}` (critical) from Community-Ops. The nightly
  Glacier archive on community-archive
  (12:00 → 22:16) failed only on `member-purgos`. `community-vms` and `community-cloud-backups` were fine. The last fully
  successful run was 2026-11-01 13:37.
- The archive log (`/var/log/s4-archive/archive-20261102-120013.log`) shows 4 chunks in
  `member-purgos/pbs-main/gen-2026-11/.chunks/4898/` failing with
  `failed to open source object: object not found` on all 3 rclone attempts. It also shows 10 chunks in neighbouring
  folders logged as `Duplicate object found in source - ignoring`.

## Root cause

**Mega S4 sometimes stores two objects under the same key, and a GET for that key then returns a broken body.**

- **Trigger, 2026-11-01 18:11**: the `pbs-offsite.sh` upload of the new monthly generation `gen-2026-11` (dyonisis)
  got `Failed to copy: object not found` on 7 chunks in `4898/` during a ~20 s burst. In the same burst, chunks in
  `4886 4887 488c 488e 488f 4892 4898` were written twice.
- **Result on Mega** (rclone `s4-sync`, `rclone cat | md5sum` against the local datastore):
  - A duplicated key is listed twice. A GET returns **both copies concatenated** (2× the size), so the chunk is
    corrupt on read.
  - Folder `4898/` is fully broken: all 8 chunks read as 0 bytes ("not found") or doubled, and it changes from one
    minute to the next.
  - The listing still shows the 3 never-uploaded chunks at the right size. `pbs-offsite.sh` uses `--size-only`, so
    it thinks they're there and never re-sends them.
  - `gen-2026-11`: 14 bad chunks (8 in `4898` + 6 duplicates). It was nevertheless **marked `.complete`** at
    2026-11-02 22:41.
  - `gen-2026-10` (the other complete generation) also has **2 bad chunks**, duplicated since earlier uploads:
    `2e07/2e077ce5…` (read 2,465,602 B, real 1,232,801 B; dup first logged 10-30) and `59a3/59a3e830…` (read
    8,388,696 B, real 4,194,348 B; dup first logged 10-26).
  - Every other chunk sampled is fine: 25 random chunks plus every non-duplicated chunk in the 7 folders matched.
- **Glacier is clean for what it holds.** The copies of the gen-2026-10 duplicates and of `4886c27b…` in
  `community-s4-archive` have the true sizes. The `4898` chunks never reached Glacier (that is the failure).
- Every PBS chunk is a whole object written once (`--immutable`), so a doubled body breaks every snapshot that
  references it when restored from Mega. The local PBS datastore is intact.

## Actions taken (2026-11-02, Claude)

- Re-uploaded the 3 missing `4898` chunks from `/mnt/pve/local-backup/pbs-datastore/.chunks/4898/` with
  `rclone copyto` (log `/root/backup/reupload-4898-2026-11-02.log`). **That made it worse**: one of them now reads
  doubled, and 2 chunks that had read correctly minutes earlier went "not found". All writes into the folder were
  stopped after that.
- Full key listings saved on dyonisis: `/root/backup/mega-gen-2026-{10,11}-list.txt`.

## Repair (2026-11-02 ~23:00, Purgos chose "delete + re-upload")

- Key list: `dyonisis:/root/backup/repair-keys-2026-11-02.txt` = 16 keys (2 in gen-2026-10, 6 dups in gen-2026-11, and
  all 8 in `gen-2026-11/.chunks/4898/`). Copy on Metrics.
- Delete on Metrics with `s4-prune` (`rclone deletefile`, repeated until the key is no longer listed; log
  `/root/repair-delete-2026-11-02.log`). Each duplicated key needed **two** deletes, one per copy. That confirms
  two objects stored under one key.
- Re-upload on dyonisis with `s4-sync`, `rclone copyto`, one at a time (log
  `/root/backup/reupload-repair-2026-11-02.log`).
- Verify: all 16 listed exactly once and md5-identical to the local datastore via GET. Then every chunk in the 9
  affected folders was re-checked (all OK), and a full duplicate-key scan of both generations came back with 0.
- A manual archive run (`systemctl start s4-archive.service`, 2026-11-02 23:21 → 11-03 00:56) finished with
  `rc=0` and no `Duplicate`/`ERROR` lines. All three buckets show `s4_archive_bucket_ok` = 1, so the alert cleared.

## Separate finding: gen-2026-10 top-up always `partial`

`pbs-offsite.sh` step 2 for gen-2026-10 fails every day with `index.json.blob: ... immutable file modified`. PBS rewrites
a snapshot's manifest after the fact (e.g. a verify job's result goes into the manifest), and `--immutable` refuses the
new version. So `last-status` = `partial` and `pbs-offsite.service` exits 1. Chunks are unaffected. The fix is in the
script (allow manifests to be updated, or compare only the chunks), tracked in #118.

## Status

**Mega repaired 2026-11-02**, Forgejo #118 stays open for
the follow-ups:

- ~~`pbs-offsite.sh`: catch duplicate keys and failed uploads before writing `.complete`~~ **done 2026-11-03**:
  duplicate-key scan plus a `suspect-<gen>` re-check after every chunk pass. The gen-2026-10 `partial` was fixed too:
  snapshots now use `--ignore-existing`. See `VMs/pbs/README.md`. Tested by dry-run on the community target: a clean
  pass, and a forced bad chunk that blocked `.complete`.
- `s4-archive.sh` / the prune script: treat `Duplicate object found` as an error. It is currently only a NOTICE.
- Report the duplicate-key behaviour to Mega support.
