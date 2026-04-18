#!/bin/bash
# scripts/fstab_hardening.sh
# ================================================================
# Hardens /etc/fstab with two security/performance changes:
#
#   1. /dev/shm hardening (noexec, nosuid, nodev)
#      Shared memory is world-accessible RAM. Without these flags
#      an exploited process can use /dev/shm to execute injected
#      code, escalate privileges, or create device files. These
#      mount options block all three attack vectors.
#
#   2. noatime on the root filesystem
#      By default Linux writes the access timestamp (atime) on
#      every file read. On a web server reading hundreds of files
#      per second this generates constant unnecessary I/O. noatime
#      eliminates these writes with zero functional downside.
#
# Both changes are idempotent: the script checks whether each
# entry is already present/configured before modifying fstab.
# fstab is backed up before any modification.
#
# No config file is needed — these are fixed security values with
# no sensible variation between servers.
#
# Writes to: /etc/fstab
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
LOG_FILE="$BASE_DIR/serverforge.log"

FSTAB="/etc/fstab"
FSTAB_BAK="${FSTAB}.bak"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FSTAB] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FSTAB] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$FSTAB" ]; then
    log "ERROR: /etc/fstab not found. Cannot proceed."
    exit 1
fi

separator
log "Starting fstab hardening..."

# Backup fstab before any modifications
if [ ! -f "$FSTAB_BAK" ]; then
    cp "$FSTAB" "$FSTAB_BAK"
    log "fstab backed up to $FSTAB_BAK"
else
    log "Backup already exists at $FSTAB_BAK — skipping backup."
fi

# ── Step 1: Harden /dev/shm ──────────────────────────────────────
log "Step 1/2 — Hardening /dev/shm (noexec, nosuid, nodev)..."

if grep -qE '^\s*none\s+/dev/shm' "$FSTAB" || grep -qE '^\s*tmpfs\s+/dev/shm' "$FSTAB"; then
    log "  /dev/shm entry already exists in fstab."
    # Verify it has the hardened options
    if grep -qE '/dev/shm.*noexec' "$FSTAB"; then
        log "  noexec already present — /dev/shm is already hardened."
    else
        log "  WARN: /dev/shm entry exists but may be missing hardened options."
        log "  Current /dev/shm fstab line:"
        grep '/dev/shm' "$FSTAB" | tee -a "$LOG_FILE"
        log "  Manual review recommended."
    fi
else
    # Append the hardened /dev/shm mount entry
    cat >> "$FSTAB" << 'EOF'

# ServerForge: harden shared memory — prevent code execution and
# privilege escalation via /dev/shm
none /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0
EOF
    log "  /dev/shm hardened mount entry added to fstab."
fi

# Verify the entry applied correctly to the running system
# (This takes effect on reboot; mount --bind confirms it's in fstab)
log "  Current /dev/shm mount:"
mount | grep shm | tee -a "$LOG_FILE"
log "  (hardened options will be enforced after the upcoming reboot)"

# ── Step 2: Add noatime to root filesystem ────────────────────────
log "Step 2/2 — Adding noatime to root filesystem mount..."

# Check whether noatime is already active in fstab
if grep -qE '^\s*[^#].*\s/\s.*noatime' "$FSTAB"; then
    log "  noatime already present on root filesystem entry — skipping."
else
    # Identify the root filesystem fstab line: the one with mount point
    # exactly ' / ' (space-or-tab separated). Use sed to inject noatime
    # into its options field.
    #
    # Handles both common fstab formats:
    #   UUID=...  /  ext4  defaults        0  1
    #   /dev/...  /  ext4  defaults        0  1
    #
    # sed pattern: find a line with ' / ' followed by fstype and options,
    # and replace 'defaults' with 'defaults,noatime' in the options column.
    # If options don't include 'defaults', append ',noatime' directly.

    # Check if the root entry uses 'defaults' in its options
    ROOT_LINE=$(grep -E '^[^#]\S+\s+/\s+\S+\s+' "$FSTAB" | grep -v '/dev/shm' | head -1)

    if [ -z "$ROOT_LINE" ]; then
        log "  WARN: Could not identify root filesystem line in fstab."
        log "  Current fstab:"
        cat "$FSTAB" | tee -a "$LOG_FILE"
        log "  Please add noatime to the root filesystem entry manually."
        log "  Continuing without applying noatime."
    else
        log "  Root filesystem fstab line:"
        echo "  $ROOT_LINE" | tee -a "$LOG_FILE"

        if echo "$ROOT_LINE" | grep -q 'defaults'; then
            # Replace 'defaults' with 'defaults,noatime' on the root line
            # Use a delimiter other than / since paths contain /
            sed -i -E 's|^([^#]\S+\s+/\s+\S+\s+)defaults(\s)|\1defaults,noatime\2|' "$FSTAB"
            log "  noatime added to root filesystem mount options."
        else
            # Options field exists but doesn't use 'defaults' — append noatime
            # This handles cases like 'rw,relatime' → 'rw,relatime,noatime'
            sed -i -E 's|^([^#]\S+\s+/\s+\S+\s+)(\S+)(\s+[0-9]+\s+[0-9]+\s*$)|\1\2,noatime\3|' "$FSTAB"
            log "  noatime appended to existing root filesystem mount options."
        fi

        log "  Updated root filesystem fstab line:"
        grep -E '^[^#]\S+\s+/\s+\S+\s+' "$FSTAB" | grep -v '/dev/shm' | head -1 \
            | tee -a "$LOG_FILE"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "fstab hardening complete."
log "  ✔ /dev/shm  → noexec, nosuid, nodev enforced on next boot"
log "  ✔ Root fs   → noatime on next boot (eliminates atime write I/O)"
log "  Current fstab:"
cat "$FSTAB" | tee -a "$LOG_FILE"
log "  A reboot is required to activate both fstab changes."
