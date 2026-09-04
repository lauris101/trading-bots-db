#!/usr/bin/env bash
# Apply the retention policy: keep the newest N full backups (default 7)
# plus the WAL required to restore any of them; delete everything older.
#
# Usage: scripts/retention.sh [N]
set -euo pipefail

CONTAINER="${POSTGRES_CONTAINER:-trading-bots-postgres}"
RETAIN="${1:-7}"

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "error: container ${CONTAINER} is not running" >&2
  exit 1
fi

echo ">>> wal-g delete retain FULL ${RETAIN} --confirm (container: ${CONTAINER})"
docker exec -u postgres "${CONTAINER}" wal-g delete retain FULL "${RETAIN}" --confirm
