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
#   PRUNE=1              also prune dangling images afterwards
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose --env-file "${REPO_ROOT}/.env" -f "${REPO_ROOT}/docker-compose.yml")

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

if [[ "${PRUNE:-0}" == "1" ]]; then
  echo ">>> pruning dangling images (PRUNE=1)"
  docker image prune -f
fi

echo ">>> done"
"${COMPOSE[@]}" ps
