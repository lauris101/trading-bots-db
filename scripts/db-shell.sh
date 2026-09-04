#!/usr/bin/env bash
# Open a psql shell in the running postgres container.
# Usage: scripts/db-shell.sh [psql args...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose --env-file "${REPO_ROOT}/.env" -f "${REPO_ROOT}/docker-compose.yml")

env_file_val() { sed -n "s/^${1}=//p" "${REPO_ROOT}/.env" 2>/dev/null | tail -1; }
POSTGRES_USER="${POSTGRES_USER:-$(env_file_val POSTGRES_USER)}"
POSTGRES_DB="${POSTGRES_DB:-$(env_file_val POSTGRES_DB)}"

exec "${COMPOSE[@]}" exec postgres psql -U "${POSTGRES_USER:-trading-bots}" "${POSTGRES_DB:-trading-bots-db}" "$@"
