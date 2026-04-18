#!/bin/bash
# scripts/system_updates.sh
# ================================================================
# Applies all pending system package updates and cleans up
# obsolete dependencies. A reboot is performed after this stage
# so any upgraded kernel takes effect immediately.
#
# Steps:
#   1. Refresh the APT package index (apt update)
#   2. Upgrade all installed packages (apt upgrade)
#   3. Remove orphaned/unused dependencies (apt autoremove)
#
# No separate config file is needed — this stage has no
# user-configurable parameters beyond running the commands.
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SYS_UPDATE] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SYS_UPDATE] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# Suppress interactive prompts from apt/dpkg.
# DEBIAN_FRONTEND=noninteractive keeps the running kernel's config files
# if a package update (e.g. openssh-server) would overwrite them.
export DEBIAN_FRONTEND=noninteractive

separator
log "Starting system updates..."

# ── Step 1: Refresh the package index ────────────────────────────
log "Step 1/3 — Refreshing APT package index..."
apt update >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: apt update failed. Check network connectivity and APT sources."
    exit 1
fi
log "Package index refreshed."

# ── Step 2: Upgrade all installed packages ────────────────────────
log "Step 2/3 — Upgrading installed packages..."

# -y:             auto-confirm
# -o Dpkg::Options: keep existing config files if a package offers to
#                   overwrite them (critical for sshd_config protection)
apt upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: apt upgrade failed. Check the log for details."
    exit 1
fi
log "Package upgrade complete."

# ── Step 3: Remove obsolete packages ─────────────────────────────
log "Step 3/3 — Removing orphaned/unused packages..."
apt autoremove -y >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "WARN: apt autoremove encountered an issue. Non-critical — continuing."
fi
log "Autoremove complete."

# ── Summary ───────────────────────────────────────────────────────
separator
log "System update complete."
log "Running kernel : $(uname -r)"
log "A reboot will follow to load any newly installed kernel."
