#!/usr/bin/env bash
# Rebuild the postgres data directory from the wal-g backups in the bucket:
# the recovery path for a LOST host. Run after scripts/bootstrap.sh has put
# .env (the same R2 credentials) in place and BEFORE the stack is started.
#
#   just restore                         # LATEST base backup, replay all WAL
#   TARGET_BACKUP=base_00000001000000000000000A just restore
#   RECOVERY_TARGET_TIME='2026-09-11 14:31:00+00' just restore   # PITR
#
# What it does: refuses to touch a running postgres or a non-empty data dir
# (FORCE=1 moves a non-empty dir aside), fetches the backup into the data
# directory with the postgres+wal-g image, writes recovery.signal and the
# restore_command, then tells you to start the stack. Postgres replays WAL
# from the bucket on that start, promotes, and archiving resumes on the new
# timeline; take a base backup right after (`just backup`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${WALG_ENV_FILE:-${REPO_ROOT}/.env}"
IMAGE="${RESTORE_IMAGE:-trading-bots/postgres:17-walg}"
TARGET="${TARGET_BACKUP:-LATEST}"
CONTAINER_LIVE="trading-bots-postgres"
PGDATA_IN=/var/lib/postgresql/data

env_file_val() { sed -n "s/^${1}=//p" "${ENV_FILE}" 2>/dev/null | tail -1; }
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: ${ENV_FILE} not found - wal-g has no bucket to restore from (run scripts/bootstrap.sh first)" >&2
  exit 1
fi
if [[ -z "$(env_file_val WALG_S3_PREFIX)" ]]; then
  echo "error: WALG_S3_PREFIX is not set in ${ENV_FILE}: no backups to restore from" >&2
  exit 1
fi
DATA_BASE_DIR="${DATA_BASE_DIR:-$(env_file_val DATA_BASE_DIR)}"
DATA_DIR="${DATA_BASE_DIR:-}/data/trading-bots/postgres"

if docker ps -q -f "name=^${CONTAINER_LIVE}$" | grep -q .; then
  echo "error: ${CONTAINER_LIVE} is running. Stop the stack first: just down" >&2
  exit 1
fi
if [[ -d "${DATA_DIR}" ]] && [[ -n "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]]; then
  if [[ "${FORCE:-0}" != "1" ]]; then
    echo "error: ${DATA_DIR} is not empty. A restore must never overwrite a cluster" >&2
    echo "       that might still be wanted. FORCE=1 moves it aside first." >&2
    exit 1
  fi
  aside="${DATA_DIR}.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
  echo ">>> moving the existing data dir aside: ${aside}"
  sudo mv "${DATA_DIR}" "${aside}"
fi
sudo mkdir -p "${DATA_DIR}"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo ">>> building ${IMAGE}"
  docker compose --env-file "${ENV_FILE}" -f "${REPO_ROOT}/docker-compose.yml" build postgres
fi

echo ">>> [1/3] wal-g backup-fetch ${TARGET} -> ${DATA_DIR}"
docker run --rm --env-file "${ENV_FILE}" -v "${DATA_DIR}:${PGDATA_IN}" "${IMAGE}" bash -c "
  set -euo pipefail
  chown postgres:postgres '${PGDATA_IN}'
  su postgres -c \"wal-g backup-fetch '${PGDATA_IN}' '${TARGET}'\"
  chmod 0700 '${PGDATA_IN}'
"

echo ">>> [2/3] archive recovery: replay WAL from the bucket on the next start"
docker run --rm -v "${DATA_DIR}:${PGDATA_IN}" "${IMAGE}" bash -c "
  set -euo pipefail
  touch '${PGDATA_IN}/recovery.signal'
  {
    echo \"restore_command = 'wal-g wal-fetch %f %p'\"
    if [[ -n '${RECOVERY_TARGET_TIME:-}' ]]; then
      echo \"recovery_target_time = '${RECOVERY_TARGET_TIME:-}'\"
      echo \"recovery_target_action = 'promote'\"
    fi
  } >> '${PGDATA_IN}/postgresql.auto.conf'
  chown -R postgres:postgres '${PGDATA_IN}'
"

echo ">>> [3/3] restored. Now start the stack and let postgres replay:"
echo "      just up                       # or scripts/deploy.sh"
echo "      just logs postgres            # 'database system is ready to accept connections'"
echo "      just psql -c 'select count(*) from pg_tables where schemaname = ''public'''"
echo "    then take a fresh base backup on the new timeline:"
echo "      just backup"
