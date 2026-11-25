---
date: 2026-09-25
resolved: 2026-09-25
severity: degraded
kind: incident
hosts: []
backfilled: true
---

# Headscale browser (OIDC) login broken: the live config held the repo's redacted placeholder secret

**Status: closed 2026-09-25.**

## Symptom
Logging a device into `headscale.example.org` via the browser → `auth.example.org` login succeeded, then
Headscale showed **Forbidden**. Headscale log: `/oidc/callback status=403`, `exchanging code for token: oauth2:
"invalid_client" "Client authentication failed"`. Pre-auth-key joins were unaffected, which is why nobody noticed.

## Root cause
The live `~/headscale/config/config.yaml` on cloud-edge contained `client_secret: "<redacted -- s…"`,
byte-identical to the **repo** copy (sha256 matched). A previous sync of the repo's `config.yaml` to the server
(most likely the 2026-09-23 `purgos-infra` split, which added the 31 `extra_records`) overwrote the real secret
with the placeholder the repo uses to avoid committing it. The next Headscale restart loaded it.

## Fix
- Real secret (from the Authentik `Headscale` OAuth2 provider on cloud-auth, piped host-to-host, never printed)
  now lives in **`~/headscale/config/oidc_client_secret`** (root, 600), mounted as
  `/etc/headscale/oidc_client_secret`. `config.yaml` uses **`client_secret_path:`** instead of `client_secret:`,
  both live and in the repo, so **copying the repo config to the server can no longer clobber the secret**.
- Verified with a token-endpoint probe: the real secret returns `invalid_grant` (past client auth) for a bogus code;
  a wrong secret returns `invalid_client`.

## Self-inflicted during the fix (~2 min control-plane outage)
First attempt wrote the path with literal escaped quotes (`\"/etc/…\"`, a shell/heredoc quoting slip), so Headscale
crash-looped on "no such file" until the line was corrected. Existing tailnet connections kept working (the
data plane doesn't need the control server). Lesson: run `headscale configtest` **before** restarting, and act on it
(it was run, it failed, and the restart went ahead anyway because the commands were chained with `;` instead of `&&`).

## Follow-on, same evening: duplicate `purgos` user → Headscale refused to start (~5 min)

Once browser login worked again, the phone logged in as `purgos` via OIDC. Headscale's original `purgos`
(user 1) had been created by CLI with no OIDC link, so the login created a **second** user `purgos` (id 3, node
`phone-1`). Headscale kept running until its next restart, then refused to start:
`validating policy user references: multiple users found: token "purgos@" found: [1: purgos, 3: purgos]`.
The restart came from an attempt to link user 1 to OIDC, which was aborted by its own safety assert because the
identity was already taken by user 3.

**Fix (Headscale stopped, DB backed up to `data/db.sqlite.bak-2026-09-25-premerge`)**: moved node 18 to user 1,
deleted user 3, and set user 1's `provider='oidc'` + `provider_identifier` to the Authentik identity (issuer + the
`purgos` user's `uid`, `sub_mode=hashed_user_id`). Renamed nodes to match `tomo`'s pattern: `phone` (purgos)
and `phone-admin` (akadmin). `pragma integrity_check` ok, health 200.

**Result**: user 1 `purgos` is now OIDC-linked, so browser logins as `purgos` land on it, and pre-auth keys still work.

**Lessons**: (1) any Headscale user that will ever log in via OIDC must be created by that login (or linked like
this), never by CLI with the same name. (2) A policy that names a user (`purgos@`) turns a duplicate name into a
control-plane outage at the next restart. (3) Chain stop → edit → start with a trap/`finally` that always
restarts, not `&&`, so an aborted edit can't leave the service stopped.
