#!/usr/bin/env bash
# Deploy the database stack on a host: pull the latest code, rebuild the
# postgres image, roll the stack. Idempotent.
#
# Usage:
#   scripts/deploy.sh            # git pull --ff-only, build, up -d
#
# Environment toggles:
#   ALLOW_NO_BACKUPS=1   proceed without a wal-g backend (WALG_S3_PREFIX) in
#                        .env -- dev/testing only
#   SCRAPER_TAG=v0.4.0   load that scraper tag from R2 instead of latest
#   NO_PRUNE=1           skip the disk cleanup after the roll (dangling images
#                        and build cache over BUILD_CACHE_KEEP, default 5GB)
#   FRESH_CLUSTER=1      start an empty postgres although the wal-g backend
#                        already holds base backups (refused otherwise: a new
#                        host on an old bucket restores first, `just restore`)
#   BUILD_CACHE_KEEP=5GB how much BuildKit cache to leave for incremental builds
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose --env-file "${REPO_ROOT}/.env" -f "${REPO_ROOT}/docker-compose.yml")

# The scheduler's config hash rides in its environment (docker-compose.yml),
# so the roll below recreates it when cron/ofelia.ini changed and leaves it
# alone otherwise; ofelia only reads the file at start.
OFELIA_CONFIG_HASH="$(sha256sum "${REPO_ROOT}/cron/ofelia.ini" | cut -c1-16)"
export OFELIA_CONFIG_HASH

# Reclaim disk after a successful roll. The images a rebuild replaced are now
# dangling and the BuildKit cache grows by GBs per rebuild; both are pruned
# here (and nightly by the scheduler's docker-cache-prune job) so a host with
# a small disk does not fill up over a run of deploys. --keep-storage leaves
# the hot layers, so the next build stays incremental. The postgres image
# rebuilds from that cache, and the scraper image is re-pulled from R2 by
# tag, so nothing needed for rollback is lost. NO_PRUNE=1 skips it.
prune_after_deploy() {
  if [[ "${NO_PRUNE:-0}" == "1" ]]; then
    echo ">>> skipping the disk cleanup (NO_PRUNE=1)"
    return
  fi
  echo ">>> reclaiming disk: dangling images, build cache over ${BUILD_CACHE_KEEP:-5GB}"
  docker image prune -f | tail -1
  docker builder prune -f --keep-storage "${BUILD_CACHE_KEEP:-5GB}" | tail -1
  docker system df
}

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "error: ${REPO_ROOT}/.env missing (copy .env.example and fill it in)" >&2
  exit 1
fi
# A wal-g backend is configured iff .env has an uncommented, non-empty
# WALG_S3_PREFIX (the postgres container loads .env via env_file).
if ! grep -Eq '^WALG_S3_PREFIX=.+' "${REPO_ROOT}/.env"; then
  if [[ "${ALLOW_NO_BACKUPS:-0}" != "1" ]]; then
    echo "error: no WALG_S3_PREFIX in .env -> WAL archiving would be silently" >&2
    echo "       disabled. Fill in a backend section of .env (see .env.example)," >&2
    echo "       or set ALLOW_NO_BACKUPS=1 to deploy without backups anyway." >&2
    exit 1
  fi
  echo "warning: no WALG_S3_PREFIX in .env -> WAL archiving is disabled" >&2
fi

if git -C "${REPO_ROOT}" symbolic-ref -q HEAD >/dev/null; then
  echo ">>> git pull --ff-only"
  git -C "${REPO_ROOT}" pull --ff-only
else
  echo ">>> detached HEAD -- skipping git pull"
fi

if grep -Eq '^IMAGES_S3_BUCKET=.+' "${REPO_ROOT}/.env"; then
  echo ">>> pulling the scraper image from R2"
  "${REPO_ROOT}/scripts/pull-scraper.sh" "${SCRAPER_TAG:-latest}"
fi

echo ">>> building images"
"${COMPOSE[@]}" build --pull

# The data directory is read as root: it is postgres-owned 0700 once a
# cluster exists, and an unprivileged ls would call it empty.
# A host with NO postgres data directory and a backend that already holds
# base backups is a new box on an old bucket: a migration, or a rebuild. Up
# would initdb an empty cluster, archive its WAL into the live prefix next
# to the real cluster's, and, on the shared tunnel token, start answering
# the app's queries with nothing in it. Refuse; `just restore` first.
# FRESH_CLUSTER=1 is the way to start an empty database on a used prefix on
# purpose.
env_file_val() { sed -n "s/^${1}=//p" "${REPO_ROOT}/.env" | tail -1; }
PG_DATA_DIR="$(env_file_val DATA_BASE_DIR)/data/trading-bots/postgres"
if grep -Eq '^WALG_S3_PREFIX=.+' "${REPO_ROOT}/.env" \
  && [[ ! -d "${PG_DATA_DIR}" || -z "$(sudo ls -A "${PG_DATA_DIR}")" ]] \
  && ! docker ps -q -f "name=^trading-bots-postgres$" | grep -q . \
  && [[ "${FRESH_CLUSTER:-0}" != "1" ]]; then
  echo ">>> no postgres data directory: checking the backend for an existing cluster"
  backups="$(docker run --rm --env-file "${REPO_ROOT}/.env" trading-bots/postgres:17-walg \
    su postgres -c 'wal-g backup-list' 2>/dev/null | grep -c '^base_' || true)"
  if [[ "${backups}" != "0" ]]; then
    echo "error: ${PG_DATA_DIR} is empty but $(env_file_val WALG_S3_PREFIX) holds ${backups} base backup(s)." >&2
    echo "       Starting now would initdb an EMPTY cluster, archive its WAL into that prefix" >&2
    echo "       and, on the shared tunnel, serve the app from it. Restore first:" >&2
    echo "         just restore && scripts/deploy.sh" >&2
    echo "       To start an empty database on this prefix on purpose: FRESH_CLUSTER=1 scripts/deploy.sh" >&2
    exit 1
  fi
  echo "    no backups on the backend: a first deploy, initdb goes ahead"
fi

echo ">>> rolling the stack"
"${COMPOSE[@]}" up -d --remove-orphans

prune_after_deploy

echo ">>> done"
"${COMPOSE[@]}" ps
