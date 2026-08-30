#!/bin/bash
# main.sh
# ================================================================
# ServerForge — Stage-based server hardening orchestrator.
#
# Installs itself as a systemd one-shot service on first run so
# the setup sequence survives reboots and automatically resumes
# at the correct stage each time the server comes back up.
#
# Stage map:
#   1  →  System Updates           (reboot)
#   2  →  Timezone                 (reboot)
#   3  →  Firewall                 (reboot)
#   4  →  Fail2ban                 (reboot)
#   5  →  Swap                     (reboot)
#   6  →  Kernel Hardening         (reboot)
#   7  →  fstab Hardening          (reboot)
#   8  →  Open File Limits         (reboot)
#   9  →  LEMP Stack Install       (no reboot — falls through)
#   10 →  Nginx Hardening          (no reboot — falls through)
#   11 →  MariaDB Hardening        (no reboot — falls through)
#   12 →  MariaDB Optimization     (no reboot — falls through)
#   13 →  PHP Hardening            (no reboot — falls through)
#   14 →  Site Infrastructure      (no reboot — falls through)
#   15 →  WordPress Install        (no reboot — setup complete)
#
# Requires an existing non-root sudo user with SSH access already
# configured — this pipeline does not create users or harden SSH.
#
# Usage:
#   sudo ./main.sh              # start or resume the sequence
#   sudo ./main.sh --status     # show current stage without running
#   sudo ./main.sh --reset      # delete stage file and restart
# ================================================================

BASE_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"
STATE_FILE="$BASE_DIR/current_stage.txt"

SERVICE_NAME="serverforge"
SERVICE_TEMPLATE="$BASE_DIR/${SERVICE_NAME}.service"
SERVICE_DEST="/etc/systemd/system/${SERVICE_NAME}.service"

TOTAL_STAGES=15

# ── Logging ──────────────────────────────────────────────────────
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MAIN] $1" | tee -a "$LOG_FILE"
}

separator() {
    printf '%s [MAIN] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "════════════════════════════════════════════" \
        | tee -a "$LOG_FILE"
}

# ── CLI flags ─────────────────────────────────────────────────────
if [ "$1" = "--status" ]; then
    if [ -f "$STATE_FILE" ]; then
        echo "ServerForge: currently at stage $(cat "$STATE_FILE") of $TOTAL_STAGES"
    else
        echo "ServerForge: no active run (setup complete or not yet started)"
    fi
    exit 0
fi

if [ "$1" = "--reset" ]; then
    rm -f "$STATE_FILE"
    log "Stage file removed. Run main.sh again to start from Stage 1."
    exit 0
fi

# ── Root check ────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: main.sh must be run as root (use: sudo ./main.sh)"
    exit 1
fi

# ── Config validation ─────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found."
    echo "       Edit configs/server.conf before running main.sh."
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$SERVER_USER" ] || [ "$SERVER_USER" = "<your-username>" ]; then
    echo "ERROR: SERVER_USER is not configured in $CONFIG_FILE"
    echo "       Set it to your existing Linux username (e.g. andrew, admin)."
    exit 1
fi

if ! id "$SERVER_USER" &>/dev/null; then
    echo "ERROR: SERVER_USER '$SERVER_USER' does not exist on this system."
    echo "       This pipeline does not create users — create it first:"
    echo "         adduser $SERVER_USER && usermod -aG sudo $SERVER_USER"
    exit 1
fi

# ── Systemd service management ────────────────────────────────────
install_service() {
    if [ -f "$SERVICE_DEST" ]; then
        return 0
    fi

    if [ ! -f "$SERVICE_TEMPLATE" ]; then
        log "ERROR: Service template not found at $SERVICE_TEMPLATE"
        exit 1
    fi

    log "Installing systemd service for reboot persistence..."

    sed \
        -e "s|<user>|${SERVER_USER}|g" \
        -e "s|ExecStart=.*|ExecStart=/bin/bash ${BASE_DIR}/main.sh|g" \
        "$SERVICE_TEMPLATE" > "$SERVICE_DEST"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1

    log "Service installed : $SERVICE_DEST"
    log "Service enabled   : will auto-run after each reboot until complete."
}

disable_service() {
    systemctl disable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
    rm -f "$SERVICE_DEST"
    systemctl daemon-reload
    log "Service disabled and removed — setup will not run again on reboot."
}

# ── Stage runner ──────────────────────────────────────────────────
# Usage: run_stage <num> <label> <script_path> <reboot_after: yes|no>
run_stage() {
    local num="$1"
    local label="$2"
    local script="$3"
    local reboot_after="$4"

    separator
    log "Stage $num/$TOTAL_STAGES — $label"
    separator

    if [ ! -f "$script" ]; then
        log "ERROR: Script not found: $script"
        exit 1
    fi

    bash "$script"
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log "ERROR: Stage $num ($label) failed (exit $exit_code)."
        log "       Fix the issue and re-run: sudo ./main.sh"
        log "       The stage will retry from here on next run."
        exit 1
    fi

    local next=$(( num + 1 ))
    echo "$next" > "$STATE_FILE"
    log "Stage $num complete."

    if [ "$reboot_after" = "yes" ]; then
        log "Rebooting to apply changes (will resume at Stage $next)..."
        sleep 2
        /usr/sbin/reboot
        exit 0
    fi
}

# ── Initialise stage state ────────────────────────────────────────
if [ ! -f "$STATE_FILE" ]; then
    echo 1 > "$STATE_FILE"
fi

STAGE=$(cat "$STATE_FILE")

separator
log "ServerForge — Resuming at Stage $STAGE of $TOTAL_STAGES"
separator

install_service

# ── Stage dispatch ────────────────────────────────────────────────
case $STAGE in
    1)
        run_stage 1 "System Updates" \
            "$BASE_DIR/scripts/system_updates.sh" "yes"
        ;;

    2)
        run_stage 2 "Timezone" \
            "$BASE_DIR/scripts/timezone.sh" "yes"
        ;;

    3)
        run_stage 3 "Firewall" \
            "$BASE_DIR/scripts/firewall.sh" "yes"
        ;;

    4)
        run_stage 4 "Fail2ban" \
            "$BASE_DIR/scripts/fail2ban.sh" "yes"
        ;;

    5)
        run_stage 5 "Swap" \
            "$BASE_DIR/scripts/swap.sh" "yes"
        ;;

    6)
        run_stage 6 "Kernel Hardening" \
            "$BASE_DIR/scripts/kernel_hardening.sh" "yes"
        ;;

    7)
        run_stage 7 "fstab Hardening" \
            "$BASE_DIR/scripts/fstab_hardening.sh" "yes"
        ;;

    8)
        run_stage 8 "Open File Limits" \
            "$BASE_DIR/scripts/open_file_limits.sh" "yes"
        # Falls through after reboot to Stage 9
        ;;

    9)
        run_stage 9 "LEMP Stack Installation" \
            "$BASE_DIR/scripts/install_lemp.sh" "no"
        # No reboot needed — services start immediately
        STAGE=10
        ;&

    10)
        run_stage 10 "Nginx Hardening & Optimization" \
            "$BASE_DIR/scripts/configure_nginx.sh" "no"
        STAGE=11
        ;&

    11)
        run_stage 11 "MariaDB Hardening" \
            "$BASE_DIR/scripts/harden_mariadb.sh" "no"
        STAGE=12
        ;&

    12)
        run_stage 12 "MariaDB Optimization" \
            "$BASE_DIR/scripts/optimize_mariadb.sh" "no"
        STAGE=13
        ;&

    13)
        run_stage 13 "PHP Hardening & Optimization" \
            "$BASE_DIR/scripts/harden_optimize_php.sh" "no"
        STAGE=14
        ;&

    14)
        run_stage 14 "Site Infrastructure" \
            "$BASE_DIR/scripts/setup_site_infrastructure.sh" "no"
        STAGE=15
        ;&

    15)
        run_stage 15 "WordPress Installation" \
            "$BASE_DIR/scripts/install_wordpress.sh" "no"

        # ── All stages complete ───────────────────────────────────
        rm -f "$STATE_FILE"

        SITE_DOMAIN=""
        SITE_CONF="$BASE_DIR/configs/site.conf"
        [ -f "$SITE_CONF" ] && SITE_DOMAIN=$(grep '^SITE_DOMAIN=' "$SITE_CONF" \
            | cut -d= -f2 | tr -d '"')

        separator
        log "╔══════════════════════════════════════════════╗"
        log "║   ServerForge — All 15 stages complete!      ║"
        log "╚══════════════════════════════════════════════╝"
        log ""
        log "  Stages 1–8   ✔  OS hardening, kernel, limits"
        log "  Stages 9–10  ✔  LEMP stack, Nginx config"
        log "  Stages 11–13 ✔  MariaDB + PHP hardening"
        log "  Stage  14    ✔  Web root + Nginx server block"
        log "  Stage  15    ✔  WordPress files deployed"
        log ""
        log "  Site: http://${SITE_DOMAIN}/"
        log ""
        log "  Remaining manual steps:"
        log "    □ Browser wizard: http://${SITE_DOMAIN}/ (if not done)"
        log ""
        log "  Not configured by this pipeline (trimmed out):"
        log "    · SSH/user hardening — set this up yourself before running"
        log "    · Mail (msmtp) notifications"
        log "    · PHP-FPM per-site pool isolation"
        log "    · SSL / HTTPS"
        log "    · Nginx & WordPress application hardening"
        separator
        disable_service
        ;;

    *)
        log "Unexpected stage value: '$STAGE'"
        log "Setup is already complete or the state file is corrupted."
        log "Run: sudo ./main.sh --reset   to start over."
        ;;
esac
