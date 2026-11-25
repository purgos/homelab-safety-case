# 2026-10-10: SSH certificates for the homelab (step-ca + Authentik)

**Why.** Every host trusted a handful of long-lived admin keys in `authorized_keys`, every client kept a `known_hosts`
that broke with "host key changed" whenever a VM was rebuilt (tomo's upcoming reinstall would have hit that across
the whole fleet), and nothing in an auth log said *who* logged in. The goal: log in with your Authentik account, get a
short-lived SSH certificate, have hosts prove themselves with CA-signed host certs, and renew all of it automatically.
Runbook: `Networking/ssh-ca/README.md`.

**Design decisions.**
- **Two CAs, two VMs.** `ssh-ca` (VM 116) for home and `community-ca` (VM 117) for the `example.org` cloud. They share no
  keys, so the home side can never mint cloud access, and cloud admin still goes only through Community-Jump (key + TOTP).
  The community CA got its own VM rather than living on the jump box. Later co-admins will have shells there, and a local
  root exploit on the jump box shouldn't hand over the CA keys.
- **User certs: 7 days, principals = Authentik `ssh-*` groups.** A step-ca SSH template reads the ID token's `groups`
  claim and keeps only names starting with `ssh-`. The email-derived default principals are dropped, so a cert can only
  ever log in where a host's `AuthorizedPrincipalsFile` lists that group. The Key ID is the email, which shows up in every
  auth log line.
- **Host certs are pushed, not pulled.** The obvious design (hosts renew themselves via step-ca's SSHPOP) needs every
  host to reach the CA. With the new VLANs, 14/15 can't reach VLAN 10, and the cloud hosts shouldn't connect inward to
  the jump box either. So the CA side signs each host's **pinned** host key and delivers the cert with a forced-command
  key that can only run `install-host-cert`. That script accepts nothing but a host cert from the right CA for that
  host's own key. The pinned key doubles as the pusher's `known_hosts`, so a host whose key changes is never re-signed:
  it fails loudly instead.

**Build.**
1. Two VMs from the Ubuntu 26.04 cloud image (Purgos-Door recipe) on `local-lvm` so snapshots work, then
   `harden-vm.sh`, scoped `ufw` (`ssh-ca` 443 from the LAN, `community-ca` 443 from Community-Jump only), snapshot.
2. Authentik app per CA via `ak shell` (`Scripts/authentik-ssh-ca.py`). The client secret goes container → shell
   variable → CA VM file without being printed.
3. `Scripts/setup-step-ca.sh`: `step ca init --ssh`, OIDC + JWK provisioners, the group template, a hardened systemd unit.
   Pi-hole record `ca.home.example.org`.
4. `Scripts/rollout-ssh-ca.sh` per host: CA pubs, principals, empty RevokedKeys, the push key, pin + first push, then the
   sshd drop-in. Gates: `sshd -t`, a fresh normal login, and a login that trusts *only* the CA line. **15 VLAN 10 hosts
   enrolled** (metrics as the pilot, then dyonisis, both Pi-holes, infra, storage, database, authentik, purgos-infra, both
   exit nodes, subnet-router, local-misc, downloads, arr-stack).
5. Old admin keys removed per host, each with a 3-minute auto-restore timer that was cancelled only after a fresh cert
   login worked. Kept: dyonisis's `proxmox` break-glass key, all machine keys (SSHFS, pgpool, rrsync backup pull), and
   tomo's media-mount key on Storage, now `restrict,from=tomo,command="internal-sftp"`.
6. Monitoring: push metrics + 3 Prometheus alerts, an Uptime Kuma check on `/health`.

**Troubleshooting along the way.**
- **Cloud image wouldn't import by storage name** (`local:iso/...img has wrong type 'iso'`). Use the absolute path in
  `import-from=`.
- **First boot never got its static IP.** cloud-init's `init-local` didn't run until ~400 s, failed to rename `ens18`
  → `eth0` ("busy"), and left the VM on a DHCP lease with no sshd. ACPI shutdown also timed out (no guest agent yet).
  A `qm reset` fixed it: the second boot applied the network config in seconds.
- **`harden-vm.sh` aborted at apt** on one VM because cloud-init still held the apt lock. Wait for
  `cloud-init status --wait`, then re-run.
- **Pi-hole `dns.hosts` output isn't JSON** (`[ a, b ]`). Parse it, then set a JSON array, and keep both Pi-holes
  byte-identical.
- **Asking for exactly `--not-after 168h` was rejected** ("168h1m21s is greater than … 168h1m0s"): step backdates
  certs by a minute. Just omit it; the provisioner default is 7 days.
- **`IdentitiesOnly yes` hides the agent cert.** tomo's per-group `IdentityFile` blocks would have kept offering only the
  old keys. An `IdentitiesOnly no` block at the top of `~/.ssh/config` for enrolled hosts fixes it (first match wins).
- **dyonisis's `authorized_keys` is a symlink into `/etc/pve/priv`.** Edit through it (write the resolved path), don't
  `sed -i` it into a plain file.
- **Prometheus `/-/reload` returns 403 here** (lifecycle API off). Restart the container to pick up rule changes.
- **Kuma has no monitor API.** Cloned an existing monitor's row (+ notifications) in `kuma.db` with Kuma stopped.
  `pragma_table_info()` isn't available in that sqlite, so use `PRAGMA table_info(monitor)`.

**Omada + VLAN 14/15 (same day).** Through the Omada UI in Chrome: `ssh-ca` added to the `admin-hosts` IP group
(Omada's numeric octet boxes auto-advance on the MAC field but not the IP field, so click each one) and DHCP reservations for
`.236`/`.237` (Community-Jump's `.110` was already reserved). Then hunter, crafty, public-misc, plex, media, openparty and blog
were enrolled and their old keys removed: **22 hosts on certificates**.

**Desktops.** tomo, miku and sakura were enrolled as `purgos` (principal `ssh-admin`) under a temporary passwordless-sudo grant
(the rollout's `sudo -n` can't prompt), removed right after. Their personal keys stay until the other devices have certs.

**example.org.** Same build on `community-ca`, with the Authentik app on cloud-auth and push renewal running on Community-Jump. All 6 cloud hosts are
enrolled (`rollout-ssh-ca-community.sh`, every step via the jump box). Purgos then traded Community-Jump's per-connection **TOTP** for
**16-hour** cloud certs: the MFA moved to one Authentik login a day.

**Break-glass.** One 5-year cert per CA, signed directly with the CA key in `/dev/shm` (the provisioners stop at a year).
Isolation checked both ways.

**Still open.** Enroll the desktops (needs sudo). Initialise and roll out the example.org CA. Make the 1-year
break-glass cert and store the CA passwords in the password manager.
