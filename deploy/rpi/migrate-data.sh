#!/usr/bin/env bash
# migrate-data.sh — preserve Loopy appliance data across the one-time re-layout flash
# that introduces the persistent /data partition (Phase 0 of #300).
#
# Before that flash, the app's data lives on the ROOTFS (/root/{Documents,.config,
# .local}); the flash wipes it. After it, data lives on /data. This script backs the
# old data up off-device and restores it onto the new /data, with verification.
#
# Usage:
#   ./migrate-data.sh backup  [user@host] [backup.tar.gz]   # BEFORE the re-layout flash
#   ./migrate-data.sh restore [user@host] [backup.tar.gz]   # AFTER  the re-layout flash
#   ./migrate-data.sh verify  [user@host]                   # list what's on /data now
#
# Defaults: host root@192.168.50.211, backup ./loopy-data-backup.tar.gz
set -euo pipefail

CMD="${1:-}"
HOST="${2:-root@192.168.50.211}"
BACKUP="${3:-./loopy-data-backup.tar.gz}"

# Non-interactive ssh that works in this sandbox (osxkeychain-free).
SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

# The app's persistent data, relative to $HOME. Keep in sync with loopy-kiosk-launch.
PATHS="Documents .config .local"

die() { echo "migrate-data: $*" >&2; exit 1; }

case "$CMD" in
  backup)
    # Old layout: data under /root. Tar exactly the app dirs (skip if absent).
    echo "==> Backing up ${HOST}:/root/{${PATHS// /,}} -> ${BACKUP}"
    "${SSH[@]}" "$HOST" "cd /root && tar czf - \$(for p in $PATHS; do [ -e \"\$p\" ] && printf '%s ' \"\$p\"; done) 2>/dev/null" > "$BACKUP" \
      || die "backup failed"
    sz=$(wc -c < "$BACKUP" | tr -d ' ')
    [ "$sz" -gt 0 ] || die "backup is empty — nothing captured (abort before flashing!)"
    echo "==> Wrote ${BACKUP} (${sz} bytes). Contents:"
    tar tzf "$BACKUP" | sed 's/^/    /'
    echo "==> Safe to re-layout flash now. Then run: $0 restore $HOST $BACKUP"
    ;;

  restore)
    # New layout: /data mounted. Extract the backup into /data (creating
    # /data/Documents, /data/.config, /data/.local). loopy-kiosk-launch points
    # HOME=/data, so the app picks these up.
    [ -f "$BACKUP" ] || die "no backup file at ${BACKUP} (run 'backup' first)"
    echo "==> Checking ${HOST}:/data is mounted..."
    "${SSH[@]}" "$HOST" "grep -qs ' /data ' /proc/mounts" \
      || die "/data is not mounted on ${HOST} — is this the new (re-laid-out) image?"
    echo "==> Restoring ${BACKUP} -> ${HOST}:/data/"
    "${SSH[@]}" "$HOST" "tar xzf - -C /data" < "$BACKUP" || die "restore failed"
    echo "==> Restart the app so it re-reads the data:"
    echo "    ${SSH[*]} $HOST systemctl restart loopy"
    echo "==> Verify:"
    "$0" verify "$HOST"
    ;;

  verify)
    echo "==> ${HOST}:/data contents:"
    "${SSH[@]}" "$HOST" "grep -qs ' /data ' /proc/mounts && df -h /data | tail -1; ls -la /data 2>/dev/null; echo '--- app dirs ---'; for p in $PATHS; do du -sh \"/data/\$p\" 2>/dev/null || echo \"  (missing) /data/\$p\"; done"
    ;;

  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
