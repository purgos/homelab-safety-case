# 2026-10-22: Proxmox Backup Server on dyonisis

**Why.** A Mega size check for the member-backups plan found that 7.38 of the
account's 7.52 TiB was one bucket, `vm-backups`: ~700 GiB of compressed `vzdump` images every night, ~11 nights kept.
Compressed vzdump output can't be deduped, so every night re-uploads everything and the push to Mega runs 5-8 h. PBS
stores each unique chunk once and uses QEMU dirty bitmaps, so a nightly backup only reads changed blocks. Plan:
`Near-Term/proxmox-backup-server.md`. Reference doc: `VMs/pbs/`.

**Design decisions.**
- **LXC, not a VM, and no wipe.** The 8 TB backup HDD already holds the old dumps and is the Mega push's source.
  Passing the raw disk to a VM would have meant moving 1.5 TiB off first. Instead the datastore is a folder on the same
  ext4 filesystem, bind-mounted into an unprivileged CT (owner `100034:100034` = `backup` inside). Old and new run side
  by side until PBS has proven itself.
- **Client-side encryption from day one**, because the datastore is going offsite later.
- **The HDD is SMR** (ST8000DM004), so GC and verify (which touch every chunk) are scheduled in the afternoon.
- **Two jobs mirroring the old split.** `local-large` VMs stay capped at 100 MiB/s (the SPCC rule from 2026-10-16);
  `local-lvm` VMs run unthrottled because the cap counts sparse zeros too.

**Build.** CT 118 `pbs` from the Debian 13 template → PBS 4.2.8 from `pbs-no-subscription` → datastore `main`
(65,536 chunk dirs created in 4 s) → user + API token with `DatastoreBackup` → `pvesm add pbs pbs-main
--encryption-key autogen` → prune/GC/verify schedules → two vzdump jobs at 06:00/06:05.

**Results.**
- DNS-2's first backup: 21 min 51 s for a 128 GB disk that is 87% zeros (all of it read at the cap). Second backup:
  **3 seconds**, 164 MiB changed. That's the dirty bitmap.
- File-level restore of `/etc/pihole/pihole.toml` from the encrypted backup matched the live file's sha256.

**Troubleshooting along the way.**
- `proxmox-backup-manager user generate-token` has no `--output-format`; parsed the default JSON-ish output instead,
  keeping the secret inside the script.
- `Cannot find datastore 'main', check permissions`: a PBS API token only gets privileges its **user** also has.
  Adding the ACL for `pve@pbs` as well as `pve@pbs!dyonisis` fixed it (and the token had to be regenerated, since the
  first secret was never stored).
- The package added `pbs-enterprise.sources`; disabled it (no subscription).
- The CT defaulted to UTC, which would have shifted every PBS schedule by 4 h. Set `America/New_York`.
- **A full test restore onto `local-lvm` starved every VM on that SSD for ~25 minutes** (host I/O pressure 93%, normal
  ~1%). The cheap DRAM-less SSD absorbed the restore's 4.5 GB of buffered writes at 13-38 MB/s. Stopped it, let
  writeback drain, and proved the restore with file-level restore instead. Write-up:
  `Troubleshooting/pbs-restore-test-starved-local-lvm.md`.
- A `pkill -f` whose pattern also matched the SSH command running it killed its own shell. Kill by PID.

**Status.** Phase 1 (build + prove) done. Phase 2 (side by side) starts with tomorrow's 06:00 run, which is the full seed.
Still to do: offsite copy of the datastore and a Mega-only restore drill, then cutover and shrinking `vm-backups` on Mega.

**2026-10-23: first nightly run and the offsite copy.** The seed ran 06:00-~15:10 and left 639 GiB of chunks for all 29 VMs.
The SMR drive was 100% busy the whole time, which also slowed the old Mega push to 3-5 MiB/s (still running at 15:50).
Offsite copy: `pbs-offsite.sh` on dyonisis, daily 09:00, uploads to Mega S4 bucket `purgos-backup`. It uploads chunks first, then
only snapshots that were complete before the chunk pass began, so nothing on Mega points at a missing chunk. It is
additive-only with the delete-incapable key. One snag: my first `rclone mkdir` for a bucket named `pbs-main` seemed to hang.
I switched to `purgos-backup`, and both buckets turned out to exist. The empty `pbs-main` can't be removed with a key that
can't delete; it has to go in the Mega UI.

**Same day: generations instead of a pruner.** The first cleanup design reimplemented PBS garbage collection for Mega:
parse every backup's chunk list and delete chunks no kept backup uses. Reviewing it, that was the riskiest part of the
plan. One bug deletes chunks live backups need, and you only find out during a restore. The dyonisis key can also
write fake backups that a count-based pruner would keep instead of the real ones. The fix is to write each offsite copy
as a **generation**, a self-contained datastore copy in a dated folder, and delete whole old generations. Mega keeps 3
monthly generations, and `s4-pbs-gen-prune.py` on Metrics runs in dry-run mode for now. AWS will get quarterly
generations in Deep Archive with a 365-day Object Lock, expired by lifecycle, so no pruner there at all. The cost is
re-uploading ~650 GB per generation, plus ~1.5 TB more on Mega than a pruner would need.
Snag: the auto mode classifier blocked my attempt to delete the ~5 GB of stray pre-generation chunks with the prune
key, so they're left for a manual delete in the Mega UI.

**AWS tier, same evening.** Built with the local AWS CLI.
1. I proved the setup on a throwaway bucket with a 1-day compliance lock:
   - a test upload landed in `DEEP_ARCHIVE`, with the lock set;
   - a delete with the writer key returned `AccessDenied`;
   - deleting the locked version as admin failed with "object protected by object lock".
2. Then I created the real `purgos-backup-archive` (365-day lock, 400-day lifecycle expiry). The writer's access key
   was piped from `aws iam create-access-key` straight into dyonisis's rclone config, never printed.
3. `pbs-offsite.sh` now takes `mega` or `aws`. I swapped the file with `mv`, not by overwriting it, because bash reads
   a running script as it goes and the Mega seed was running it.
4. A dry run of the AWS mode, pointed at the test bucket, found 278,897 chunks (638.7 GiB) and the newest snapshot of
   each of the 29 VMs. Pointing it at the test bucket mattered: rclone's `rcat` ignores the dry-run flag, so the
   `.complete` marker was written for real.

**And then it changed again: Purgos's homelab is a member.** The long-term plan is multi-admin, multi-member community
backups:
- every homelab gets its own Mega S4 bucket with a 2 TB allowance;
- community's own backups live in S4 too;
- one archive job copies **all of S4 to Glacier** (365 days after deletion).

Under that plan, dyonisis uploading to Glacier on its own is a special case, so I removed it before its first run:
timer, units, bucket, IAM user, rclone remote. Its bucket had never received an object, so nothing was locked. The PBS
seed restarted into the new bucket `member-purgos`. The lesson: compliance-mode locks are permanent, so a "test it first"
bucket with a 1-day lock was the right call, and so was waiting to upload real data until the design settled.

**community VMs get their own datastore.** The four community-admin VMs (Community-Jump, Community-Ops, Community-Door, community-ca) now back
up to a second PBS datastore, `community`, with **its own encryption key**, and go offsite to community's own Mega bucket,
`community-vms`. A separate bucket alone wouldn't have worked: PBS shares chunks across every VM in a datastore, so there was
nothing separable to copy. The separate key matters more for multi-admin: community admins can restore community VMs without
holding the key to Purgos's homelab.

The build:
- **The bind mount needed a restart.** CT 118 had to reboot to pick up the second mount (`mp1`); there were no PBS tasks
  running.
- **PBS side:** the datastore, ACLs, prune, GC and verify jobs.
- **dyonisis side:** `pvesm add pbs pbs-community --encryption-key autogen`, reusing the existing token.
- **Jobs:** the four VMs came out of `pbs-main-lvm`/`pbs-main-large` and into a new `pbs-community` job at 06:10.
- **One snag:** the test backup of community-ca reported "existing bitmap was invalid". QEMU's dirty bitmap is tied to one
  PBS target, so a VM must stick to one datastore or every run becomes a full read.

**The Glacier tier, built the same night.** The new EC2 `community-archive` copies every Mega bucket into
`community-s4-archive` (Deep Archive, 365-day compliance lock). Details are in the `community-admin` repo
(`VMs/community-archive/`). Choices and snags:
- **No static AWS key.** The server uses an instance role that can upload and mark files deleted, but is explicitly
  denied deleting old versions or touching the lock.
- **The Mega key belongs to a read-only sub-user** (List + Read), because Mega puts permissions on users, not keys.
  Purgos added it on the host through stdin, never through chat. The first try saved a 1-character key ID, so the
  retry printed the pasted length.
- **No inbound ports.** It was bootstrapped over SSM, then joined Headscale and was enrolled in the community CA. SSM was
  then removed.
- **A reused tailnet IP.** It got `100.64.0.3`, community-infra's old address. Community-Jump's alias and pinned host key
  for that IP had to be replaced. The only other reference was an old promtail backup file on cloud-mc.
- **My hardening briefly locked out SSH.** `PermitRootLogin no` broke the community CA's forced-command cert push, and
  removing my CA lines before the rollout script wrote its own left no CA trust. I fixed it over SSM; the drop-in is
  now `forced-commands-only`.
- **The rollout script needed a missing file**, `Scripts/ssh-ca/install-host-cert`. I copied the byte-identical
  Homelab version into community-admin.
