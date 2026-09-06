#!/bin/sh
# Log housekeeping, run by the scheduler (ofelia job-exec) inside the fluentd
# container, which already has the log directory mounted at /logs: gzip every
# .log in a day directory that is not today's, and remove day directories
# older than KEEP_DAYS. fluentd may still append a straggler to yesterday's
# file for a few seconds after midnight, so an already-gzipped name is
# appended to (gzip members concatenate; zcat reads them as one stream).
set -u
LOGS="${LOGS_DIR:-/logs}"
KEEP="${KEEP_DAYS:-7}"
today="$(date -u +%F)"
for dir in "${LOGS}"/*/; do
  [ -d "${dir}" ] || continue
  [ "$(basename "${dir}")" = "${today}" ] && continue
  find "${dir}" -type f -name '*.log' | while IFS= read -r f; do
    if [ -e "${f}.gz" ]; then
      gzip -c "${f}" >> "${f}.gz" && rm -f "${f}"
    else
      gzip -q "${f}"
    fi
  done
done
find "${LOGS}" -mindepth 1 -maxdepth 1 -type d -mtime +"${KEEP}" -exec rm -rf {} +
echo "logs-rotate: done (today ${today}, keep ${KEEP} days)"
