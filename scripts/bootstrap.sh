#!/usr/bin/env bash
# Bootstrap a FRESH Debian/Ubuntu host as the database server and deploy.
# Idempotent: run it again after editing .env to finish a deploy.
#
#   apt-get update && apt-get install -y git
#   git clone git@github.com:lauris101/trading-bots-db.git && cd trading-bots-db
#   scripts/bootstrap.sh          # installs deps, generates .env, stops
#   $EDITOR .env                  # fill in the R2 backend + tunnel token
#   scripts/bootstrap.sh          # deploys
#
# For a laptop (minio as the S3 stand-in, no prompts): bootstrap.sh dev
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOUR="${1:-server}"

case "${FLAVOUR}" in
  server|dev) ;;
  *) echo "usage: $0 [server|dev]" >&2; exit 2 ;;
esac

SUDO=""
if [[ "$(id -u)" != "0" ]]; then
  SUDO="sudo"
fi

echo ">>> [1/3] installing host dependencies"
if ! command -v docker >/dev/null; then
  echo "    docker not found; installing via get.docker.com"
  curl -fsSL https://get.docker.com | ${SUDO} sh
  ${SUDO} systemctl enable --now docker
fi
if ! docker info >/dev/null 2>&1; then
  if ${SUDO} docker info >/dev/null 2>&1; then
    echo "    adding $(whoami) to the docker group (re-login or 'newgrp docker' to use docker without sudo)"
    ${SUDO} usermod -aG docker "$(whoami)"
  else
    echo "error: docker daemon is not running" >&2
    exit 1
  fi
fi
${SUDO} apt-get update -qq
${SUDO} apt-get install -y -qq just jq curl openssl git zstd >/dev/null

echo ">>> [2/3] configuration (.env)"
if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
  chmod 600 "${REPO_ROOT}/.env"
  # URL-safe generated secrets (hex only).
  sed -i "s|^POSTGRES_PASSWORD=$|POSTGRES_PASSWORD=$(openssl rand -hex 24)|" "${REPO_ROOT}/.env"
  sed -i "s|^CLICKHOUSE_PASSWORD=$|CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)|" "${REPO_ROOT}/.env"
  if [[ "${FLAVOUR}" == "server" ]]; then
    # No minio on a server; backups go to Cloudflare R2 (fill in below).
    sed -i "s|^COMPOSE_PROFILES=devstack$|COMPOSE_PROFILES=tunnel|" "${REPO_ROOT}/.env"
    sed -i -E "s|^(WALG_S3_PREFIX=s3://trading-bots-db/walg)$|#\1|; \
               s|^(AWS_ENDPOINT=http://minio:9000)$|#\1|; \
               s|^(AWS_S3_FORCE_PATH_STYLE=true)$|#\1|; \
               s|^(AWS_REGION=us-east-1)$|#\1|; \
               s|^(AWS_ACCESS_KEY_ID=minioadmin)$|#\1|; \
               s|^(AWS_SECRET_ACCESS_KEY=change-me)$|#\1|" "${REPO_ROOT}/.env"
    echo ""
    echo "    Generated ${REPO_ROOT}/.env with random database passwords."
    echo "    NOW: edit .env and fill in"
    echo "      - the 'Cloudflare R2' backend section (WALG_S3_PREFIX, AWS_ENDPOINT,"
    echo "        AWS_REGION=auto, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
    echo "      - CLOUDFLARE_TUNNEL_TOKEN (or drop 'tunnel' from COMPOSE_PROFILES)"
    echo "    then run this script again to deploy."
    echo "    To deploy WITHOUT backups (not recommended): ALLOW_NO_BACKUPS=1 $0"
    exit 0
  else
    MINIO_PASS="$(openssl rand -hex 24)"
    sed -i "s|^MINIO_ROOT_PASSWORD=$|MINIO_ROOT_PASSWORD=${MINIO_PASS}|" "${REPO_ROOT}/.env"
    sed -i "s|^AWS_SECRET_ACCESS_KEY=change-me$|AWS_SECRET_ACCESS_KEY=${MINIO_PASS}|" "${REPO_ROOT}/.env"
    echo "    generated .env with random postgres, clickhouse and minio credentials (dev)"
  fi
else
  echo "    .env already present; leaving it as is"
fi

echo ">>> [3/3] deploying"
"${REPO_ROOT}/scripts/deploy.sh"

cat <<'EOF'

Done. Next steps:
  - just ps                              # both databases healthy
  - just backup && just restore-drill    # prove the backup pipeline
  - Point the app stack at this host: DATABASE_URL in trading-bots/.env
    (through the tunnel's db.<domain> hostname; see README).
EOF
