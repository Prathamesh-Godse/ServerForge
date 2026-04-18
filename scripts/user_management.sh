#!/bin/bash
# scripts/user_management.sh
# ================================================================
# Creates a non-root sudo user, removes pre-existing cloud
# provider default accounts, and optionally installs an SSH
# public key for the new user.
#
# Reads from: configs/users.conf
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/users.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [USER_MGMT] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [USER_MGMT] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$SERVER_USER" ] || [ "$SERVER_USER" = "<your-username>" ]; then
    log "ERROR: SERVER_USER is not set in $CONFIG_FILE"
    exit 1
fi

if [ -z "$USER_PASSWORD" ] || [ "$USER_PASSWORD" = "<strong-password-here>" ]; then
    log "ERROR: USER_PASSWORD is not set in $CONFIG_FILE"
    exit 1
fi

separator
log "Starting user management..."

# ── Step 1: Create the non-root user ─────────────────────────────
if id "$SERVER_USER" &>/dev/null; then
    log "User '$SERVER_USER' already exists — skipping creation."
else
    log "Creating user: $SERVER_USER"
    # --disabled-password: creates account without an interactive password prompt
    # --gecos "": skips the Full Name / Room Number interactive fields
    adduser --disabled-password --gecos "" "$SERVER_USER" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        log "ERROR: Failed to create user '$SERVER_USER'."
        exit 1
    fi
    log "User '$SERVER_USER' created successfully."
fi

# ── Step 2: Set the user's password ──────────────────────────────
log "Setting password for user: $SERVER_USER"
echo "${SERVER_USER}:${USER_PASSWORD}" | chpasswd >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: Failed to set password for '$SERVER_USER'."
    exit 1
fi
log "Password set successfully."

# ── Step 3: Grant sudo privileges ────────────────────────────────
# Write a drop-in sudoers file instead of editing /etc/sudoers directly.
# This is safer — a syntax error here won't break the whole sudoers system.
SUDOERS_FILE="/etc/sudoers.d/${SERVER_USER}"

if [ -f "$SUDOERS_FILE" ]; then
    log "Sudoers entry for '$SERVER_USER' already exists — skipping."
else
    log "Granting sudo privileges to: $SERVER_USER"
    echo "${SERVER_USER} ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    # Validate the sudoers drop-in before proceeding
    visudo -cf "$SUDOERS_FILE" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: Sudoers file syntax check failed. Removing invalid file."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
    log "Sudo privileges granted via $SUDOERS_FILE"
fi

# ── Step 4: Install SSH public key (optional) ─────────────────────
if [ -n "$SSH_PUBLIC_KEY" ]; then
    SSH_DIR="/home/${SERVER_USER}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    log "Setting up SSH authorized_keys for: $SERVER_USER"
    mkdir -p "$SSH_DIR"

    # Append only if the key is not already present
    if grep -qsF "$SSH_PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null; then
        log "SSH public key already present in authorized_keys — skipping."
    else
        echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
        log "SSH public key added to $AUTH_KEYS"
    fi

    # Enforce correct ownership and permissions
    chown -R "${SERVER_USER}:${SERVER_USER}" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
    log "Permissions set: $SSH_DIR (700), $AUTH_KEYS (600)"
else
    log "SSH_PUBLIC_KEY not set — skipping authorized_keys setup."
    log "  → Add your public key to ~/.ssh/authorized_keys manually before"
    log "    password auth is disabled in the SSH Hardening stage."
fi

# ── Step 5: Remove pre-existing cloud default users ───────────────
if [ -n "$REMOVE_USERS" ]; then
    log "Removing pre-existing cloud default users: $REMOVE_USERS"
    for user in $REMOVE_USERS; do
        # Never remove the newly created admin user
        if [ "$user" = "$SERVER_USER" ]; then
            log "WARN: Skipping removal of '$user' — this is the configured SERVER_USER."
            continue
        fi

        if id "$user" &>/dev/null; then
            log "Removing user: $user (with home directory)"
            deluser "$user" --remove-home >> "$LOG_FILE" 2>&1
            if [ $? -eq 0 ]; then
                log "User '$user' removed."
            else
                log "WARN: Could not remove '$user' — may already be in use. Skipping."
            fi
        else
            log "User '$user' does not exist — skipping."
        fi
    done
else
    log "REMOVE_USERS is empty — no default users to remove."
fi

# ── Step 6: Verify final state ────────────────────────────────────
separator
log "Users with home directories in /home:"
ls /home | tee -a "$LOG_FILE"

log "Sudo privileges for $SERVER_USER:"
cat "$SUDOERS_FILE" 2>/dev/null | tee -a "$LOG_FILE"

log "User management complete."
