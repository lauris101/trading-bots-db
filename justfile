# trading-bots-db task runner. `just --list` for an overview.

set dotenv-load := true

compose := "docker compose --env-file .env -f docker-compose.yml"

# Start (or update) the databases
up:
    {{compose}} up -d --build

# Stop everything (volumes are kept)
down:
    {{compose}} down

# Show status
ps:
    {{compose}} ps

# Tail logs for one service, e.g. `just logs postgres`
logs svc:
    {{compose}} logs -f {{svc}}

# psql shell into the database
psql *args:
    ./scripts/db-shell.sh {{args}}

# clickhouse-client shell
ch *args:
    ./scripts/ch-shell.sh {{args}}

# Push a wal-g base backup now
backup:
    ./scripts/backup.sh

# Apply retention: keep the newest 7 full backups
retention:
    ./scripts/retention.sh

# Prove backups restore: fetch LATEST into a throwaway postgres and verify
restore-drill:
    ./scripts/restore-drill.sh

# Rebuild the LIVE postgres data dir from the bucket (a lost host): stack stopped, data dir empty
restore:
    ./scripts/restore-latest.sh

# Load the scraper image from R2 (a tag, or the latest) and recreate ONLY the scraper (--no-deps: the databases are never touched)
pull-scraper tag="latest":
    ./scripts/pull-scraper.sh {{tag}} && {{compose}} up -d --no-deps scraper

# Backup freshness check (what the scheduler runs daily)
freshness:
    docker exec -u postgres trading-bots-postgres walg-freshness.sh

# Validate the compose file against the current .env
check:
    {{compose}} config --quiet && echo "compose config ok"
