---
date: 2026-08-15
resolved: 
severity: degraded
kind: security
hosts: []
backfilled: true
---

# Offsite backups (media, Nextcloud, Immich, VM backups) weren't actually ransomware-proof — split sync/prune credentials across hosts

## What prompted this

While reviewing the media backup's version-on-overwrite protection (the
`--backup-dir` mechanism added 2026-08-09), a direct question came up: is this setup actually ransomware
resistant? The honest answer was no — `--backup-dir` protects against a *sync* silently overwriting a good
backup with a bad one, but the Storage VM held a single Mega S4 credential per
backup with full read/write/**delete** access to both the live bucket and its versions safety-net bucket,
and ran the prune step itself using that same credential. A compromise of the Storage VM — the realistic
threat model, since it's also where all the live data lives — would hand an attacker everything needed to
delete the version history that's supposed to be the recovery path, not just encrypt the live files. This
turned out to apply identically to all three Storage-VM-hosted offsite backups: media, Nextcloud, and Immich.

## What was checked first

**Does Mega S4 support S3 Object Lock/WORM**, which would make this a non-issue by making objects
undeletable for a retention window regardless of who holds the credentials? Checked directly against Mega's
own [`s4-specs`](https://github.com/meganz/s4-specs) API documentation: **no**. `x-amz-bucket-object-lock-enabled`
on `CreateBucket`, and every `x-amz-object-lock-*` header on `PutObject`/`CreateMultipartUpload`, are all
explicitly marked unsupported. Bucket/object versioning itself (the `versionId` parameter family) is also
unsupported. S4 has no server-side immutability story to build on at all — this isn't a missing config, the
storage backend genuinely doesn't offer it.

**Does Mega S4 support scoped/restricted access keys** instead, as the next-best option? Also checked
against `s4-specs`: **yes**. S4 provides genuine IAM-style managed policies —
`S3ListAccess`/`S3ReadAccess`/`S3WriteAccess`/`S3DeleteAccess`/`S3FullAccess` — cleanly separating list/read
from write from delete, attachable per-user via the IAM API (`AttachUserPolicy`). IAM user/access-key
*creation* itself isn't part of the documented API, though — that's done through Mega's S4 web console. All
managed policies use `"Resource": "*"`, meaning a single scoped key ends up account-wide (not scoped to one
bucket) — confirmed live when the new key could already list `media`, `nextcloud-community`, and `immich-community`
without being granted anything bucket-specific.

## What changed

1. Created one new Mega S4 access key (via the web console, by Purgos) with only `S3ReadAccess` +
   `S3WriteAccess` attached. Added as a `media-s4-sync` remote on the Storage VM, confirmed live: list/write
   succeed, `rclone deletefile` returns `403 AccessDenied: Request not allowed by policy`.
2. Confirmed the same key already worked account-wide against the Nextcloud/Immich buckets too (no need for
   two more keys) — renamed the remote to `s4-sync` to reflect that, and repointed `nextcloud-backup.sh` and
   `immich-backup.sh` at it alongside `media-backup.sh`.
3. Installed `rclone` on the Infrastructure VM and moved the three
   *original* (delete-capable) credentials there — `media-s4`, `nextcloud-s4`, `immich-s4` — copied
   server-to-server, one command per credential.
4. Moved all pruning off the Storage VM: `media-versions-prune.sh` (new, sweeps all 7 media categories in one
   daily pass) plus the pre-existing `s4-versions-prune.py` invocations for Nextcloud/Immich now run on
   Infrastructure's cron instead of Storage's.
5. Removed all three delete-capable remotes (`media-s4`, `nextcloud-s4`, `immich-s4`) from the Storage VM's
   `rclone.conf` entirely — it now only has `s4-sync` (scoped) and the unrelated `mega:` remote (used for
   vzdump backups). Ran a full end-to-end manual trigger of all three sync scripts afterward to confirm
   nothing broke.
6. Consolidated Infrastructure's three separate delete-capable credentials into one: a single new `s4-prune`
   key (see below), replacing `media-s4`/`nextcloud-s4`/`immich-s4` there too. All prune scripts/cron entries
   repointed at it, tested end-to-end (`media-versions-prune.sh` ran clean across all 7 categories).
7. Extended the same pattern to VM backups (2026-08-16): `dyonisis`'s `mega-sync.sh`/`mega-prune.sh` pair had
   the identical single-host, single-full-access-key gap, just with the native `mega:` remote instead of S4.
   Moved the sync to a new `vm-backups` S4 bucket using the same `s4-sync` credential (already account-wide,
   no new key needed) plus a `--bwlimit 50M` cap (dyonisis previously ran uncapped — fine for small daily
   deltas, not for the much larger first full push under the new setup). Pruning ported to
   `s4-vm-backup-prune.py` on Infrastructure using `s4-prune`, same tiered daily/weekly retention logic as the
   original. The old `mega:vm-backups` copy was deliberately left running under its original `mega-prune.sh`
   (unmodified) rather than migrated — nothing new lands there anymore, so it drains to nothing over ~30 days
   on its own, the same pattern already used for the older `mega-crypt:` generations.

## A real functional break found the same day — `--backup-dir` needs delete permission to work at all

The scoped `s4-sync` key (read/write only) worked fine for *new* files, but Nextcloud's next real sync
exposed the actual mechanics of `--backup-dir`: to replace a changed file, rclone has to (1) copy the old
version to the versions bucket, (2) **delete the old version from the primary bucket** to complete that
move, then (3) write the new content. A delete-incapable credential can do step 1 but not step 2 — so any
file that actually *changes* (not just new files) silently stopped updating offsite. Caught because
Nextcloud's own `nextcloud.log` changes on every run, so it failed every single sync;
media and Immich hadn't hit it yet only because nothing had needed replacing
during their test runs — the same failure was latent there too. Confirmed safe in the meantime: the failure
mode is stale, not corrupting — the primary bucket keeps the old, valid file rather than a broken partial
write, since rclone aborts that file's whole operation when the delete fails.

Checked whether Mega S4 supports **custom** IAM policies with bucket-specific resource scoping — the clean
fix would've been "allow delete on the live bucket, block it only on the versions bucket." It doesn't: no
`CreatePolicy`/custom-policy API exists in `s4-specs`, only the 5 pre-built managed policies, all
account-wide. There's no way to split delete permission by bucket on this platform.

**Redesign**: rather than granting delete back to the sync-side credential (which would've undone the whole
point, since S4 can't scope it away from the versions bucket), moved the *entire* sync+versioning operation
for Nextcloud and Immich onto the Infrastructure VM — the same host that already holds `s4-prune`. The
Storage VM (and Nextcloud's own VM) now hold **zero** Mega S4 credentials for these two backups. Source data
is read via new dedicated, read-only SSHFS mounts (`/mnt/nextcloud-source`, `/mnt/immich-source`, a new
`nc_immich_source_ed25519` key authorized read-only against the Storage VM — confirmed live: a `touch` on
the mount returns "Read-only file system"). `s4-prune` was broadened to `S3FullAccess` (list+read+write+delete
all needed for a working `sync --backup-dir`; same "already isolated to one host, broader grant isn't
meaningfully riskier" reasoning as before) and now does the real work: `nextcloud-backup.sh`/`immich-backup.sh`
moved to `/root/scripts/` on Infrastructure, cron moved there too, old copies on the Storage VM renamed
`.retired-2026-08-16-moved-to-infra` rather than deleted.

**Why this still achieves the original goal**: the security property was never "the sync host can't delete
things" for its own sake — it's "a compromised Storage VM/Nextcloud can't destroy the version history that's
the recovery path." That still holds: those hosts have no S4 credential at all now, so a compromise there can
feed bad (e.g. ransomware-encrypted) data through the read-only mount, but can only cause Infrastructure to
apply normal sync logic to it — which *preserves* the last-known-good version in the versions bucket before
any bad overwrite, exactly as intended. Media and
VM backups haven't hit this failure mode yet (no replace-scenario during
testing) but carry the same latent risk on the scoped `s4-sync` key — flagged as a follow-up, not yet
migrated to the same Infrastructure-side pattern.

## Mistake made along the way — two credentials were briefly exposed in plaintext

While copying the Nextcloud credential to Infrastructure, a cleanup/verification command
(`sudo cat rclone.conf.tmp`, meant to check for a stray leftover file) accidentally printed the **full
`rclone.conf` contents**, including both the original `media-s4` and `nextcloud-s4` access keys and secrets,
into a tool result during this session. Caught immediately, the malformed config was rebuilt cleanly without
re-displaying secrets, but the two keys had already appeared in plaintext once.

The exposure was contained to this session's tooling rather than transmitted anywhere external, but per this
repo's own secret-handling standard it was flagged rather than quietly absorbed. **Resolved same-day**:
Purgos revoked all three original credentials (`media-s4`, `nextcloud-s4`, `immich-s4`) via Mega's S4
console — not just the two that were exposed, all three, since they'd all been carrying full delete access
regardless — and a single new dedicated prune-only key was created to replace them.

**One gotcha hit creating the replacement**: the first attempt at the new key had `S3DeleteAccess` attached
but delete calls still came back `403 AccessDenied: Request not allowed by policy` — the same denial message
a key with *no* delete permission gives, suggesting either the policy hadn't actually attached, or Mega S4's
`s3:Delete*` wildcard doesn't reliably match `s3:DeleteObject` the way AWS's does. A second key created with
broader permissions worked immediately. Given this key already lives on an isolated, single-purpose host
(Infrastructure) running only the prune scripts, the extra permission surface from a broader grant isn't a
meaningful added risk here — not worth fighting Mega S4's policy-wildcard quirks for a marginal tightening.

## Result

Two different final shapes, depending on what each backup's sync actually needs:

- **VM backups** (`rclone copy`, additive-only by design already): Storage VM's equivalent, `s4-sync`, holds
  read/write only and that's genuinely sufficient — `copy` never needs to delete anything to overwrite a
  changed file's content in place, so this one never hit the `--backup-dir` problem.
- **Nextcloud, Immich** (`rclone sync --backup-dir`, which does need delete to complete a move): the entire
  sync now runs from Infrastructure using `s4-prune`, reading source data over a dedicated read-only mount.
  The Storage VM holds zero credentials for these two.
- **Media** got the same Infrastructure-side migration as Nextcloud/Immich on 2026-08-19, proactively —
  never actually broke (no replace-scenario had occurred during testing) but carried the identical latent
  gap. `media-backup.sh` and the Arr-container-pause control key both moved from the Storage VM to
  Infrastructure, reading source data via a new `/mnt/media-source` read-only mount. Verified live:
  Wednesday's real sync (Music, which only had a stale 6GB partial copy from before the throttled redesign)
  completed the full 148GB backfill cleanly in ~3 minutes, zero errors.

Either way, the credential capable of deleting anything lives on a host the actual data source never
touches. This doesn't make the setup ransomware-*proof* in an absolute sense (Infrastructure itself is still
a reachable host, and Mega S4's lack of Object Lock means there's no true immutability floor under any of
this) — but a compromise of any data-source host can no longer directly delete the version history that's
supposed to be the recovery path.

## Status

**Fully closed 2026-08-19.** All four offsite backups now have the correct shape for what they actually need:
Nextcloud/Immich/media sync from Infrastructure (verified working, zero permission errors across real runs);
VM backups stay on their source host (`dyonisis`) since `copy`-only never needed delete in the first place.
No open items remain from this investigation.

**2026-09-18 update**: the media leg of this design (sync, both remote buckets, the read-only source mount,
and the `media_source_ed25519`/`arr_control_ed25519` keys this whole scoped-credential effort was built
around) was retired outright after the Mega account filled up — see
`Scripts/README.md`. The scoped-credential
pattern itself remains in place and unaffected for Nextcloud, Immich, and VM backups.
