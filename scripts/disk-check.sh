#!/bin/bash
# ---------------------------------------------------------------------------
# Disk Usage Check + Monitoring Heartbeat
# Checks the datastore and root filesystems and reports to Uptime Kuma via a
# push monitor. Runs on the Proxmox host via cron, daily at 08:00 UTC.
#
# Push-monitor pattern: every run sends a status to Uptime Kuma. If usage is
# healthy it sends "up"; if either filesystem crosses the threshold it sends
# "down" with the numbers. Because Uptime Kuma also alerts when an expected
# push DOESN'T arrive, a dead cron job (no heartbeat) is itself an alert.
# ---------------------------------------------------------------------------

# Uptime Kuma push endpoint. The push key is a secret and lives in the URL;
# replace <UPTIME_KUMA_PUSH_KEY> with your monitor's key.
PUSH_URL="http://192.168.50.121:3001/api/push/<UPTIME_KUMA_PUSH_KEY>"
THRESHOLD=90

# Usage percentage for datastore (column 5 of df, second row, % stripped)
DATASTORE=$(df /mnt/datastore | awk 'NR==2 {print $5}' | tr -d '%')

# Usage percentage for the root filesystem
ROOT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$DATASTORE" -ge "$THRESHOLD" ] || [ "$ROOT" -ge "$THRESHOLD" ]; then
    # Over threshold — send down status so Uptime Kuma fires an alert
    curl -s "${PUSH_URL}?status=down&msg=DISK+ALERT+datastore:${DATASTORE}%25+root:${ROOT}%25&ping=" > /dev/null
else
    # Healthy — send up heartbeat
    curl -s "${PUSH_URL}?status=up&msg=OK+datastore:${DATASTORE}%25+root:${ROOT}%25&ping=" > /dev/null
fi
