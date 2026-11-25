---
date: 2026-08-15
resolved: 
severity: degraded
kind: incident
hosts: []
backfilled: true
---

# Storage array has pre-existing silent corruption — found via the media backup, confirmed via scrub

## What broke

While the staggered media backup was doing its first full pass through `TV`,
`rclone` repeatedly failed on one file:

```
2026/08/09 23:24:53 ERROR : Black Mirror/Black Mirror - S03E06 - Hated in the Nation WEBDL-1080p.mkv:
Failed to copy: multi-thread copy: failed to write chunk: read
/mnt/storage/TV/Black Mirror/Black Mirror - S03E06 - Hated in the Nation WEBDL-1080p.mkv: input/output error
```

A single failed read could plausibly be a fluke, but it turned out to be reproducible — the same file
failed identically on 2026-08-09, and again on 2026-08-14 across all 3 of `rclone`'s automatic retry
attempts, before the sync gave up on that one file and completed everything else in `TV` successfully
(`rclone`'s `--backup-dir` safety net correctly refused to delete/prune anything on the remote given the
error, so nothing was lost on the Mega S4 side either).

## Root cause

`btrfs device stats /mnt/storage` on first investigation showed:

```
[/dev/sdb1].write_io_errs    0
[/dev/sdb1].read_io_errs     0
[/dev/sdb1].flush_io_errs    0
[/dev/sdb1].corruption_errs  64756487
[/dev/sdb1].generation_errs  0
```

**~64.75 million accumulated checksum-verification failures**, with zero read/write/flush I/O errors. That
combination matters: the physical read requests are succeeding (the JMicron RAID5 controller is returning
data without complaint), but the data that comes back doesn't match its own btrfs checksum. That's silent
corruption, not a drive refusing to respond — consistent with either a degraded member disk the hardware
controller isn't surfacing as failed, or a controller-level fault, but there's no way to tell which from the
OS side: the array is presented as a single block device (`/dev/sdb`), `smartctl` isn't installed and
wouldn't see the individual physical disks behind the hardware RAID anyway.

**This filesystem had never had a scrub run** (`btrfs scrub status` returned "no stats available" before
this incident) — so nothing had ever actually verified data integrity across the array. The corruption
count is very likely mostly pre-existing, silently accumulated over however long this array has been in
service, only surfacing now because the backup's `--fast-list` full-tree read was the first thing to
actually touch large stretches of cold data in a long time. Supporting evidence: the counter barely moved
during the entire TV backfill (+146, from 64,756,487 to 64,756,633) despite that backfill reading ~3TiB —
if fresh corruption were being introduced by current I/O, the count would track backup activity far more
closely than it does.

## What's been done

1. Confirmed the corruption is reproducible, not transient — same file, same offset region, failed
   identically across 4 separate attempts spanning 5 days.
2. Launched `btrfs scrub start /mnt/storage` (2026-08-11 23:12) to get a real, filesystem-wide account of
   scope rather than guessing from one file. Ran deliberately alongside the ongoing TV backup rather than
   waiting for it to finish — verified via a live read test through Plex's SSHFS
   mount that the combined load didn't repeat the
   original saturation incident.
3. Scrub ran for ~150.5 hours total (2026-08-11 23:12 → 2026-08-18, sharing I/O with the ongoing media
   backfill/backups the whole time) and **finished with a final, stable result**:

   ```
   Error summary:    csum=30
     Corrected:      0
     Uncorrectable:  30
     Unverified:     0
   ```

   **30 uncorrectable checksum errors total across the entire 5.98TiB scrubbed** — `Corrected: 0` is expected
   given the data profile is `single` on top of hardware RAID5 (no btrfs-level mirror to self-heal from, even
   though scrub can detect the mismatch). Throughout the entire investigation, every `dmesg` corruption
   message that included an inode number pointed at the same one (`1112`, the Black Mirror file) — consistent
   with the damage being contained to that single file's region rather than scattered across the array.
   `btrfs device stats` settled at `corruption_errs = 64,756,882`, essentially unchanged from the pre-scrub
   baseline (64,756,487) — confirming this was overwhelmingly pre-existing, silently-accumulated corruption
   that scrub was the first thing to actually verify against, not damage introduced by this session's own
   heavy I/O.

## Status

**Fully closed 2026-08-19.** Scope confirmed narrow: one corrupted file (`Black Mirror - S03E06 - Hated in the
Nation`), not a wider array problem. Both follow-ups actioned:

- **Re-acquired via Sonarr (2026-08-19)** — deleted the corrupted episode file record (confirmed removed from
  disk), triggered `EpisodeSearch`, Sonarr found and grabbed a new release within 9 seconds.
- **Monthly scrub scheduled (2026-08-19)** — `/root/scripts/monthly-scrub.sh` on the
  Storage VM, 1st of the month at 2am, `flock`-guarded. See
  `VMs/Storage/README.md`'s Scrub entry.
