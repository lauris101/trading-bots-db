# Database runbook

Shell into the DB: `just psql` (or `scripts/db-shell.sh`).
Container name: `trading-bots-postgres`.

## Disk full

Symptoms: `PANIC: could not write to file`, postgres in crash loop, or
`No space left on device` in `docker logs trading-bots-postgres`.

1. Confirm: `df -h /var/lib/docker` and
   `docker system df` (images/volumes breakdown).
2. Quick wins that do NOT touch the database:
   - `docker image prune -af` (old build layers)
   - `docker builder prune -af`
   - container logs are already capped (10m × 3) but other hosts' junk may not be.
3. **Most common cause here: WAL piling up because archiving is failing.**
   Check inside the container:
   ```bash
   docker exec -u postgres trading-bots-postgres \
     du -sh /var/lib/postgresql/data/pg_wal
   ```
   If it is huge, see "Failed archive" below — postgres keeps every WAL
   segment that has not been archived. Fix archiving (or disable it
   consciously by unsetting WALG_S3_PREFIX in .env and recreating the container); postgres
   frees the segments on the next checkpoints.
4. Never delete files from `pg_wal` by hand.
5. If truly wedged with 0 bytes free: stop the writers on the APP host
   (`recorder`, `api`, `collector` in the trading-bots stack), free space
   here, start postgres, then the rest.

## Connection exhaustion

Symptoms: services log `FATAL: sorry, too many clients already` /
`53300 too_many_connections`.

```sql
select count(*), state, usename, application_name
  from pg_stat_activity group by 2,3,4 order by 1 desc;
-- who is idle-in-transaction (the usual leak):
select pid, now() - xact_start as xact_age, query
  from pg_stat_activity
 where state = 'idle in transaction' order by xact_age desc;
-- surgical fix:
select pg_terminate_backend(pid) from pg_stat_activity
 where state = 'idle in transaction' and now() - xact_start > interval '5 minutes';
```

- `max_connections` is 200 (`POSTGRES_MAX_CONNECTIONS` in .env). If a
  service leaks connections, restarting that one service on the app host
  releases its pool — prefer that over raising max_connections.
- Persistent pressure → add a pooler (pgbouncer) or shrink sqlx pool sizes in
  the services.

## Failed archive (WAL not shipping)

```sql
select * from pg_stat_archiver;
-- archived_count should grow; failed_count growing + last_failed_wal set = broken
```

1. Read the archive error: `docker logs --tail 200 trading-bots-postgres`
   (walg-archive.sh stderr lands there).
2. Try by hand with the same env postgres sees:
   ```bash
   docker exec -u postgres trading-bots-postgres wal-g backup-list
   ```
   - Credentials/endpoint wrong → fix the wal-g backend section of `.env`, then
     `docker compose … up -d postgres` (env changes need recreate).
   - Bucket missing → create it (dev: is minio-init up? prod: real bucket).
   - minio/S3 down → restore connectivity; postgres retries automatically and
     the backlog drains (watch `pg_wal` size shrink).
3. Remember: with `WALG_S3_PREFIX` unset archiving is a silent no-op by design
   (`walg-archive.sh`), so "archiver shows no failures but backup-list is
   empty" usually means the .env wal-g backend never reached the container (recreate it).
4. After recovery, run `just backup` so a fresh base backup brackets the gap.

## Vacuum basics

- Autovacuum is ON by default — do not disable it.
- Health check:
  ```sql
  select relname, n_dead_tup, last_autovacuum, last_autoanalyze
    from pg_stat_user_tables order by n_dead_tup desc limit 10;
  ```
- Table growing despite deletes (e.g. `service_heartbeats`) → dead tuples not
  being reclaimed fast enough:
  ```sql
  vacuum (verbose, analyze) service_heartbeats;   -- online, no exclusive lock
  ```
- `vacuum full` rewrites the table and takes an exclusive lock — only during a
  maintenance window, only when bloat is severe.
- Long-running / idle-in-transaction sessions block vacuum from reclaiming
  anything ("oldest xmin"); hunt them with the connection-exhaustion queries.
- Watch for wraparound warnings in logs (`database is not accepting
  commands`) — if you ever see age > 1.5B, stop writes and vacuum immediately:
  ```sql
  select datname, age(datfrozenxid) from pg_database order by 2 desc;
  ```
