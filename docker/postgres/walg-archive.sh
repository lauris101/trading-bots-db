#!/bin/bash
# archive_command wrapper: fail-soft when wal-g has no S3 target configured.
#
# - WALG_S3_PREFIX unset/empty  -> exit 0 (WAL is recycled; archiving is OFF
#   on purpose, e.g. local hacking without minio).
# - WALG_S3_PREFIX set          -> run wal-g wal-push and PROPAGATE its exit
#   code, so postgres keeps the WAL segment and retries until archiving
#   succeeds. Never mask errors here (no `|| true`): that would let postgres
#   recycle WAL that was never shipped, silently breaking PITR.
set -euo pipefail

if [[ -z "${WALG_S3_PREFIX:-}" ]]; then
  exit 0
fi

exec wal-g wal-push "$1"
