#!/usr/bin/env bash
# Restore drill: prove that wal-g backups are actually restorable.
#
# Spins up a throwaway container from the postgres+wal-g image, fetches the
# LATEST base backup from the configured S3 target, replays WAL, starts
# postgres from the restored data dir on a side port, runs a verification
# query, then tears everything down.
#
# Tunables (env):
#   DRILL_NETWORK  docker network with reach to the S3 endpoint
#                  (default: trading-bots-db_default, the compose network;
#                  use `bridge` when the backend is R2/S3 rather than minio)
#   DRILL_PORT     host port (127.0.0.1) for the drilled postgres (default 5433)
#   VERIFY_QUERY   SQL that must succeed on the restored DB
#                  (default: select count(*) from service_heartbeats)
#   WALG_ENV_FILE  env file with the wal-g backend (default: .env)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${DRILL_IMAGE:-trading-bots/postgres:17-walg}"
NETWORK="${DRILL_NETWORK:-trading-bots-db_default}"
PORT="${DRILL_PORT:-5433}"
# The default query needs no application schema: a freshly bootstrapped host
# has no tables yet (the trading-bots migrator creates them), and the drill
# proves the RESTORE, not the schema. VERIFY_QUERY overrides it.
QUERY="${VERIFY_QUERY:-select count(*) || ' tables in public' from pg_tables where schemaname = 'public'}"
ENV_FILE="${WALG_ENV_FILE:-${REPO_ROOT}/.env}"
CONTAINER="trading-bots-restore-drill"
RESTORE_DIR=/var/lib/postgresql/restore
# Database identity: caller env wins, then the env file (the same one the
# stack runs with), then the repo defaults - so the drill can't probe the
# restored cluster with a role that doesn't exist in it.
env_file_val() { sed -n "s/^${1}=//p" "${ENV_FILE}" 2>/dev/null | tail -1; }
PGUSER="${POSTGRES_USER:-$(env_file_val POSTGRES_USER)}"
PGUSER="${PGUSER:-trading-bots}"
PGDB="${POSTGRES_DB:-$(env_file_val POSTGRES_DB)}"
PGDB="${PGDB:-trading-bots-db}"
# Recovery refuses to start with max_connections below the primary's (the
# value is in the WAL); the primary runs with POSTGRES_MAX_CONNECTIONS
# (docker-compose.yml, default 200), so the drill does too.
MAXCONN="${POSTGRES_MAX_CONNECTIONS:-$(env_file_val POSTGRES_MAX_CONNECTIONS)}"
MAXCONN="${MAXCONN:-200}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: ${ENV_FILE} not found - wal-g has no S3 target to restore from" >&2
  exit 1
fi

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo ">>> [1/5] starting throwaway container ${CONTAINER} (network: ${NETWORK})"
docker run -d --name "${CONTAINER}" \
  --network "${NETWORK}" \
  --env-file "${ENV_FILE}" \
  -p "127.0.0.1:${PORT}:5432" \
  --entrypoint sleep \
  "${IMAGE}" infinity >/dev/null

echo ">>> [2/5] wal-g backup-fetch LATEST -> ${RESTORE_DIR}"
docker exec -u postgres "${CONTAINER}" wal-g backup-fetch "${RESTORE_DIR}" LATEST

echo ">>> [3/5] preparing archive recovery (replay WAL, archiving OFF)"
docker exec -u postgres "${CONTAINER}" bash -c "
  set -euo pipefail
  chmod 0700 '${RESTORE_DIR}'
  touch '${RESTORE_DIR}/recovery.signal'
  {
    echo \"restore_command = 'wal-g wal-fetch %f %p'\"
    echo 'max_connections = ${MAXCONN}'  # at least the primary's, or recovery aborts
    echo 'archive_mode = off'      # never push WAL from a drill
    echo 'logging_collector = on'  # server log to \${RESTORE_DIR}/log/ so
    echo \"log_directory = 'log'\" # failure diagnostics below have a file
  } >> '${RESTORE_DIR}/postgresql.auto.conf'
"

echo ">>> [4/5] starting postgres from the restored data dir"
docker exec -d -u postgres "${CONTAINER}" postgres -D "${RESTORE_DIR}"

for i in $(seq 1 60); do
  if docker exec -u postgres "${CONTAINER}" pg_isready -q -U "${PGUSER}" -d "${PGDB}" 2>/dev/null; then
    break
  fi
  if [[ "${i}" == 60 ]]; then
    echo "error: restored postgres did not become ready in 60s" >&2
    docker exec "${CONTAINER}" bash -c "tail -50 ${RESTORE_DIR}/log/*.log 2>/dev/null" || true
    exit 1
  fi
  sleep 1
done

echo ">>> [5/5] verifying"
# Wait for WAL replay to finish and the cluster to promote out of recovery
# (hot standby accepts read-only connections while still replaying).
IN_RECOVERY=t
for i in $(seq 1 120); do
  IN_RECOVERY=$(docker exec -u postgres "${CONTAINER}" \
    psql -U "${PGUSER}" -d "${PGDB}" -tAc 'select pg_is_in_recovery()' 2>/dev/null || echo t)
  [[ "${IN_RECOVERY}" == "f" ]] && break
  sleep 1
done
if [[ "${IN_RECOVERY}" != "f" ]]; then
  echo "error: restored cluster is still in recovery after 120s (WAL replay stuck?)" >&2
  docker exec "${CONTAINER}" bash -c "tail -50 ${RESTORE_DIR}/log/*.log 2>/dev/null" || true
  exit 1
fi
RESULT=$(docker exec -u postgres "${CONTAINER}" \
  psql -U "${PGUSER}" -d "${PGDB}" -tAc "${QUERY}")

echo ""
echo "=== RESTORE DRILL SUCCEEDED ==="
echo "    query : ${QUERY}"
echo "    result: ${RESULT}"
echo "    (drilled instance was listening on 127.0.0.1:${PORT}; tearing down)"
