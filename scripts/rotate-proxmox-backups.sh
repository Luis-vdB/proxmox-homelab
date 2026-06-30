#!/bin/bash
# ---------------------------------------------------------------------------
# Proxmox Config Backup — Tiered Rotation
# Backs up critical host configuration to the isolated vault drive, with
# daily / weekly / biweekly / monthly retention tiers.
# Runs on the Proxmox host via cron, daily at 03:30.
#
# Each tier is a single rolling archive (e.g. daily.tar.gz) that is overwritten
# on its schedule, so the vault holds one of each tier at any time rather than
# an unbounded pile of dated files.
# ---------------------------------------------------------------------------

BACKUP_DIR="/mnt/vault/pve-backups"
mkdir -p "$BACKUP_DIR"

# Date components used to decide which tiers fire on this run
DAY_OF_MONTH=$(date +%d)
DAY_OF_WEEK=$(date +%u)   # 1 = Monday ... 7 = Sunday
MONTH=$(date +%m)
YEAR=$(date +%Y)

# Create one compressed archive of all critical host config under the given name
backup() {
    TARGET_NAME="$1"
    tar --exclude='/root/pve-backups' \
        --exclude='/root/nvidia' \
        --warning=no-file-changed \
        -czf "${BACKUP_DIR}/${TARGET_NAME}.tar.gz" \
        /etc/pve \
        /etc/network/interfaces \
        /etc/ssh/sshd_config \
        /etc/wireguard \
        /root \
        /etc/systemd/network \
        /etc/resolv.conf \
        /etc/hosts \
        /etc/hostname
    echo "✅ $TARGET_NAME backup saved to ${BACKUP_DIR}/${TARGET_NAME}.tar.gz"
}

# === ROTATING BACKUPS ===

# Daily — always runs
backup "daily"

# Weekly — every Monday
if [ "$DAY_OF_WEEK" -eq 1 ]; then
    backup "weekly"
fi

# Biweekly — 1st and 15th of the month
if [ "$DAY_OF_MONTH" -eq 01 ] || [ "$DAY_OF_MONTH" -eq 15 ]; then
    backup "biweekly"
fi

# Monthly — 1st of the month
if [ "$DAY_OF_MONTH" -eq 01 ]; then
    backup "monthly"
fi
