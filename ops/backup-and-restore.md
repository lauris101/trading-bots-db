# Backup & restore (wal-g)

## How WAL archiving works here

The postgres image (`docker/postgres/`) is `postgres:17-bookworm` with
[wal-g](https://github.com/wal-g/wal-g) v3.0.9 baked in. Configuration pieces:

- **Source of truth: compose command-line args.** The `postgres` service in
  `docker-compose.yml` passes the four archiving GUCs as
  `postgres -c ...` arguments — `wal_level = replica`, `archive_mode = on`,
  `archive_timeout = 300`,
  `archive_command = '/usr/local/bin/walg-archive.sh %p'`. Command-line args
  outrank every config file and hold even when the `pgdata` volume was
  initialized by a different image. To change one of these, edit the compose
  file and recreate the container.
- `docker/postgres/walg.conf` — the same settings as a conf snippet at
  `/etc/postgresql-extra/walg.conf`, wired into `postgresql.conf` at first
  initdb via `include_if_exists` (script `01-enable-walg-conf.sh`). This is a
  fallback for running the image *outside* this compose stack; under compose
  the command-line args above win. Keep the two in sync.
- `walg-archive.sh` — the archive wrapper. **Fail-soft gating**: if
  `WALG_S3_PREFIX` is unset (no wal-g backend in `.env`), it exits 0 and
  WAL is recycled — the stack runs fine with archiving deliberately off. If
  `WALG_S3_PREFIX` *is* set, the script propagates wal-g's exit code, so a
  broken S3 target makes postgres retain and retry WAL (visible in
  `pg_stat_archiver`, see runbook) instead of silently losing it. We chose the
  wrapper over `... || true` precisely because `|| true` lets postgres recycle
  WAL that was never shipped.
- wal-g gets its target + credentials from the **container environment**:
  compose loads the root `.env` (gitignored) into the postgres service via
  `env_file`, so the wal-g backend section there is all it takes. Both the
  archive_command (postgres inherits container env) and
  `docker exec … wal-g …` see the same config — no files inside `$PGDATA`.
- The container **healthcheck is `pg_isready` only** — it never touches wal-g
  or S3, so S3 outages can't cascade into restarts of a healthy database.
- To change an archiving GUC: edit the `postgres` service `command:` args in
  `docker-compose.yml` (and mirror it in `walg.conf`), then
  recreate the container (`docker compose … up -d postgres`).

## Backup schedule

The `scheduler` service (ofelia) drives cron via `docker exec` on the postgres
container (`cron/ofelia.ini`):

| job | schedule | command |
|---|---|---|
| base backup | daily 02:30 | `wal-g backup-push /var/lib/postgresql/data` |
| retention | Sun 04:00 | `wal-g delete retain FULL 7 --confirm` |
| freshness check | daily 06:00 | `walg-freshness.sh` |
| docker cache prune | daily 05:00 | `docker builder prune -f --keep-storage 5GB` + dangling image prune |

The freshness check guards against "green stack, zero backups": it fails
(visible in the scheduler log) when no base backup exists or the newest one is
older than `MAX_AGE_HOURS` (30), and it upserts a `service_heartbeats` row
(service `walg-backup`, details `{ok, last_backup, age_hours}`), so backup
health shows up in the app's api (`GET /status`, trading-bots repo) next to the services. Run it by
hand anytime: `docker exec -u postgres trading-bots-postgres walg-freshness.sh`.

Manual equivalents:

```bash
just backup                      # scripts/backup.sh
scripts/backup.sh --retain    # backup, then apply retention
scripts/retention.sh 7        # retention only
docker exec -u postgres trading-bots-postgres wal-g backup-list
```

## Restore drill (run this regularly — an untested backup is not a backup)

```bash
just restore-drill               # scripts/restore-drill.sh
```

What it does: starts a throwaway container from the postgres+wal-g image on the
compose network, `wal-g backup-fetch <dir> LATEST`, adds `recovery.signal` +
`restore_command = 'wal-g wal-fetch %f %p'` (and `archive_mode = off` so the
drill never pushes WAL), starts postgres from the restored dir on
`127.0.0.1:5433`, waits for recovery to finish, verifies with
`select count(*) from service_heartbeats`, prints the result, and tears down.
Tunables: `DRILL_NETWORK`, `DRILL_PORT`, `VERIFY_QUERY`, `WALG_ENV_FILE`.

## Rebuilding a lost host (`just restore`)

`scripts/restore-latest.sh` restores into the LIVE data directory
(`${DATA_BASE_DIR}/data/trading-bots/postgres`), for a host rebuilt from
scratch. It refuses to run while `trading-bots-postgres` is up or while the
data directory is non-empty (`FORCE=1` moves a non-empty directory aside as
`postgres.replaced-<time>`), fetches `TARGET_BACKUP` (default `LATEST`) with
the postgres+wal-g image using the credentials in `.env`, writes
`recovery.signal` and `restore_command = 'wal-g wal-fetch %f %p'` (plus
`recovery_target_time` / `recovery_target_action = 'promote'` when
`RECOVERY_TARGET_TIME` is set), and stops. Starting the stack (`just up`,
`scripts/deploy.sh`) makes postgres replay the WAL from the bucket, promote
onto a new timeline and resume archiving. Take a base backup then
(`just backup`): the retention job keeps counting from it.

## Point-in-time recovery (PITR)

To restore to a specific moment (e.g. just before an incident at 14:32):

```bash
# On the APP host: stop the writers (recorder, api, collector) first --
# trading-bots/infra/scripts/deploy.sh's compose files, `stop recorder api collector`.

# Into the live data dir on a stopped stack. TARGET_BACKUP must be a base
# backup taken BEFORE the target time (pick it from `wal-g backup-list`;
# LATEST is right only if it predates the target):
RECOVERY_TARGET_TIME='2026-08-29 14:31:00+00' TARGET_BACKUP=base_... FORCE=1 just restore
just up
# Or into a throwaway container to inspect first: the same pattern as
# restore-drill.sh with the two recovery_target lines in postgresql.auto.conf.
```

Postgres replays WAL up to the target time and promotes. Validate the data,
then either point the stack at the recovered data dir (swap it into the
`pgdata` volume while postgres is stopped) or dump/restore what you need.
Rule of thumb: never overwrite the broken cluster before the recovered one is
verified.

## Switching minio → Cloudflare R2 (production target)

1. In the Cloudflare dashboard: create the R2 bucket, then create an **S3 API
   token** (R2 → Manage R2 API Tokens → Create API token, permission
   "Object Read & Write", scoped to that bucket). This yields the S3-style
   Access Key ID / Secret — a plain Cloudflare API token does NOT work with
   wal-g.
2. `.env`: set `COMPOSE_PROFILES=` (empty). minio/minio-init are under the
   `devstack` profile, so they simply stop being part of the project.
3. In `.env`, comment out the minio backend block and fill in the Cloudflare
   R2 one (see `.env.example`):
   - `WALG_S3_PREFIX=s3://trading-bots-db/walg`
   - `AWS_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com`
   - `AWS_S3_FORCE_PATH_STYLE=true`
   - `AWS_REGION=auto`
   - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from step 1.
4. Recreate postgres so it picks up the env: `docker compose … up -d postgres`.
5. Verify end to end: `just backup`, check `wal-g backup-list`, then
   `just restore-drill` (set `DRILL_NETWORK=bridge` — minio is gone and R2 is
   reachable from any network).

For plain AWS S3 instead: same flow, but drop `AWS_ENDPOINT` and
`AWS_S3_FORCE_PATH_STYLE`, and set a real `AWS_REGION`.

The old minio history does not migrate; take a fresh base backup immediately
after switching (step 5 does).
