# `just` recipes

Every recipe in the repository's `justfile`, what it runs and when to use
it. `just --list` prints the same names with their one-line comments. All
recipes read `.env`; the compose recipes run `docker compose --env-file
.env -f docker-compose.yml`.

## The stack

| recipe | runs | use |
| --- | --- | --- |
| `just up` | `compose up -d --build` | Start or update every service (postgres, clickhouse, scraper, scheduler, fluentd, node-exporter, cloudflared). `scripts/bootstrap.sh` and `scripts/deploy.sh` are the normal paths; this is the bare compose call. |
| `just down` | `compose down` | Stop everything. Data stays on disk (plain directories, not volumes). |
| `just ps` | `compose ps` | Container status. |
| `just logs <svc>` | `compose logs -f <svc>` | Follow one service's log, e.g. `just logs postgres`. |
| `just check` | `compose config --quiet` | Validate the compose file against the current `.env`. |
| `just help [recipe]` | prints the matching row of this page | Explain one recipe on the host, e.g. `just help restore`; without an argument, `just --list` plus a pointer here. |

## Shells

| recipe | runs | use |
| --- | --- | --- |
| `just psql [args]` | `scripts/db-shell.sh [args]` | psql inside the postgres container as the application user. |
| `just ch [args]` | `scripts/ch-shell.sh [args]` | clickhouse-client inside the clickhouse container. |

## Backups

| recipe | runs | use |
| --- | --- | --- |
| `just backup` | `scripts/backup.sh` | Push a wal-g base backup now (the scheduler does this nightly at 02:30). |
| `just retention` | `scripts/retention.sh` | Keep the newest 7 full backups (the scheduler does this weekly). |
| `just freshness` | `walg-freshness.sh` in the postgres container | The daily freshness check: newest backup and WAL age, written as a `walg-backup` heartbeat. |
| `just restore-drill` | `scripts/restore-drill.sh` | Prove the backups restore: fetch LATEST into a throwaway postgres, replay WAL, run a verification query. The live database is not touched. |
| `just restore` | `scripts/restore-latest.sh` | Rebuild the LIVE data directory from the bucket on a lost host. Requires the stack stopped and the data directory empty; refuses otherwise. `ops/backup-and-restore.md`. |

## The scraper

| recipe | runs | use |
| --- | --- | --- |
| `just pull-scraper [tag]` | `scripts/pull-scraper.sh <tag>` then `compose up -d --no-deps scraper` | Load the scraper image the app repo's CI published for a tag (default: the one `latest.json` points at) and recreate only the scraper container. The databases are never touched. |

## Not recipes, but next to them

- `scripts/bootstrap.sh [dev]`: a fresh host from nothing (docker and just, `.env` from the prod template with generated passwords, then the deploy). Rerun after any `.env` change.
- `scripts/deploy.sh`: what bootstrap runs to (re)deploy; refuses to run without a wal-g backend in `.env` (`ALLOW_NO_BACKUPS=1` overrides).
