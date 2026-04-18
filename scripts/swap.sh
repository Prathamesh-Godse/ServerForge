#!/bin/bash
# scripts/swap.sh
# ================================================================
# Creates a swap file on the root filesystem, sets secure
# permissions, formats it, activates it, and registers it in
# /etc/fstab so it persists across reboots.
#
# Idempotent: if a swap file already exists at SWAP_PATH AND is
# already listed in /etc/fstab, the script skips creation and
# logs the current state instead.
#
# Reads from: configs/swap.conf
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/swap.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SWAP] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SWAP] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$SWAP_PATH" ]; then
    log "ERROR: SWAP_PATH is not set in $CONFIG_FILE"
    exit 1
fi

if [ -z "$SWAP_SIZE_MB" ] || ! [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]]; then
    log "ERROR: SWAP_SIZE_MB must be a positive integer in $CONFIG_FILE"
    exit 1
fi

separator
log "Starting swap file setup..."
log "  Path : $SWAP_PATH"
log "  Size : ${SWAP_SIZE_MB} MB"

# ── Check for existing swap ───────────────────────────────────────
SWAP_IN_FSTAB=$(grep -s "^${SWAP_PATH}" /etc/fstab)
SWAP_FILE_EXISTS=0
[ -f "$SWAP_PATH" ] && SWAP_FILE_EXISTS=1

if [ $SWAP_FILE_EXISTS -eq 1 ] && [ -n "$SWAP_IN_FSTAB" ]; then
    log "Swap file already exists at $SWAP_PATH and is registered in /etc/fstab."
    log "Current swap status:"
    swapon -s | tee -a "$LOG_FILE"
    log "Swap setup already complete — skipping."
    exit 0
fi

# ── Remove stale swap if file exists but fstab is missing ─────────
if [ $SWAP_FILE_EXISTS -eq 1 ] && [ -z "$SWAP_IN_FSTAB" ]; then
    log "Swap file exists but is not in fstab. Deactivating and removing..."
    swapoff "$SWAP_PATH" 2>/dev/null
    rm -f "$SWAP_PATH"
    log "Stale swap file removed."
fi

# ── Step 1: Create the swap file ──────────────────────────────────
BYTE_COUNT=$(( SWAP_SIZE_MB * 1024 ))
log "Step 1/5 — Creating ${SWAP_SIZE_MB} MB swap file at $SWAP_PATH..."
log "  (this may take a moment for large sizes)"

dd if=/dev/zero of="$SWAP_PATH" bs=1024 count="$BYTE_COUNT" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ] || [ ! -f "$SWAP_PATH" ]; then
    log "ERROR: Failed to create swap file. Check available disk space."
    df -h / | tee -a "$LOG_FILE"
    exit 1
fi
log "Swap file created: $(du -sh "$SWAP_PATH" | cut -f1)"

# ── Step 2: Set secure permissions ───────────────────────────────
log "Step 2/5 — Setting permissions to 600 (root-only)..."
chmod 600 "$SWAP_PATH"
log "Permissions set: $(stat -c '%a' "$SWAP_PATH")"

# ── Step 3: Format as swap ────────────────────────────────────────
log "Step 3/5 — Formatting as swap space..."
mkswap "$SWAP_PATH" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: mkswap failed."
    exit 1
fi
log "Swap area formatted."

# ── Step 4: Activate swap ────────────────────────────────────────
log "Step 4/5 — Activating swap..."
swapon "$SWAP_PATH" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: swapon failed."
    exit 1
fi

log "Swap active:"
swapon -s | tee -a "$LOG_FILE"

# ── Step 5: Register in /etc/fstab ───────────────────────────────
log "Step 5/5 — Registering swap in /etc/fstab..."

# Backup fstab before touching it
if [ ! -f /etc/fstab.bak ]; then
    cp /etc/fstab /etc/fstab.bak
    log "fstab backed up to /etc/fstab.bak"
fi

# Only append if not already present (guard against partial runs)
if ! grep -q "^${SWAP_PATH}" /etc/fstab; then
    echo "" >> /etc/fstab
    echo "# ServerForge: swap file" >> /etc/fstab
    echo "${SWAP_PATH} swap swap defaults 0 0" >> /etc/fstab
    log "fstab entry added: ${SWAP_PATH} swap swap defaults 0 0"
else
    log "fstab already contains an entry for $SWAP_PATH — skipping append."
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "Swap file setup complete."
log "  ✔ Path        : $SWAP_PATH"
log "  ✔ Size        : ${SWAP_SIZE_MB} MB"
log "  ✔ Permissions : 600"
log "  ✔ fstab       : registered"
log "  A reboot will verify the swap file activates automatically on startup."
