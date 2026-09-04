#!/usr/bin/env bash
# Open a clickhouse-client shell in the running clickhouse container.
# Usage: scripts/ch-shell.sh [clickhouse-client args...]   e.g. -q 'select 1'
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose --env-file "${REPO_ROOT}/.env" -f "${REPO_ROOT}/docker-compose.yml")

env_file_val() { sed -n "s/^${1}=//p" "${REPO_ROOT}/.env" 2>/dev/null | tail -1; }
CLICKHOUSE_USER="${CLICKHOUSE_USER:-$(env_file_val CLICKHOUSE_USER)}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-$(env_file_val CLICKHOUSE_PASSWORD)}"
CLICKHOUSE_DB="${CLICKHOUSE_DB:-$(env_file_val CLICKHOUSE_DB)}"

exec "${COMPOSE[@]}" exec clickhouse clickhouse-client \
  --user "${CLICKHOUSE_USER:-trading-bots}" --password "${CLICKHOUSE_PASSWORD}" \
  --database "${CLICKHOUSE_DB:-trading_bots}" "$@"
