# Hardening a VM: procedure

Step-by-step runbook for taking a VM from default/`purgos`-login to root-only key auth + `ufw` +
`ufw-docker`. Written up 2026-08-05 after doing this across the whole fleet in one pass — the phase
order below (especially "investigate before touching anything" and the verification gates) exists
because skipping steps caused four separate incidents that day: a brief DNS outage on `dns-1`, a
near-total loss of the shared Postgres database on `database`, two broken homepage/NPM widgets on
`infra`, and a full data loss of Forgejo's repos on `local-misc` when `--remove-user=purgos` deleted
`/home/purgos/forgejo/data` (Phase 1's bind-mount check exists specifically to catch this and wasn't
actually run against every container on that host). Each is referenced inline below; see
`Troubleshooting/` for the full writeups.

`harden-vm.sh` (same directory) automates the mechanical parts of phases 2-5, plus running
`setup-unattended-upgrades.sh` (daily apt upgrade + autoremove, 04:00 auto-reboot — see
`scripts/README.md`) so a newly-hardened host doesn't need a separate pass for that. It does **not**
automate phase 1 (investigation) or phase 6 (old-account removal) — those require judgment calls this
script can't safely make for you. Read this whole doc before running it on a new host.

## Phase 0: Safety net

**Take a Proxmox snapshot of the VM before starting**, no exceptions, even for a "simple" host. The
`database` incident happened on a VM that presumably had no fresh snapshot immediately before the
attempt — the recovery involved restoring from day-old SQL dumps instead of an instant snapshot
rollback. A snapshot costs a couple of minutes and turns any mistake in the phases below into a
30-second rollback instead of a multi-hour incident.

**Gotcha found 2026-09-18**: `qm snapshot` fails outright ("snapshot feature is not available") for any
VM whose disk lives on `local-large` — that storage is plain LVM, not thin-provisioned, and Proxmox's
snapshot feature needs `lvmthin`/`qcow2`/ZFS underneath. (`Metrics`, VMID 106, and `DC-Exit-Node`, VMID
108, are both on `local-large` — check `qm config <vmid>` for the `scsi0`/storage before assuming a
snapshot will work.) Fall back to a full `vzdump --mode stop` backup (to `local-backup`) instead — briefly
stops the VM, but for a fresh/low-stakes host that's a fine trade for a real restore point instead of
skipping Phase 0 entirely.

## Phase 1: Investigate before touching anything

Do all of this **before** running any command that changes state. The goal is to know, in advance,
exactly what will break if you naively (a) enable `ufw` with only SSH allowed, or (b) delete the old
login account.

1. **What's actually listening?**
   ```sh
   sudo ss -tulnp | grep -vE '127\.0\.0\.1|::1]|systemd-resolve|systemd-network'
   ```
   Note every port bound by something that isn't Docker (bare-metal services — Pi-hole, Apache,
   Plex, a Node app, etc.). `ufw allow OpenSSH` alone is only safe on hosts where **every** real
   service is Docker-published and `ufw-docker` will govern it. Missing this step is what broke
   `dns-1`'s DNS for a few minutes — Pi-hole runs bare-metal there, and enabling `ufw default deny
   incoming` with only SSH allowed took out 53/80/443 immediately. Every bare-metal port needs its own
   `ufw allow <port>` **before** `ufw --force enable`, not as a follow-up fix.

2. **Does this host run Docker with the userland-proxy?**
   ```sh
   sudo ss -tulnp | grep docker-proxy
   ```
   If published container ports show up bound via `docker-proxy` (not just DNAT), `ufw-docker`'s
   FORWARD-chain rules alone aren't sufficient — those ports are real INPUT-chain listeners too and
   need an explicit `ufw allow <port>` in addition to `ufw-docker allow <container>`. This is what
   made `database` different from every other Docker host in the fleet (`mariadb`/`postgres`/
   `portainer_agent` needed explicit port allows; `infra`/`friendica`/etc. didn't).

3. **What does the account-to-be-removed actually own?** For the account you intend to delete
   (`purgos` in this fleet, but generalize):
   - `sudo crontab -u <user> -l` — any real entries?
   - `pgrep -u <user> -a` — any live processes? (Watch out for containerized processes that
     coincidentally share the same UID via `PUID=1000`-style images — check `docker ps` first and
     cross-reference before assuming a `pgrep` hit is a real bare-metal dependency.)
   - `sudo systemctl cat <service>` for anything suspected of running as that user — check the
     resolved `User=`/`WorkingDirectory=`, not just `grep` the unit file (symlinks and drop-ins can
     make a raw `grep` on the wrong path give a false negative).
   - `sudo docker inspect $(sudo docker ps -q) | grep '"Source"'` — does **any** container bind-mount
     its data from under `/home/<user>/`? This is exactly what made `database` a special case: the
     `postgres` container's data directory was `/home/purgos/postgres/data`, so `userdel -r` would
     have deleted the live database. Check this even on hosts that look like simple app servers — this
     is the exact check that got skipped on `local-misc`, where `forgejo`'s data directory
     (`/home/purgos/forgejo/data`) was deleted along with the account, losing all repo data (see
     `Troubleshooting/forgejo-data-loss-userdel-hardening.md`).
     `local-misc` runs several containers (`forgejo`, `tautulli`, `radicale`, …) — check **every one**,
     not just the ones that look database-shaped.
   - Do **other** hosts authenticate to this one as that user (SSHFS/NFS mounts, `Networking/mounts-fstab/README.md`)? And
     if so, does the exported *path* itself live under `/home/<user>/` (not just the auth identity)?
     `storage`'s case (`/mnt/storage`, outside home) was safe to migrate quickly; `downloads`' case
     (`/home/purgos/Downloads` was the literal mount source) would have needed a real data migration.

4. **Same-bridge hairpin check, if this host runs Docker.** For any container that calls back into a
   *sibling* container on the same host (a reverse-proxy admin panel proxying to itself, a dashboard
   querying a local Docker-socket proxy, etc.), check whether that call goes out via the host's own
   external IP instead of `127.0.0.1` or the container's name over Docker's built-in DNS. That pattern
   works fine without `ufw-docker`, but breaks — specifically when both containers share the *same*
   user-defined bridge network — once `ufw-docker` is installed (cross-bridge hairpin keeps working;
   same-bridge doesn't). This bit both NPM's self-referential admin-UI proxy and homepage's
   `dockerproxy` connection on `infra`. Grep proxy configs / container env vars for the host's own IP
   and check each hit:
   ```sh
   sudo docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep <host-ip>
   ```
   Fix found instances by switching to the container name (same network) or `127.0.0.1` (self), not by
   trying to patch the firewall rule — it's a NAT/bridge interaction, not a missing `ufw allow`.

## Phase 1.5: `apt update && apt upgrade`

Patch the host before touching SSH/firewall config, so it isn't sitting exposed with stale packages
mid-hardening:

```sh
sudo apt-get update && sudo apt-get -y upgrade
```

Non-interactive (`DEBIAN_FRONTEND=noninteractive`) in `harden-vm.sh` so it can't hang on a debconf
prompt. A kernel upgrade here won't take effect until a reboot — that's fine, `setup-unattended-upgrades.sh`
(Phase 4.5) takes over day-to-day patching including the 04:00 auto-reboot from here on.

## Phase 2: Root SSH key

Identify the correct public key for this host's Termius/admin key group (match the private key file
you'd use to connect, e.g. `ssh-keygen -y -f ~/.ssh/<group>`), then:

```sh
sudo install -d -m700 -o root -g root /root/.ssh
echo '<pubkey>' | sudo tee /root/.ssh/authorized_keys >/dev/null
sudo chmod 600 /root/.ssh/authorized_keys
```

**Alternative source: import from GitHub.** If the admin keys are attached to a GitHub account,
`https://github.com/<username>.keys` serves every public key on that account (plaintext, no auth
needed — it's meant for this). That's what `harden-vm.sh`'s `--github-user=<name>` flag pulls from
instead of deriving one key from `<local-identity-file>` — useful for installing keys for multiple
admin devices in one pass instead of one at a time. The identity file passed to the script is still
required for the verification step below, so it must be one of the keys GitHub is serving.
```sh
curl -fsSL https://github.com/<username>.keys | sudo tee /root/.ssh/authorized_keys >/dev/null
```

**Verify root login works over a fresh connection before doing anything else**:
```sh
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i <identity-file> root@<host-ip> true
```
If this fails, stop — do not proceed to sshd hardening.

## Phase 3: `ufw` base rules

Using what you found in Phase 1:

```sh
sudo ufw allow OpenSSH
# one of these per bare-metal port found in Phase 1, e.g.:
sudo ufw allow 80/tcp
# if the host has a tailscale0 interface:
sudo ufw allow in on tailscale0
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
```
Add every bare-metal allow **before** `--force enable`. Safe to re-run — `ufw` skips duplicate rules.

## Phase 4: `ufw-docker` (skip if no Docker)

```sh
bash scripts/setup-ufw-docker.sh   # run locally on the host, or via remote-setup-ufw-docker.sh
```
Then, for every container with a published port:
```sh
for c in $(sudo docker ps --format '{{.Names}}'); do
  [ -n "$(sudo docker port "$c" 2>/dev/null)" ] && sudo /usr/local/bin/ufw-docker allow "$c"
done
```
If Phase 1 found `docker-proxy`-bound ports, also add explicit `ufw allow <port>` for those specific
ports — `ufw-docker allow` alone won't cover them.

*(Note: piping `setup-ufw-docker.sh` through `ssh host 'bash -s' < file` can intermittently fail with
`curl: (23) client returned ERROR on write` — something about that stdin channel conflicts with
curl's own handling. Running the same commands via a direct `ssh host '...'` invocation instead is
reliable; `remote-setup-ufw-docker.sh` had that failure mode, `harden-vm.sh` avoids it.)*

## Phase 4.5: unattended-upgrades

```sh
sudo bash scripts/setup-unattended-upgrades.sh   # run locally on the host
```
Idempotent, unrelated to the SSH/ufw work above — configures daily apt upgrade + autoremove with a
04:00 auto-reboot if needed. Bundled into `harden-vm.sh` here (rather than as a separate pass) since a
host being freshly hardened is also, in practice, always a host that needs this. See
`scripts/README.md` for what it actually configures.

## Phase 5: sshd hardening

```sh
# PermitRootLogin, PasswordAuthentication, KbdInteractiveAuthentication -> prohibit-password/no/no
# in /etc/ssh/sshd_config, AND in any /etc/ssh/sshd_config.d/*.conf override (cloud-init's
# 50-cloud-init.conf commonly re-sets PasswordAuthentication and will win if not also patched)
sudo systemctl restart ssh
```
**Verify root login again, over a fresh connection, after the restart.** This is the last point where
a mistake is still trivially recoverable via the account you're about to remove — don't skip it.

## Phase 6: old-account removal — decision, not automation

Only proceed if Phase 1 found nothing that depends on the account or its home directory. Otherwise:

- **Nothing depends on it** → `pkill -u <user>; userdel -r <user>`. Verify with `id <user>` (should
  fail) and re-run your smoke tests.
- **Something depends on it, but the dependency doesn't live under `/home/<user>/`** (e.g. `storage`'s
  case — SSHFS auth as that user, but the served path was `/mnt/storage`) → migrate the *auth*
  (add the consuming hosts' keys to root's `authorized_keys`, repoint `Networking/mounts-fstab/README.md` + each
  consumer's `/etc/fstab` from `<user>@` to `root@`, remount, verify), then remove the account.
  Watch for orphaned `mount.fuse.sshfs` client processes on the consumer side that survive a plain
  `umount` and keep reconnecting as the old user in the background (`ps aux | grep sshfs` on the
  consumer) — kill them explicitly or `userdel` will refuse with "user ... currently used by process".
- **The dependency's data lives under `/home/<user>/`** (`database`'s Postgres bind-mount,
  `downloads`' qBittorrent/SABnzbd data+config) → this is real migration work, not a quick fix. Plan
  it as its own task: move the data (check `df` first — if `/home` and the target are the same
  filesystem, it's an instant `mv`, not a slow cross-filesystem copy), fix any place that stored an
  *absolute path* pointing at the old location (e.g. qBittorrent's per-torrent `.fastresume` resume
  data — a raw `mv` without a compatibility symlink at the old path makes every existing torrent show
  as "missing"), repoint configs/fstab, verify, only then remove the account. Don't bundle this into
  the same session as the rest of the hardening pass unless you're prepared for the extra time and
  risk — it's fine to leave the account in place and document why, same as `database`/`downloads` were
  left partially hardened here.

## Phase 6.5: enroll in the SSH CA (since 2026-10-10)

Right after hardening, run `bash Scripts/rollout-ssh-ca.sh home <alias>` from tomo so the host trusts the home
SSH CA and gets a push-renewed host cert, then add it to `Scripts/ssh-ca-hosts.txt` and to the `IdentitiesOnly no`
block at the top of tomo's `~/.ssh/config`. Once cert login is verified, remove the bootstrap admin key from root's
`authorized_keys`. See `Networking/ssh-ca/README.md`.

## Phase 7: cleanup + docs

- Remove any temporary passwordless-sudo grant (`teardown-passwordless-sudo.sh`, or `rm -f
  /etc/sudoers.d/<user>-nopasswd` directly if the account is already gone).
- Update `~/.ssh/config`: flip the host's `User` to `root`, add a one-line comment with the hardening
  date and, if the account was kept, exactly why.
- Update `scripts/README.md`'s rollout status and this repo's relevant `VMs/<name>/README.md`/`Docker/<name>/README.md`
  if a partial-hardening exception applies there (see `Docker/shared/database/README.md`'s Open Items for
  the pattern).

## Phase 8: post-hardening verification

- Smoke-test every service on the host (`curl -o /dev/null -w '%{http_code}\n' <url>` for each), not
  just the one you were most worried about.
- If the host runs Docker, re-check the same-bridge hairpin pattern from Phase 1 item 4 even if it
  looked clean beforehand — a container recreate between your check and now could have changed which
  network something is on.
- If anything depends on this host from elsewhere in the fleet (a homepage widget, an NPM proxy, an
  SSHFS mount), check that too, not just things running on the host itself.

## Other recommendations (not yet applied fleet-wide, worth considering)

- **Restrict SSH to LAN/Tailscale only** where a host doesn't need WAN-reachable SSH — currently every
  hardened host allows `OpenSSH` from `Anywhere`. Given key-only auth is already in place the risk is
  low, but `ufw allow in on tailscale0` + a LAN-subnet-scoped SSH rule instead of "Anywhere" would
  shrink the exposed surface further. Not done here to avoid changing remote-access behavior mid-pass.
- **fail2ban** (or equivalent) for SSH — lower priority given key-only auth already blocks
  password-guessing outright, but still cuts log noise and adds a layer against key-enumeration-style
  probing.
- **Periodic re-audit**: nothing currently checks that a host hasn't drifted back to password auth or
  had a `purgos`-equivalent account resurrected (e.g. by a base-image update). A simple periodic script
  re-running Phase 1's checks fleet-wide would catch that early — not built yet.
- **Keep docs in sync in real time, not after the fact.** The `database` incident was compounded by
  `Docker/shared/database/README.md` claiming the hardening was done and `purgos` removed when neither was
  true — written prematurely, before verifying, and not caught until this exact procedure surfaced it.
  Update the doc as the *last step of the phase it describes*, not as a batch at the end.
