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

## Scheduler jobs all fail: "cannot connect to Docker endpoint"

Every ofelia job in `scheduler.log` fails within a millisecond of starting,
`error creating exec: cannot connect to Docker endpoint` (or `dial unix
/var/run/docker.sock: connection refused` for the `job-run` prunes), from
some moment on. The docker daemon restarted at that moment (`sudo
journalctl -u docker`; a containerd or docker package upgrade, see
`/var/log/apt/history.log`); the containers survived it (live-restore) and
the scheduler kept its dead client connection. Nothing ran: no base backup,
no retention, no freshness check, so the `walg-backup` heartbeat in the
app's `GET /status` goes stale.

1. `docker compose restart scheduler`, and confirm the next job in
   `scheduler.log` finishes with `failed: false`.
2. Take the missed base backup and rewrite the heartbeat:
   ```bash
   just backup
   docker exec -u postgres trading-bots-postgres walg-freshness.sh
   ```
3. If this happened at all, the host lacks the `docker.service` drop-in that
   restarts the scheduler after a daemon start: re-run `scripts/bootstrap.sh`
   (or host-setup's `just provision`) and check
   `/etc/systemd/system/docker.service.d/restart-socket-clients.conf` exists.

## ClickHouse: "memory limit exceeded" on every query, inserts included

Every query, the scraper's `INSERT`s among them, fails with `Code: 241 ...
(total) memory limit exceeded ... current RSS: x GiB, maximum: y GiB` while
`system.processes` is empty. The server's resident memory has crept over
its cap (`max_server_memory_usage`, `clickhouse/config.d/trading-bots.xml`)
without any query holding it: memory-mapped data files, the query condition
cache and the allocator's slack. Until it is under the cap again nothing
runs, and quotes are being lost.

1. Free what can be freed without a restart (each is harmless, the caches
   rebuild):
   ```sql
   SYSTEM DROP MMAP CACHE;
   SYSTEM DROP QUERY CONDITION CACHE;
   SYSTEM DROP MARK CACHE;
   SYSTEM JEMALLOC PURGE;
   ```
   then `select metric, formatReadableSize(value) from
   system.asynchronous_metrics where metric = 'MemoryResident'` must read
   under the cap, and `select max(ts) from quotes` must move again.
2. If it does not: `docker compose restart clickhouse` (the scraper
   reconnects; the quotes of the restart's seconds are lost).
3. Check the gap: `select venue, min(ts), max(ts) from quotes where ts
   between <first failure> and <recovery> group by venue`. The first failure
   is in `select min(event_time) from system.query_log where exception_code
   = 241 and event_date = today()`.

The cap is set explicitly in the config file and hot-reloads from it, so
raising it is a `git pull` on this host; keep it about 1 GiB under the
container's memory limit (the compose file's 5g, or `CLICKHOUSE_MEMORY`
where a smaller host overrides it), the room the resident-but-untracked
memory needs, or the kernel kills the container instead. A new container
limit needs `docker compose up -d clickhouse` (a recreate: the scraper
reconnects, the restart's seconds of quotes are lost).

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
