#!/bin/bash
# scripts/fail2ban.sh
# ================================================================
# Downloads, installs, and configures Fail2ban for SSH brute-force
# protection. Uses the official GitHub .deb release to ensure the
# latest stable version rather than the Ubuntu repo version.
#
# Configuration applied:
#   - Global ban/find/retry tuning from server.conf
#   - SSH jail enabled in aggressive mode
#
# Reads from: configs/server.conf (FAIL2BAN_* variables)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

FAIL2BAN_VERSION="1.1.0"
FAIL2BAN_DEB_URL="https://github.com/fail2ban/fail2ban/releases/download/${FAIL2BAN_VERSION}/fail2ban_${FAIL2BAN_VERSION}-1.upstream1_all.deb"
FAIL2BAN_DEB="/tmp/fail2ban.deb"
JAIL_LOCAL="/etc/fail2ban/jail.local"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL2BAN] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL2BAN] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

separator
log "Starting Fail2ban installation and configuration..."
log "  Version    : $FAIL2BAN_VERSION"
log "  Ban time   : $FAIL2BAN_BANTIME"
log "  Find time  : $FAIL2BAN_FINDTIME"
log "  Max retries: $FAIL2BAN_MAXRETRY"

# ── Step 1: Download the .deb package ────────────────────────────
if dpkg -s fail2ban &>/dev/null; then
    log "Fail2ban is already installed — skipping download and install."
else
    log "Downloading Fail2ban ${FAIL2BAN_VERSION}..."
    wget -q -O "$FAIL2BAN_DEB" "$FAIL2BAN_DEB_URL" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ] || [ ! -s "$FAIL2BAN_DEB" ]; then
        log "ERROR: Download failed. Check network connectivity."
        log "       URL: $FAIL2BAN_DEB_URL"
        rm -f "$FAIL2BAN_DEB"
        exit 1
    fi
    log "Download complete: $(du -sh "$FAIL2BAN_DEB" | cut -f1)"

    # ── Step 2: Install the package ──────────────────────────────
    log "Installing Fail2ban package..."
    dpkg -i "$FAIL2BAN_DEB" >> "$LOG_FILE" 2>&1
    apt -f install -y >> "$LOG_FILE" 2>&1

    if ! dpkg -s fail2ban &>/dev/null; then
        log "ERROR: Fail2ban installation failed."
        rm -f "$FAIL2BAN_DEB"
        exit 1
    fi

    rm -f "$FAIL2BAN_DEB"
    log "Fail2ban installed successfully."
fi

# ── Step 3: Write jail.local from scratch ─────────────────────────
# jail.local is the user override layer. It is merged on top of
# jail.conf by Fail2ban at startup — so it only needs to contain
# our overrides, not a full copy of jail.conf.
#
# IMPORTANT: Do NOT copy jail.conf → jail.local. jail.conf already
# contains an [sshd] section. Copying it and then appending our own
# [sshd] block creates a duplicate section, which causes Fail2ban to
# fail with "section 'sshd' already exists". Write jail.local fresh.
log "Writing jail.local (minimal override file)..."

cat > "$JAIL_LOCAL" << EOF
# /etc/fail2ban/jail.local
# Managed by serverforge/scripts/fail2ban.sh — do not edit manually.
# This file is layered on top of jail.conf; only overrides live here.

[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}

# [ServerForge] sshd jail — managed by serverforge/scripts/fail2ban.sh
[sshd]
mode     = aggressive
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
enabled  = true
EOF

log "jail.local written."
log "  bantime  → $FAIL2BAN_BANTIME"
log "  findtime → $FAIL2BAN_FINDTIME"
log "  maxretry → $FAIL2BAN_MAXRETRY"
log "  sshd     → aggressive mode, enabled"

# ── Step 4: Restart and verify ────────────────────────────────────
log "Restarting Fail2ban service..."
systemctl restart fail2ban >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: Fail2ban failed to restart. Check: journalctl -xeu fail2ban"
    exit 1
fi

# Give the daemon a moment to fully initialise
sleep 2

separator
log "Fail2ban service status:"
systemctl status fail2ban --no-pager 2>&1 | tee -a "$LOG_FILE"

log "SSH jail status:"
fail2ban-client status sshd 2>&1 | tee -a "$LOG_FILE"

log "Fail2ban configuration complete."
log "  ✔ SSH jail  → enabled (aggressive mode)"
log "  ✔ Ban time  → $FAIL2BAN_BANTIME"
log "  ✔ Find time → $FAIL2BAN_FINDTIME"
log "  ✔ Max retry → $FAIL2BAN_MAXRETRY"
