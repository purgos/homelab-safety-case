---
date: 2026-08-05
resolved: 2026-08-05
severity: outage
kind: incident
hosts: []
backfilled: true
---

# Forgejo lost all repo data when `userdel -r purgos` ran during hardening

**Status**: closed (2026-08-05)

## What broke

Forgejo (`git.old.example.com`, Local-Misc VM, `10.10.33`) started returning `500 Internal Server Error`
on login. Logs showed:

```
[E] RegenerateSession: regenerate session: mkdir /data/gitea: no such file or directory
```

## Root cause

Forgejo's container bind-mounts its entire data directory from `~/forgejo/data` — i.e.
`/home/purgos/forgejo/data` — per `Docker/purgos/forgejo/docker-compose.yml`.
During the fleet-wide SSH/ufw hardening pass (see `scripts/README.md` and
`scripts/harden-vm.md`), `harden-vm.sh --remove-user=purgos` ran
`userdel -r purgos` on `local-misc` as the final step. `userdel -r` deletes the account's entire home
directory — which took Forgejo's live data (git objects, SSH host keys, session store, `app.ini`) with
it. `/home/` on the VM was left completely empty afterward.

`harden-vm.md`'s own Phase 1 checklist explicitly calls for checking "does any container bind-mount its
data from under `/home/<user>/`?" before removing an account — this is exactly the check that should
have caught it on `local-misc` and didn't. The Forgejo README had also already flagged (before this
incident) that there was no backup approach set up for `~/forgejo/data/` — so there was no copy to
restore from either. No Proxmox snapshot existed for this VM (Phase 0 of `harden-vm.md` calls for one
before touching any host; it was skipped here).

The Forgejo container itself kept running throughout (Docker doesn't care that its bind-mount source
vanished), so `docker ps` showed nothing wrong — only requests that touched `/data` (like creating a
login session) surfaced the failure.

## What was and wasn't lost

- **Lost**: all on-disk git data (bare repos, so full commit/object history as stored server-side),
  Forgejo's own config (`app.ini`, DB password location, secret keys), SSH host keys, session store.
- **Not lost**: the `forgejo` MariaDB database on the shared `Database` VM (`10.10.161`) — repo
  *records*, user accounts, registered SSH public keys, issues, permissions all survived, since that
  lives on a separate host untouched by this VM's account removal.
- Of the two repos with a `git.old.example.com` remote (`Homelab`, `Campaign`), only `Homelab` actually had
  a repository record in Forgejo's DB — `Campaign`'s local `git remote` had apparently been configured
  ahead of ever actually creating the repo on the server, so there was never server-side history to lose
  for it in the first place.
- Both `Homelab` and `Campaign` had full, intact git history on two independent local clones (`miku`,
  `tomo`), which is what made this recoverable at all — this repo (and its sibling private repos) has no
  other off-VM backup.

## Resolution

1. Confirmed no Proxmox snapshot existed for the VM (`qm listsnapshot 209` on `dyonisis` showed only
   `current`), ruling out a rollback.
2. Rebuilt the Forgejo stack at **`/root/forgejo/`** instead of a user home directory — same
   `docker-compose.yml` (image, env, ports) as before, `.env` DB password recovered from the
   still-running old container's own environment (`docker inspect forgejo`, before removing it), plus
   `FORGEJO__security__INSTALL_LOCK=true` added so the fresh `/data` reconnects straight to the existing
   database instead of presenting the first-run install wizard.
3. Fresh container start regenerated new SSH host keys (`/data/ssh/`) — anyone with `git.old.example.com`/
   `10.10.33:2222` in `known_hosts` needs `ssh-keygen -R "[10.10.33]:2222"` before their next
   clone/push/fetch, same as any legitimate host rebuild.
4. Confirmed the DB reconnected cleanly (`ORM engine initialization successful`, "Populating the repo
   stats indexer with existing repositories") — repo/user records were intact.
5. Generated a temporary admin API token via CLI (`forgejo admin user generate-access-token`, no
   password needed) instead of trying to recover/reset the admin password.
6. `Homelab`'s repo record pointed at a bare-repo path that no longer existed on disk (DB record
   orphaned from the deleted files) — deleted that stale record and recreated both `Homelab` and
   `Campaign` fresh via the API (`POST /api/v1/user/repos`, empty/private/`auto_init:false`), which
   properly initializes a receivable bare repo instead of leaving a broken DB↔disk mismatch.
7. `miku` and `tomo` had diverged (2 commits only on `miku`, 1 different commit only on `tomo`, no
   overlapping files) since neither had successfully pushed in a while — fetched `tomo`'s commit onto
   `miku` directly over SSH (`git fetch tomo:/home/purgos/Homelab main`) and cherry-picked it in, giving
   one combined linear history, then pushed both repos from `miku` to the freshly recreated Forgejo repos.
   Reset `tomo`'s local branch to match (`git reset --hard origin/main`) since its one unique commit was
   already represented upstream under a new hash post-cherry-pick.
8. Left the temporary admin API token in place — no CLI subcommand was found to revoke it; **needs
   manual revocation via Settings > Applications** in the Forgejo web UI once login is confirmed working.

## General rule

**Any `harden-vm.sh --remove-user=` run needs Phase 1's bind-mount check actually executed, not just
read** — `docker inspect $(docker ps -q) | grep '"Source"'` against every container on the host, cross-
referenced against the account being removed, every single time, regardless of how simple the host looks.
`local-misc` runs several containers (`forgejo`, `tautulli`, `radicale`, `grocy`) and looked like a
routine Docker host — the miss here is exactly the same class of mistake `database`'s partial-hardening
exception was written to prevent, just on a host that didn't get flagged in time.

**Service data directories should never live under a login account's home directory** for exactly this
reason — `/root/<service>` or `/data/<service>` (outside any account's home) is safe from `userdel -r`
regardless of which account gets removed later. Worth an audit pass across the rest of the fleet for any
other service still storing live data under `/home/purgos/`.

**Take the Phase 0 Proxmox snapshot, every time** — this incident would have been a 30-second rollback
instead of an hour of recovery work if `local-misc` had one.
