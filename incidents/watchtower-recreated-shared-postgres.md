---
date: 2026-09-07
resolved: 2026-09-07
severity: degraded
kind: incident
hosts: []
backfilled: true
---

# Watchtower recreated the shared MariaDB + Postgres from a pinned-tag digest move

**Status**: resolved 2026-09-07 (~5 min Postgres disruption). Prevention applied — see bottom.

## What happened

During a fleet-wide `watchtower --run-once --cleanup` pass, the run on the **`database`** host
recreated **both** `mariadb` (`mariadb:12.3`) and `postgres`
(`ghcr.io/immich-app/postgres:16-vectorchord1.1.1`) — even though both tags are *pinned* to a specific
version. Upstream had **rebuilt those tags with a new digest** (a same-version rebuild), and Watchtower
treats "tag points at a new digest" as an update.

Fallout:
- MariaDB restarted cleanly; replication (db-backup primary → database replica) resumed on its own
  (`Seconds_Behind_Master: 0`, no errors).
- Postgres restarting made **pgpool mark both backend nodes `down`**
  (`all backend nodes are down, pgpool requires at least one valid node`). pgpool does **not**
  auto-reattach a recovered node — a known quirk of this fleet's setup
  (`Docker/shared/pgpool/README.md`, "A rejoined node doesn't automatically get
  read traffic back").
- ~5 min of `Npgsql … TimeoutException` on the Servarr apps (sonarr/radarr/lidarr/readarr). Synapse,
  WikiJS, Immich, Authentik, Vaultwarden, Forgejo rode it out with **0 errors** (their pools reconnect
  cleanly; the .NET Servarr Npgsql pool does not).

## Recovery

1. `docker restart pgpool` → brought node 0 (Database, primary) back and serving.
2. `docker exec pgpool rm -f /tmp/pgpool_status && docker restart pgpool` → cleared the persisted
   "node 1 down" state so pgpool re-probed and re-attached node 1 (Edge standby, status `2` = up/standby).
3. Servarr apps stopped erroring within ~1 min of pgpool being healthy — no app restarts needed.

## Prevention (applied 2026-09-07)

Watchtower is now on **all** Docker hosts (it was missing on metrics/database/authentik/blog/db-backup)
via `Scripts/setup-watchtower.sh` / `Scripts/rollout-watchtower.sh`. The stateful / infra-critical
containers are excluded by name with `WATCHTOWER_DISABLE_CONTAINERS` (a container-name list on the
watchtower container itself — cheap, no need to relabel/recreate the DB containers):

| Host | Excluded |
|---|---|
| `database` | `mariadb`, `postgres` |
| `db-backup` | `mariadb-replica` |
| `edge` | `postgres-replica`, `maxscale`, `npm-vps-edge` |
| `infra` | `pgpool`, `maxscale`, `npm-purgos-app-1`, `portainer` |
| `friendica` | `friendica-db-1` |

Those images now only ever move on a **deliberate** `docker compose pull && up`, done one node at a
time with replication checks between.

## Noticed while debugging (not caused by this)

The live Postgres topology is **Database (`10.10.161`) = primary, Edge (`100.80.68.81`) =
streaming standby** (Database `pg_is_in_recovery()=f` with Edge in `pg_stat_replication`; timeline 3,
forked 2026-09-07 01:09). Several docs written 2026-09-06/07 still said Edge was primary — a fail-back
that was never written up. Reconciled 2026-09-07: pgpool/database/Edge READMEs + the two failover
blog posts now say Database primary; see the pgpool README's "Primary history". `postgresql.auto.conf`
on Database still carries a leftover `primary_conninfo` pointing at Edge (harmless — no
`standby.signal`) — clean that stanza next time the container is touched.
