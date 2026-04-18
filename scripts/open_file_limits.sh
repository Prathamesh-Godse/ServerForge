#!/bin/bash
# scripts/open_file_limits.sh
# ================================================================
# Raises the system-wide open file descriptor limits and enables
# PAM to enforce them at login time for all session types.
#
# Why this matters:
#   Every open network socket consumes one file descriptor. The
#   default soft limit of 1024 causes "too many open files" errors
#   under any real web server load. This script raises both hard
#   and soft limits to the value set in configs/limits.conf, then
#   tells PAM to apply those limits to every session — including
#   interactive SSH, cron jobs, and systemd service units.
#
# After this stage each application (Nginx, PHP-FPM, MariaDB)
# still needs LimitNOFILE= set in its own systemd unit file.
# The OS limit is the ceiling; each service must also explicitly
# raise its own internal limit up to it.
#
# Reads from: configs/limits.conf
# Writes to : /etc/security/limits.d/custom_directives.conf
#             /etc/pam.d/common-session
#             /etc/pam.d/common-session-noninteractive
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/limits.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

LIMITS_FILE="/etc/security/limits.d/custom_directives.conf"
PAM_SESSION="/etc/pam.d/common-session"
PAM_NONINTERACTIVE="/etc/pam.d/common-session-noninteractive"
PAM_DIRECTIVE="session required    pam_limits.so"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [LIMITS] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [LIMITS] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$NOFILE_LIMIT" ] || ! [[ "$NOFILE_LIMIT" =~ ^[0-9]+$ ]]; then
    log "ERROR: NOFILE_LIMIT must be a positive integer in $CONFIG_FILE"
    exit 1
fi

separator
log "Starting open file limits configuration..."
log "  NOFILE_LIMIT = $NOFILE_LIMIT"
log "  Current limits (before changes):"
log "    Hard : $(ulimit -Hn)"
log "    Soft : $(ulimit -Sn)"

# ── Step 1: Write limits drop-in file ────────────────────────────
log "Step 1/3 — Writing limits to $LIMITS_FILE..."

cat > "$LIMITS_FILE" << EOF
# ================================================================
# ServerForge — Open File Descriptor Limits
# Managed by: serverforge/scripts/open_file_limits.sh
# ================================================================
# Raises both hard and soft nofile limits for all users and root.
# Values take effect after login (enforced by pam_limits.so).
#
# <domain>    <type>    <item>      <value>
*             soft      nofile      ${NOFILE_LIMIT}
*             hard      nofile      ${NOFILE_LIMIT}
root          soft      nofile      ${NOFILE_LIMIT}
root          hard      nofile      ${NOFILE_LIMIT}
EOF

if [ $? -ne 0 ]; then
    log "ERROR: Failed to write $LIMITS_FILE"
    exit 1
fi
log "  $LIMITS_FILE written."

# ── Step 2: Enable PAM limits — interactive sessions ─────────────
log "Step 2/3 — Enabling pam_limits.so in $PAM_SESSION..."

if [ ! -f "$PAM_SESSION" ]; then
    log "ERROR: $PAM_SESSION not found. PAM may not be installed."
    exit 1
fi

if grep -qF "pam_limits.so" "$PAM_SESSION"; then
    log "  pam_limits.so already present in $PAM_SESSION — skipping."
else
    # Backup before modifying
    cp "$PAM_SESSION" "${PAM_SESSION}.bak"
    echo "" >> "$PAM_SESSION"
    echo "# ServerForge: enforce open file descriptor limits" >> "$PAM_SESSION"
    echo "$PAM_DIRECTIVE" >> "$PAM_SESSION"
    log "  pam_limits.so appended to $PAM_SESSION"
fi

# ── Step 3: Enable PAM limits — non-interactive sessions ─────────
# Covers cron jobs, scripts, and systemd service units that don't
# go through a login shell — they would otherwise inherit the
# default low limits instead of the values set in limits.d/.
log "Step 3/3 — Enabling pam_limits.so in $PAM_NONINTERACTIVE..."

if [ ! -f "$PAM_NONINTERACTIVE" ]; then
    log "ERROR: $PAM_NONINTERACTIVE not found."
    exit 1
fi

if grep -qF "pam_limits.so" "$PAM_NONINTERACTIVE"; then
    log "  pam_limits.so already present in $PAM_NONINTERACTIVE — skipping."
else
    cp "$PAM_NONINTERACTIVE" "${PAM_NONINTERACTIVE}.bak"
    echo "" >> "$PAM_NONINTERACTIVE"
    echo "# ServerForge: enforce open file descriptor limits" >> "$PAM_NONINTERACTIVE"
    echo "$PAM_DIRECTIVE" >> "$PAM_NONINTERACTIVE"
    log "  pam_limits.so appended to $PAM_NONINTERACTIVE"
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "Open file limits configuration complete."
log "  ✔ Limits file    → $LIMITS_FILE"
log "  ✔ nofile limit   → $NOFILE_LIMIT (hard + soft, all users)"
log "  ✔ PAM session    → pam_limits.so enabled"
log "  ✔ PAM non-interactive → pam_limits.so enabled"
log ""
log "  After the upcoming reboot, verify with:"
log "    ulimit -Hn   # should return $NOFILE_LIMIT"
log "    ulimit -Sn   # should return $NOFILE_LIMIT"
