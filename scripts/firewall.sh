#!/bin/bash
# scripts/firewall.sh
# ================================================================
# Configures UFW firewall rules from configs/firewall.conf.
# Handles both scenarios:
#   - UFW pre-enabled by the cloud host (adds rules on top)
#   - UFW not yet enabled (full setup from scratch)
#
# Port 22 (SSH) is always protected — the script aborts if SSH
# is not present in the ALLOW list to prevent lockout.
#
# Reads from: configs/firewall.conf
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/firewall.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FIREWALL] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [FIREWALL] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Firewall config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Safety guard: SSH must be in the ALLOW list
if ! echo "$ALLOW" | grep -qiE '(^|,)\s*(ssh|22)\s*(,|$)'; then
    log "ERROR: 'ssh' or port 22 is not in the ALLOW list."
    log "       Add 'ssh' to ALLOW in configs/firewall.conf to prevent lockout."
    exit 1
fi

separator
log "Starting firewall configuration..."

# ── Ensure UFW is installed ───────────────────────────────────────
if ! command -v ufw &>/dev/null; then
    log "UFW not found. Installing..."
    apt update -qq >> "$LOG_FILE" 2>&1
    apt install -y ufw >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to install UFW."
        exit 1
    fi
    log "UFW installed."
fi

# ── Reset to a clean slate ────────────────────────────────────────
log "Resetting UFW rules to defaults..."
ufw --force reset >> "$LOG_FILE" 2>&1

# ── Apply default policies ────────────────────────────────────────
log "Setting default policies: incoming=$DEFAULT_INCOMING, outgoing=$DEFAULT_OUTGOING"
ufw default "$DEFAULT_INCOMING" incoming >> "$LOG_FILE" 2>&1
ufw default "$DEFAULT_OUTGOING" outgoing >> "$LOG_FILE" 2>&1

# ── Allow specified ports/services ───────────────────────────────
IFS=',' read -ra ALLOW_PORTS <<< "$ALLOW"
for port in "${ALLOW_PORTS[@]}"; do
    port="$(echo "$port" | tr -d ' ')"
    [ -z "$port" ] && continue
    log "Allowing: $port"
    ufw allow "$port" >> "$LOG_FILE" 2>&1
done

# ── Deny specified ports ──────────────────────────────────────────
IFS=',' read -ra DENY_PORTS <<< "$DENY"
for port in "${DENY_PORTS[@]}"; do
    port="$(echo "$port" | tr -d ' ')"
    [ -z "$port" ] && continue
    log "Denying: $port"
    ufw deny "$port" >> "$LOG_FILE" 2>&1
done

# ── ICMP / ping ───────────────────────────────────────────────────
if [ "$ALLOW_PING" = "no" ]; then
    log "Disabling ICMP ping..."
    ufw deny proto icmp >> "$LOG_FILE" 2>&1
else
    log "Ping (ICMP) is allowed."
fi

# ── Enable the firewall ───────────────────────────────────────────
log "Enabling UFW..."
ufw --force enable >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: Failed to enable UFW."
    exit 1
fi

# ── Verify final state ────────────────────────────────────────────
separator
log "Firewall status:"
ufw status verbose 2>&1 | tee -a "$LOG_FILE"

log "Firewall configuration complete."
log "  ✔ Allowed : $ALLOW"
log "  ✔ Denied  : $DENY"
log "  ✔ Ping    : $ALLOW_PING"
