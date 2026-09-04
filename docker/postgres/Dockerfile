# syntax=docker/dockerfile:1
#
# PostgreSQL 17 with wal-g baked in for WAL archiving + base backups.
#
# Config strategy (documented in ops/backup-and-restore.md):
#   - A conf snippet (walg.conf) lives at /etc/postgresql-extra/walg.conf.
#   - An init script in /docker-entrypoint-initdb.d appends an
#     `include_if_exists` for that snippet to postgresql.conf at first initdb,
#     so later image rebuilds can change the snippet and a container restart
#     picks it up (no re-initdb needed).
#   - archive_command calls /usr/local/bin/walg-archive.sh, which is a no-op
#     (exit 0) when WALG_S3_PREFIX is unset -> archiving is fail-soft when no
#     S3 target is configured, but propagates failures (so postgres retains
#     and retries WAL) when an S3 target IS configured.
#   - wal-g reads its configuration (WALG_S3_PREFIX, AWS_*) from the container
#     environment; postgres inherits the container env, so archive_command and
#     `docker exec ... wal-g backup-push` both see it. The compose stack feeds
#     that env from the root .env via env_file.
#   - The container healthcheck is pg_isready only and never touches wal-g.

FROM postgres:17-bookworm

ARG WALG_VERSION=v3.0.9
ARG WALG_SHA256=4f03ee4679db7f660bfd1b2b8291ac5df247cd2ec48074b60c112f4897299f24

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    curl -fsSL -o /tmp/wal-g.tar.gz \
      "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/wal-g-pg-22.04-amd64.tar.gz"; \
    echo "${WALG_SHA256}  /tmp/wal-g.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/wal-g.tar.gz -C /usr/local/bin; \
    mv /usr/local/bin/wal-g-pg-22.04-amd64 /usr/local/bin/wal-g; \
    chmod 0755 /usr/local/bin/wal-g; \
    rm /tmp/wal-g.tar.gz; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    # Prove the binary actually runs on this base image.
    wal-g --version

COPY walg.conf /etc/postgresql-extra/walg.conf
COPY walg-archive.sh /usr/local/bin/walg-archive.sh
COPY walg-freshness.sh /usr/local/bin/walg-freshness.sh
COPY 01-enable-walg-conf.sh /docker-entrypoint-initdb.d/01-enable-walg-conf.sh
RUN chmod 0755 /usr/local/bin/walg-archive.sh /usr/local/bin/walg-freshness.sh \
      /docker-entrypoint-initdb.d/01-enable-walg-conf.sh
