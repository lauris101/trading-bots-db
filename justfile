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

# Explain a recipe from ops/just.md, e.g. `just help restore`; no argument lists them all
help *recipe:
    #!/usr/bin/env bash
    set -euo pipefail
    doc="{{justfile_directory()}}/ops/just.md"
    if [ -z "{{recipe}}" ]; then just --list; echo; echo "just help <recipe> explains one; the whole guide: $doc"; exit 0; fi
    row="$(grep -E '^\| `just {{recipe}}( |`)' "$doc" || true)"
    if [ -z "$row" ]; then echo "no recipe '{{recipe}}' in $doc"; exit 1; fi
    echo "$row" | sed -e 's/^| //' -e 's/ |$//' | awk -F' \\| ' '{ printf "%s\n  runs: %s\n  use:  %s\n", $1, $2, $3 }'
