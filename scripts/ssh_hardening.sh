#!/bin/bash
# scripts/ssh_hardening.sh
# ================================================================
# Hardens the SSH daemon by:
#   1. Disabling root login in both sshd_config and the cloud
#      provider's drop-in override (50-cloud-init.conf)
#   2. Disabling password authentication (forces key-only login)
#   3. Restarting the SSH daemon to apply changes
#
# ⚠  WARNING: Ensure SSH key auth works BEFORE disabling passwords.
#             If SSH_PUBLIC_KEY was not set in users.conf, add your
#             public key to ~/.ssh/authorized_keys manually first.
#
# Reads from: configs/ssh.conf
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/ssh.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

SSHD_CONFIG="/etc/ssh/sshd_config"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SSH_HARDEN] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SSH_HARDEN] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

separator
log "Starting SSH hardening..."
log "  PERMIT_ROOT_LOGIN  = $PERMIT_ROOT_LOGIN"
log "  PASSWORD_AUTH      = $PASSWORD_AUTH"
log "  SSH_DROPIN_FILE    = $SSH_DROPIN_FILE"

# ── Helper: apply or add a directive in a config file ────────────
# Usage: set_directive <file> <key> <value>
set_directive() {
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^\s*${key}\s+" "$file" 2>/dev/null; then
        # Key exists — update it in-place (handles leading whitespace)
        sed -i "s|^\(\s*\)${key}\s.*|\1${key} ${value}|" "$file"
        log "  Updated in $file: ${key} → ${value}"
    else
        # Key absent — append it
        echo "${key} ${value}" >> "$file"
        log "  Appended to $file: ${key} ${value}"
    fi
}

# ── Step 1: Harden the main sshd_config ──────────────────────────
log "Editing main SSH config: $SSHD_CONFIG"

# Back up before touching
if [ ! -f "${SSHD_CONFIG}.bak" ]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
    log "  Backup created: ${SSHD_CONFIG}.bak"
fi

set_directive "$SSHD_CONFIG" "PermitRootLogin" "$PERMIT_ROOT_LOGIN"

# ── Step 2: Harden the cloud-init drop-in (takes precedence) ─────
if [ -f "$SSH_DROPIN_FILE" ]; then
    log "Editing cloud-init drop-in: $SSH_DROPIN_FILE"

    if [ ! -f "${SSH_DROPIN_FILE}.bak" ]; then
        cp "$SSH_DROPIN_FILE" "${SSH_DROPIN_FILE}.bak"
        log "  Backup created: ${SSH_DROPIN_FILE}.bak"
    fi

    set_directive "$SSH_DROPIN_FILE" "PermitRootLogin"        "$PERMIT_ROOT_LOGIN"
    set_directive "$SSH_DROPIN_FILE" "PasswordAuthentication" "$PASSWORD_AUTH"
else
    # Drop-in doesn't exist — apply the password auth directive to main config
    log "Drop-in file not found at $SSH_DROPIN_FILE"
    log "Applying PasswordAuthentication directly to $SSHD_CONFIG"
    set_directive "$SSHD_CONFIG" "PasswordAuthentication" "$PASSWORD_AUTH"
fi

# ── Step 3: Validate SSH config before restarting ─────────────────
log "Validating SSH configuration..."
sshd -t >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: SSH config validation failed. Restoring backups."
    [ -f "${SSHD_CONFIG}.bak" ]    && cp "${SSHD_CONFIG}.bak"    "$SSHD_CONFIG"
    [ -f "${SSH_DROPIN_FILE}.bak" ] && cp "${SSH_DROPIN_FILE}.bak" "$SSH_DROPIN_FILE"
    exit 1
fi
log "SSH config validation passed."

# ── Step 4: Restart the SSH daemon ───────────────────────────────
log "Restarting SSH daemon..."
systemctl restart ssh >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: Failed to restart SSH daemon."
    exit 1
fi
log "SSH daemon restarted successfully."

# ── Step 5: Verify final state ────────────────────────────────────
separator
log "Current effective SSH settings:"

log "  From $SSHD_CONFIG:"
grep -E "^\s*(PermitRootLogin|PasswordAuthentication)" "$SSHD_CONFIG" \
    | tee -a "$LOG_FILE"

if [ -f "$SSH_DROPIN_FILE" ]; then
    log "  From $SSH_DROPIN_FILE (takes precedence):"
    cat "$SSH_DROPIN_FILE" | tee -a "$LOG_FILE"
fi

log "SSH hardening complete."
log "  ✔ Root login: $PERMIT_ROOT_LOGIN"
log "  ✔ Password authentication: $PASSWORD_AUTH"
