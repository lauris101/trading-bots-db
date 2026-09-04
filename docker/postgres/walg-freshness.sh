#!/usr/bin/env bash
# Verify wal-g base-backup freshness and publish the result where humans and
# the api can see it: a `service_heartbeats` row (service = 'walg-backup'),
# so `GET /status` shows backup health alongside the services.
#
# Scheduled daily by ofelia (cron/ofelia.ini). Exit codes:
#   0  backups fresh (or archiving deliberately disabled: no WALG_S3_PREFIX)
#   1  no backups found, or the newest one is older than MAX_AGE_HOURS
set -euo pipefail

MAX_AGE_HOURS="${MAX_AGE_HOURS:-30}"   # nightly backup + slack

beat() { # beat <details-json>
  psql -X -q -v ON_ERROR_STOP=1 -v details="$1" <<'SQL'
insert into service_heartbeats (service, beat_at, details)
values ('walg-backup', now(), :'details'::jsonb)
on conflict (service) do update
  set beat_at = excluded.beat_at, details = excluded.details;
SQL
}

if [[ -z "${WALG_S3_PREFIX:-}" ]]; then
  beat '{"ok": true, "archiving": "disabled (no WALG_S3_PREFIX)"}'
  echo "walg-freshness: archiving disabled; nothing to verify"
  exit 0
fi

# List backups, keeping wal-g's own failure visible: a broken S3 target
# (rotated credentials, endpoint down) is exactly what this check exists to
# catch, so it must produce an ok:false heartbeat, not a silent abort.
set +e
backup_list_output="$(wal-g backup-list 2>&1)"
backup_list_rc=$?
set -e
if ((backup_list_rc != 0)); then
  echo "${backup_list_output}" >&2
  beat "{\"ok\": false, \"error\": \"wal-g backup-list failed (exit ${backup_list_rc}); see scheduler log\"}"
  echo "walg-freshness: FAIL - wal-g backup-list failed (exit ${backup_list_rc})" >&2
  exit 1
fi

# Newest backup's modified timestamp: last data line, second column.
last_backup="$(echo "${backup_list_output}" | awk 'NR > 1 { ts = $2 } END { print ts }')"

if [[ -z "${last_backup}" ]]; then
  beat '{"ok": false, "error": "no base backups found in storage"}'
  echo "walg-freshness: FAIL - no base backups found" >&2
  exit 1
fi

now_epoch="$(date +%s)"
backup_epoch="$(date -d "${last_backup}" +%s)"
age_hours=$(((now_epoch - backup_epoch) / 3600))

if ((age_hours > MAX_AGE_HOURS)); then
  beat "{\"ok\": false, \"last_backup\": \"${last_backup}\", \"age_hours\": ${age_hours}, \"max_age_hours\": ${MAX_AGE_HOURS}}"
  echo "walg-freshness: FAIL - newest backup ${last_backup} is ${age_hours}h old (max ${MAX_AGE_HOURS}h)" >&2
  exit 1
fi

beat "{\"ok\": true, \"last_backup\": \"${last_backup}\", \"age_hours\": ${age_hours}}"
echo "walg-freshness: OK - newest backup ${last_backup} (${age_hours}h old)"
