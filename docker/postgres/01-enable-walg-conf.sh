#!/bin/bash
# Runs once at first initdb (official postgres image entrypoint hook).
# Wires the wal-g conf snippet into postgresql.conf via include_if_exists so
# future changes to /etc/postgresql-extra/walg.conf only need a restart.
set -euo pipefail

if ! grep -q '/etc/postgresql-extra/walg.conf' "${PGDATA}/postgresql.conf"; then
  cat >> "${PGDATA}/postgresql.conf" <<'EOF'

# Added by docker/postgres/01-enable-walg-conf.sh (image build)
include_if_exists = '/etc/postgresql-extra/walg.conf'
EOF
fi
