# trading-bots-db

The databases behind [trading-bots](https://github.com/lauris101/trading-bots),
on their own host: **PostgreSQL 17** (with wal-g continuous backups to
Cloudflare R2 / S3) and **ClickHouse**, reachable only through a
**Cloudflare Tunnel**. This repository is infrastructure only. The schema is
owned by the app repo: `trading-bots/migrations` is the single source of
truth and its `migrator` service applies it over the wire at every app
deploy. Nothing here creates a table.

```
docker-compose.yml       postgres, clickhouse, scraper, scheduler, fluentd, node-exporter, cloudflared (tunnel), minio (dev)
docker/postgres/         postgres:17 + wal-g image, archive wrapper, freshness check
clickhouse/config.d/     server overrides (console logging, memory caps, log TTLs)
cron/ofelia.ini          nightly base backup, weekly retention, daily freshness, cache trim
scripts/                 bootstrap.sh, deploy.sh, backup.sh, retention.sh,
                         restore-drill.sh, db-shell.sh, ch-shell.sh
ops/                     runbooks: backup & restore, database incidents
.env.example             the one config file (copy to .env)
justfile                 `just --list`
```

## Fresh server

```bash
apt-get update && apt-get install -y git
git clone git@github.com:lauris101/trading-bots-db.git && cd trading-bots-db
scripts/bootstrap.sh     # installs docker + just, generates .env with random
                         # passwords, then stops and asks for R2 + tunnel
$EDITOR .env             # R2 backend section, CLOUDFLARE_TUNNEL_TOKEN
scripts/bootstrap.sh     # deploys; rerun after any .env change
just backup && just restore-drill    # prove the backup pipeline
```

Every listener binds to `127.0.0.1` on the host: postgres `5432`, ClickHouse
`8123` (HTTP) and `9000` (native). Nothing needs to be open on the firewall
except SSH. `scripts/deploy.sh` refuses to run without a wal-g backend in
`.env` (`ALLOW_NO_BACKUPS=1` overrides, for testing).

On a laptop, `scripts/bootstrap.sh dev` gives the same stack with minio as
the S3 stand-in (compose profile `devstack`) and no prompts.

## Cloudflare Tunnel

The `cloudflared` service (profile `tunnel`) makes an outbound-only
connection to Cloudflare's edge and proxies public hostnames to the loopback
listeners. In Zero Trust, Networks > Tunnels > your tunnel > Public Hostname:

| hostname | type | origin |
|---|---|---|
| `db.<domain>` | TCP | `tcp://127.0.0.1:5432` |
| `ch.<domain>` | TCP | `tcp://127.0.0.1:9000` |
| `chdb.<domain>` | HTTP | `http://127.0.0.1:8123` |
| `metrics-db.<domain>` | HTTP | `http://127.0.0.1:9100` (node-exporter) |
| `scraper.<domain>` | HTTP | `http://127.0.0.1:8084` (the scraper's API; the trading host's IPs allowed) |

Put an **Access application** on each (Zero Trust > Access > Applications)
with two kinds of rule: **Allow** for the users who may log in from a
browser, and **Bypass** for the source IPs that may connect without logging
in: your own machines, the trading host (all of its public IPs), a
Prometheus scraper for `metrics-db.`. No service tokens anywhere.

**From your machine** (psql, DBeaver, clickhouse-client):

```bash
cloudflared access tcp --hostname db.<domain> --url 127.0.0.1:5432
cloudflared access tcp --hostname ch.<domain> --url 127.0.0.1:9000
```

Each opens a local listener, pops the Access login in a browser, and proxies
through the tunnel. Point the client at `localhost:5432` / `localhost:9000`
with the credentials from the server's `.env`.

**From the app host** (no browser): its public IPs are in the Bypass rule
of the `db.<domain>` and `chdb.<domain>` applications. The trading-bots
stack runs a `db-proxy` sidecar, the same `cloudflared access tcp` with just
the hostname, and its services use
`DATABASE_URL=postgres://...@db-proxy:5432/...`; ClickHouse is reached over
HTTPS at `chdb.<domain>`. See the app repo's `.env.example` and
`ops/deploy.md`.

## Backups

Postgres runs with `archive_mode=on`; wal-g ships every WAL segment as it
closes (at most 5 minutes behind via `archive_timeout`). The `scheduler`
(ofelia) pushes a nightly base backup at 02:30, applies `retain FULL 7`
weekly, and runs a freshness check daily that writes a `walg-backup` row
into the app's `service_heartbeats` table, so backup health shows up in the
app's `GET /status`. **Fail-soft**: with no `WALG_S3_PREFIX` archiving is a
no-op; with one configured, failures make postgres retain and retry WAL
rather than drop it. `just restore-drill` fetches the LATEST backup into a
throwaway postgres, replays WAL and runs a verification query. Run it
regularly. Full walkthrough and point-in-time recovery:
`ops/backup-and-restore.md`. Incidents (disk full, connections, failed
archive, vacuum): `ops/runbook-db.md`.

## The scraper runs here

The market-data scraper (venue top of book into ClickHouse) is a service of
the trading-bots repo, but it runs on this host: its inserts are then local,
and there is no cloud egress from the trading host for the 100+ million
quotes a day it writes. Where it observes from does not matter, because both
venues stamp every quote and `quotes.ts_venue` is the axis the analysis
joins on. The image is built and published by the app repo's CI on release
tags (`ghcr.io/lauris101/trading-bots-scraper`, a private package: `docker
login ghcr.io` once on this host with a token that has `read:packages`, and
pin a tag with `SCRAPER_IMAGE`). Control on the trading host pushes it the
subscriptions derived from what the bots trade, through `scraper.<domain>`.
It starts empty and needs nothing but ClickHouse and the venues.

ClickHouse has no backup job yet; its data is derivable (analytics loaded
from postgres and from the venue feeds). Adding one is a `BACKUP DATABASE
... TO S3(...)` job in `cron/ofelia.ini` when the tables exist.

## Where things are on disk

| what | host path |
|---|---|
| postgres data | `${DATA_BASE_DIR}/data/trading-bots/postgres` |
| clickhouse data | `${DATA_BASE_DIR}/data/trading-bots/clickhouse` |
| logs | `${LOGS_BASE_DIR}/logs/trading-bots/<UTC day>/<service>.log` |

Both base directories default to empty, so the defaults are
`/data/trading-bots/...` and `/logs/trading-bots/...`. Plain directories,
not docker volumes: `du`, `rsync` and the host's own backup see them.

**Logs.** Every container logs through the docker fluentd driver to the
`fluentd` container on this host, which appends each record to that day's
file for that service. The scheduler's daily `logs-rotate` job (ofelia,
`cron/ofelia.ini`) gzips finished days and removes day directories older
than `LOG_KEEP_DAYS` (7).
`docker compose logs <service>` still works (docker keeps a local copy).

## Moving from the app repo

Until 2026-09-04 postgres ran inside the trading-bots compose project, in a
docker volume named `trading-bots_pgdata`. To carry that data over, copy it
into the host directory while nothing runs, preserving ownership:

```bash
docker compose down
sudo mkdir -p /data/trading-bots
sudo rsync -a /var/lib/docker/volumes/trading-bots_pgdata/_data/ /data/trading-bots/postgres/
docker compose up -d
```

Keep `POSTGRES_USER` / `POSTGRES_DB` / `POSTGRES_PASSWORD` as they were: the
role and database were created at first initdb and do not change with the
environment. The wal-g history in the bucket continues; take a fresh base
backup after the move (`just backup`) so a restore never has to cross it.

## Same box as the app stack (dev)

Containers of another compose project cannot reach a port published on
`127.0.0.1`. When the trading-bots stack runs in docker on the same machine,
publish on the docker bridge address instead:

```
POSTGRES_BIND=172.17.0.1
CLICKHOUSE_BIND=172.17.0.1
```

The app containers then use `host.docker.internal` (which resolves to that
address) in `DATABASE_URL`, and host-native tools use `172.17.0.1` too. The
address is the host's own docker0 interface: reachable from the host and its
containers, not from the network.

## Day to day

```bash
just ps                    # both databases healthy
just psql                  # psql into postgres
just ch -q 'select 1'      # clickhouse-client
just backup                # base backup now
just freshness             # what the scheduler checks daily
just logs postgres
```

Container names are fixed (`trading-bots-postgres`, `trading-bots-clickhouse`)
so the cron jobs and scripts can target them.
