#!/bin/bash
# scripts/timezone.sh
# ================================================================
# Sets the server system timezone from configs/server.conf.
# Validates the timezone string exists on this system before
# applying, and logs the before/after state.
#
# Reads from: configs/server.conf (TIMEZONE)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [TIMEZONE] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [TIMEZONE] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$TIMEZONE" ]; then
    log "ERROR: TIMEZONE is not set in $CONFIG_FILE"
    exit 1
fi

separator
log "Starting timezone configuration..."
log "Requested timezone: $TIMEZONE"
log "Current timezone  : $(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')"

# ── Validate timezone ─────────────────────────────────────────────
if ! timedatectl list-timezones | grep -qx "$TIMEZONE"; then
    log "ERROR: '$TIMEZONE' is not a valid timezone."
    log "       Run: timedatectl list-timezones | grep <Region>"
    exit 1
fi

# ── Apply timezone ────────────────────────────────────────────────
log "Applying timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: timedatectl set-timezone failed."
    exit 1
fi

# ── Verify ────────────────────────────────────────────────────────
separator
log "Timezone applied. Current system time:"
timedatectl | tee -a "$LOG_FILE"

log "Timezone configuration complete."
log "  ✔ Timezone → $TIMEZONE"
