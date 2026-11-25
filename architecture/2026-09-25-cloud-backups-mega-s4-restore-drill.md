# Cloud backups to Mega S4, and a restore drill that actually opened the files

Date: 2026-09-25

## What was planned

The outside security review's firmest point: "keep a protected backup that a compromised live account cannot erase,
then actually restore it to a temporary system." The example.org cloud stack had **no backups at all**, and Nextcloud's
master-key encryption meant that losing `config.php` would turn the S3 bucket into unreadable ciphertext. Plan:
`Planning/Strategies/security-review-2026-09.md`, Phase 1.

## How it went

- **Pull model, reusing the home pattern** (`vps-backup.sh`): the jump box pulls a `tar | zstd` stream from each AWS box
  through a forced-command key (`Scripts/cloud-backup-tar.sh`), encrypts it with rclone crypt, and pushes it to Mega S4.
  The Nextcloud S3 bucket is copied with a new **read-only** AWS IAM user.
- **Designing around Mega S4's limits.** The first draft proposed custom bucket policies, which Purgos rightly pointed
  out don't exist in the Mega console. Mega S4 offers only fixed, account-wide permission levels, with no versioning,
  object lock or lifecycle. So protection comes from *who holds which key*: the jump box's key is **IAM none, bucket
  List+Read, object List+Read+Write, with no Delete**, and 30-day retention runs on the Infrastructure VM with its existing
  delete-capable key. A guard means a host whose newest backup is older than 3 days is never pruned.
- **Secrets never in the repo.** The crypt passphrase was generated on the jump box and copied by Purgos straight into
  his password manager. The Mega key was rotated after it had passed through chat, and the old key was confirmed
  `InvalidAccessKeyId`. The rotation key file had landed inside the repo folder (not gitignored), so it was used and
  shredded immediately.
- **Monitoring**: Prometheus textfile metrics per target, and an Uptime Kuma push monitor that only turns green when every
  target succeeded (25 h window).

## The restore drill

A throwaway LXC on dyonisis, fed **only from Mega**: Postgres from the `pg_dumpall`, Nextcloud 35.0.0 with the backed-up
`config/`, and the S3 objects served locally by `rclone serve s3`. Four real encrypted files (PDF, JPEG, MP4, Markdown)
came back through `occ files:get` with sizes **exactly** matching Nextcloud's recorded plaintext sizes. Headscale's DB
matched production node-for-node; Authentik's users and superuser matched too. The container was then destroyed.

## Troubleshooting along the way

- **Bucket not there**: the backup key (correctly) can't create buckets, so the first permission test's "delete worked"
  was a false alarm on a 404. It was retested after Purgos created the bucket: `AccessDenied`, as intended.
- **Metrics not scraped**: the `.prom` file sat in the `cloud-backup` home (mode 750), which node_exporter couldn't read.
  It moved to its own 755 directory.
- **Drill gotchas, now baked into `Scripts/cloud-restore-drill.sh`**: the `en_US.UTF-8` locale must exist before loading
  the dump; the tarballs store absolute paths; **disabling `user_oidc` makes SSO users' files "not found"**; MinIO no
  longer ships free binaries (use `rclone serve s3` from a current rclone); and there's no `sudo` in a bare Debian LXC.

## Outcome

Nightly encrypted backups of all three AWS boxes plus the Nextcloud bucket are live (02:30), and **the restore is proven**.
Both halves of the friend's readiness gate now have evidence: the reachability tests (tailnet lockdown) and a real restore.
