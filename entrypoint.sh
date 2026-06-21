#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------
# Entrypoint
#
# SCHEDULE unset  → run backup once and exit
# SCHEDULE set    → install crontab and run crond forever
# -------------------------------------------------------

if [[ -z "${SCHEDULE:-}" ]]; then
    echo "[entrypoint] No SCHEDULE set — running backup once."
    exec /app/backup.sh
fi

echo "[entrypoint] SCHEDULE='$SCHEDULE' — installing crontab."

# Write crontab for root; redirect output to stdout/stderr so
# `docker logs` captures everything.
echo "$SCHEDULE /app/backup.sh >> /proc/1/fd/1 2>> /proc/1/fd/2" \
    > /etc/cron.d/audible-backup

chmod 0644 /etc/cron.d/audible-backup
crontab /etc/cron.d/audible-backup

echo "[entrypoint] Next run: $(crontab -l)"
echo "[entrypoint] Starting cron daemon..."

# Run cron in foreground (-f) so the container stays alive.
exec cron -f
