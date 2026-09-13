#!/usr/bin/env bash
# The forced command behind the CI deploy key: the only thing that key can
# do on this host is ask for one scraper tag to be deployed.
#
# sshd runs it for the key that carries
#   command="/home/<user>/trading-bots-db/scripts/ci-deploy-scraper.sh",no-pty,...
# (trading-bots-host-setup, role trading_bot_user, ci_deploy_public_key) and
# passes what the client asked for in SSH_ORIGINAL_COMMAND:
#
#   ssh trading-bot@db-host deploy-scraper v0.5.0
#
# Anything but `deploy-scraper <tag>` is refused. The tag is checked against
# the manifest CI published (pull-scraper.sh verifies the checksum), the repo
# is fast-forwarded so the compose file matches the image, and only the
# scraper container is recreated (--no-deps: the databases are never touched).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
read -r -a words <<<"${SSH_ORIGINAL_COMMAND:-}"
if [[ "${#words[@]}" -ne 2 || "${words[0]}" != "deploy-scraper" ]]; then
  echo "refused: this key deploys the scraper only: deploy-scraper <tag>" >&2
  exit 2
fi
TAG="${words[1]}"
if [[ ! "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "refused: '${TAG}' is not a release tag (vX.Y.Z)" >&2
  exit 2
fi

echo ">>> $(date -u +%FT%TZ) deploying scraper ${TAG} on $(hostname)"
cd "${REPO_ROOT}"
# The compose file that runs the image should be the one released with it.
git pull --ff-only --quiet || echo "warning: git pull failed; deploying with the checked-out compose file" >&2
just pull-scraper "${TAG}"
docker ps --filter name=scraper --format '>>> {{.Names}} {{.Image}} {{.Status}}'
