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

echo ">>> rolling the stack"
"${COMPOSE[@]}" up -d --remove-orphans

prune_after_deploy

echo ">>> done"
"${COMPOSE[@]}" ps
