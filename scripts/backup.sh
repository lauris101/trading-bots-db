#!/usr/bin/env bash
# Push a wal-g base backup from the running postgres container.
#
# Usage:
#   scripts/backup.sh            # base backup now
#   scripts/backup.sh --retain   # base backup, then `delete retain FULL 2`
#
# The container already carries the wal-g env (root .env via env_file) and
# PGUSER/PGDATABASE, so this is a thin docker-exec wrapper.
set -euo pipefail

CONTAINER="${POSTGRES_CONTAINER:-trading-bots-postgres}"
PGDATA_DIR="${PGDATA_DIR:-/var/lib/postgresql/data}"

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "error: container ${CONTAINER} is not running" >&2
  exit 1
fi

echo ">>> wal-g backup-push ${PGDATA_DIR} (container: ${CONTAINER})"
docker exec -u postgres "${CONTAINER}" wal-g backup-push "${PGDATA_DIR}"

if [[ "${1:-}" == "--retain" ]]; then
  "$(dirname "$0")/retention.sh"
fi

echo ">>> current backups:"
docker exec -u postgres "${CONTAINER}" wal-g backup-list
