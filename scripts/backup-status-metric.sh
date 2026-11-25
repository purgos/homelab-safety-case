#!/bin/bash
# Writes Prometheus textfile metrics for vzdump backup freshness, using the
# same textfile-collector convention as lynis/trivy (Scripts/setup-lynis.sh,
# Scripts/setup-trivy.sh) -- no Prometheus scrape config change needed,
# node_exporter already reads this directory.
set -euo pipefail

OUT=/var/lib/prometheus/node-exporter/backup.prom
TMP="$(mktemp)"

TASKS="$(pvesh get /nodes/dyonisis/tasks --typefilter vzdump --limit 10 --output-format json)"

LAST_OK_ENDTIME="$(echo "$TASKS" | python3 -c '
import sys, json
tasks = json.load(sys.stdin)
ok = [t["endtime"] for t in tasks if t.get("status") == "OK"]
print(max(ok) if ok else 0)
')"
LATEST_ENDTIME="$(echo "$TASKS" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["endtime"])')"
LATEST_OK=0
[ "$(echo "$TASKS" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["status"])')" = "OK" ] && LATEST_OK=1

{
  echo "# HELP dyonisis_backup_last_success_timestamp_seconds Unix timestamp of the most recent successful vzdump job."
  echo "# TYPE dyonisis_backup_last_success_timestamp_seconds gauge"
  echo "dyonisis_backup_last_success_timestamp_seconds $LAST_OK_ENDTIME"
  echo "# HELP dyonisis_backup_last_run_timestamp_seconds Unix timestamp of the most recent vzdump job, regardless of outcome."
  echo "# TYPE dyonisis_backup_last_run_timestamp_seconds gauge"
  echo "dyonisis_backup_last_run_timestamp_seconds $LATEST_ENDTIME"
  echo "# HELP dyonisis_backup_last_run_ok Whether the most recent vzdump job succeeded (1) or not (0)."
  echo "# TYPE dyonisis_backup_last_run_ok gauge"
  echo "dyonisis_backup_last_run_ok $LATEST_OK"
} > "$TMP"
chmod 644 "$TMP"
mv "$TMP" "$OUT"
