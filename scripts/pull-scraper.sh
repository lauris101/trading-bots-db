#!/usr/bin/env bash
# Fetch the scraper image from the R2 bucket the app repo's CI publishes to,
# and load it into docker as trading-bots/scraper:<tag> and :latest.
#
# Usage:
#   scripts/pull-scraper.sh            # the tag `latest.json` points at
#   scripts/pull-scraper.sh v0.4.0     # a specific tag
#
# Reads the bucket and the R2 credentials from .env: IMAGES_S3_BUCKET plus
# the wal-g section's AWS_ENDPOINT / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# (the same R2 account; give the token Object Read on this bucket too). The
# aws cli runs from its container, so nothing is installed on the host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
env_val() { sed -n "s/^${1}=//p" "${ENV_FILE}" 2>/dev/null | tail -1; }

BUCKET="${IMAGES_S3_BUCKET:-$(env_val IMAGES_S3_BUCKET)}"
ENDPOINT="${AWS_ENDPOINT:-$(env_val AWS_ENDPOINT)}"
KEY_ID="${AWS_ACCESS_KEY_ID:-$(env_val AWS_ACCESS_KEY_ID)}"
SECRET="${AWS_SECRET_ACCESS_KEY:-$(env_val AWS_SECRET_ACCESS_KEY)}"
WANT="${1:-latest}"
if [[ -z "${BUCKET}" || -z "${ENDPOINT}" || -z "${KEY_ID}" || -z "${SECRET}" ]]; then
  echo "error: IMAGES_S3_BUCKET, AWS_ENDPOINT, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are needed (in ${ENV_FILE})" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
s3() { # s3 <args...>: the aws cli in a container, credentials from the env
  docker run --rm --network host \
    -e AWS_ACCESS_KEY_ID="${KEY_ID}" -e AWS_SECRET_ACCESS_KEY="${SECRET}" -e AWS_DEFAULT_REGION=auto \
    -v "${WORK}:/work" amazon/aws-cli:2.22.35 --endpoint-url "${ENDPOINT}" s3 "$@"
}

echo ">>> reading scraper/${WANT}.json from s3://${BUCKET}"
s3 cp "s3://${BUCKET}/scraper/${WANT}.json" /work/manifest.json --only-show-errors
TAG="$(sed -n 's/.*"tag":"\([^"]*\)".*/\1/p' "${WORK}/manifest.json")"
SHA="$(sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p' "${WORK}/manifest.json")"
[[ -n "${TAG}" && -n "${SHA}" ]] || { echo "error: manifest unreadable: $(cat "${WORK}/manifest.json")" >&2; exit 1; }
if docker image inspect "trading-bots/scraper:${TAG}" >/dev/null 2>&1; then
  echo ">>> trading-bots/scraper:${TAG} already loaded"
else
  echo ">>> downloading scraper/${TAG}.tar.zst"
  s3 cp "s3://${BUCKET}/scraper/${TAG}.tar.zst" /work/image.tar.zst --only-show-errors
  echo "${SHA}  ${WORK}/image.tar.zst" | sha256sum -c - >/dev/null
  echo ">>> loading into docker"
  zstd -dc "${WORK}/image.tar.zst" | docker load >/dev/null
fi
docker tag "trading-bots/scraper:${TAG}" trading-bots/scraper:latest
echo ">>> trading-bots/scraper:${TAG} is :latest (sha256 ${SHA})"
