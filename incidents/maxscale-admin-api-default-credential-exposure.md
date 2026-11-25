---
date: 2026-09-06
resolved: 2026-09-06
severity: degraded
kind: security
hosts: []
backfilled: true
---

# Opening MaxScale's admin API surfaced a default-credential exposure + a persistence footgun

**Status**: resolved — both issues fixed, verified live, 2026-09-06.

Found while wiring MaxScale's REST API (port 8989) into homepage-local's `siteMonitor` checks and
investigating Prometheus metrics options — see
`Docker/shared/maxscale/README.md`.

## What happened

MaxScale's admin API defaults to `admin_host=127.0.0.1` — loopback-only, invisible outside the container
even with the port published, since Docker's port-forwarding still has to land on a socket the app actually
bound. Both instances (Infrastructure and Edge) had also never had their default admin credential
(`admin`/`mariadb`, MaxScale's own out-of-the-box default) rotated — harmless while the API was
loopback-only, since nothing outside the container's own network namespace could ever reach it regardless
of the credential.

Setting `admin_host=0.0.0.0` to enable external monitoring access made this a real exposure for however
long the default credential remained in place afterward — anyone on the LAN/tailnet reaching port 8989
could authenticate as `admin`/`mariadb` and control MaxScale's failover behavior, including its two
production database backends. The credential was rotated to a generated value in the same maintenance
window, but the two steps weren't atomic — there was a real, if brief, window between opening the bind
address and rotating the password.

**Fix**: `maxctrl alter user admin <generated password>` on both instances immediately after opening
`admin_host`. Going forward, rotate credentials *before* opening any admin surface that was previously
loopback-protected, not after — treat "was this ever reachable with a default credential, even briefly" as
the real question, not "is it fixed now."

## The second problem — the fix didn't survive a container recreate

The rotated password appeared to work, then silently reverted to the default on the next full container
recreate (`docker compose down && up` — not `restart`, which keeps the same container and its writable
layer intact). Root cause: MaxScale's admin user database (`/var/lib/maxscale/passwd`) has no persistent
volume in the original `docker-compose.yml` — it lives entirely in the container's ephemeral writable layer,
so a recreate resets it to whatever ships in the image.

This wasn't a hypothetical — it happened for real, twice, during this same maintenance session (once
reflexively fixing an unrelated `pgrep: command not found` stop-loop on Edge's instance, once adding the
port mapping needed for the fix above), each time silently reintroducing the default credential until
re-rotated.

**Fix**: added `./data:/var/lib/maxscale` to both `docker-compose.yml`s, then rotated the credential one
final time on the now-persistent volume. Confirmed surviving a plain `docker restart` afterward.

## Lessons carried forward

- Opening any admin/API surface that was previously protected only by network isolation (loopback-only
  bind, unpublished port) means auditing its credentials *before* the surface goes live, not as an
  afterthought — a "harmless because unreachable" default becomes live risk the moment that assumption
  changes, and it's easy to open the surface and rotate the credential as two separate steps with a real
  gap between them.
- A credential or config change applied via a live admin command (`maxctrl alter user`, similar
  runtime-only changes on other tools) doesn't necessarily survive every kind of container lifecycle event —
  verify it against a full recreate, not just a restart, before considering it durable. This is the same
  class of gotcha as MariaDB/Postgres data directories needing real persistent volumes, just for
  application-level state instead of the database itself.
