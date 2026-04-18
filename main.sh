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
#   1  →  User Management          (no reboot — falls through to Stage 2)
#   2  →  SSH Hardening            (reboot)
#   3  →  System Updates           (reboot)
#   4  →  Timezone                 (reboot)
#   5  →  Firewall                 (reboot)
#   6  →  Fail2ban                 (reboot)
#   7  →  Swap                     (reboot)
#   8  →  Kernel Hardening         (reboot)
#   9  →  fstab Hardening          (reboot)
#   10 →  Open File Limits         (reboot)
#   11 →  LEMP Stack Install       (no reboot — falls through)
#   12 →  Mail / msmtp             (no reboot — falls through)
#   13 →  Nginx Hardening          (no reboot — falls through)
#   14 →  MariaDB Hardening        (no reboot — falls through)
#   15 →  MariaDB Optimization     (no reboot — falls through)
#   16 →  PHP Hardening            (no reboot — falls through)
#   17 →  Site Infrastructure      (no reboot — falls through)
#   18 →  WordPress Install        (no reboot — falls through)
#   19 →  PHP-FPM Pool             (no reboot — falls through)
#   20 →  WordPress Hardening      (no reboot — falls through)
#   21 →  SSL / HTTPS              (no reboot — falls through)
#   22 →  Nginx App Hardening      (no reboot — falls through)
#   23 →  WordPress App Hardening  (no reboot — setup complete)
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

TOTAL_STAGES=23

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
    echo "       Set it to your Linux username (e.g. andrew, admin)."
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
        run_stage 1 "User Management" \
            "$BASE_DIR/scripts/user_management.sh" "no"
        # Fall through immediately to Stage 2 (no reboot needed here)
        STAGE=2
        ;&

    2)
        run_stage 2 "SSH Hardening" \
            "$BASE_DIR/scripts/ssh_hardening.sh" "yes"
        ;;

    3)
        run_stage 3 "System Updates" \
            "$BASE_DIR/scripts/system_updates.sh" "yes"
        ;;

    4)
        run_stage 4 "Timezone" \
            "$BASE_DIR/scripts/timezone.sh" "yes"
        ;;

    5)
        run_stage 5 "Firewall" \
            "$BASE_DIR/scripts/firewall.sh" "yes"
        ;;

    6)
        run_stage 6 "Fail2ban" \
            "$BASE_DIR/scripts/fail2ban.sh" "yes"
        ;;

    7)
        run_stage 7 "Swap" \
            "$BASE_DIR/scripts/swap.sh" "yes"
        ;;

    8)
        run_stage 8 "Kernel Hardening" \
            "$BASE_DIR/scripts/kernel_hardening.sh" "yes"
        ;;

    9)
        run_stage 9 "fstab Hardening" \
            "$BASE_DIR/scripts/fstab_hardening.sh" "yes"
        ;;

    10)
        run_stage 10 "Open File Limits" \
            "$BASE_DIR/scripts/open_file_limits.sh" "yes"
        # Falls through after reboot to Stage 11
        ;;

    11)
        run_stage 11 "LEMP Stack Installation" \
            "$BASE_DIR/scripts/install_lemp.sh" "no"
        # No reboot needed — services start immediately
        STAGE=12
        ;&

    12)
        run_stage 12 "Mail (msmtp)" \
            "$BASE_DIR/scripts/configure_mail.sh" "no"
        # No reboot needed — file writes only
        STAGE=13
        ;&

    13)
        run_stage 13 "Nginx Hardening & Optimization" \
            "$BASE_DIR/scripts/configure_nginx.sh" "no"
        STAGE=14
        ;&

    14)
        run_stage 14 "MariaDB Hardening" \
            "$BASE_DIR/scripts/harden_mariadb.sh" "no"
        STAGE=15
        ;&

    15)
        run_stage 15 "MariaDB Optimization" \
            "$BASE_DIR/scripts/optimize_mariadb.sh" "no"
        STAGE=16
        ;&

    16)
        run_stage 16 "PHP Hardening & Optimization" \
            "$BASE_DIR/scripts/harden_optimize_php.sh" "no"
        STAGE=17
        ;&

    17)
        run_stage 17 "Site Infrastructure" \
            "$BASE_DIR/scripts/setup_site_infrastructure.sh" "no"
        STAGE=18
        ;&

    18)
        run_stage 18 "WordPress Installation" \
            "$BASE_DIR/scripts/install_wordpress.sh" "no"
        STAGE=19
        ;&

    19)
        run_stage 19 "PHP-FPM Pool Isolation" \
            "$BASE_DIR/scripts/configure_php_pool.sh" "no"
        STAGE=20
        ;&

    20)
        run_stage 20 "WordPress Hardening" \
            "$BASE_DIR/scripts/harden_wordpress.sh" "no"
        STAGE=21
        ;&

    21)
        run_stage 21 "SSL / HTTPS" \
            "$BASE_DIR/scripts/configure_ssl.sh" "no"
        STAGE=22
        ;&

    22)
        run_stage 22 "Nginx Application Hardening" \
            "$BASE_DIR/scripts/nginx_application_hardening.sh" "no"
        STAGE=23
        ;&

    23)
        run_stage 23 "WordPress Application Hardening" \
            "$BASE_DIR/scripts/wordpress_application_hardening.sh" "no"

        # ── All stages complete ───────────────────────────────────
        rm -f "$STATE_FILE"

        SITE_DOMAIN=""
        SITE_CONF="$BASE_DIR/configs/site.conf"
        [ -f "$SITE_CONF" ] && SITE_DOMAIN=$(grep '^SITE_DOMAIN=' "$SITE_CONF" \
            | cut -d= -f2 | tr -d '"')

        POOL_USER=$(echo "$SITE_DOMAIN" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')

        separator
        log "╔══════════════════════════════════════════════╗"
        log "║   ServerForge — All 23 stages complete!      ║"
        log "╚══════════════════════════════════════════════╝"
        log ""
        log "  Stages 1–10  ✔  OS hardening, kernel, limits"
        log "  Stages 11–13 ✔  LEMP stack, mail, Nginx config"
        log "  Stages 14–16 ✔  MariaDB + PHP hardening"
        log "  Stage  17    ✔  Web root + Nginx server block"
        log "  Stage  18    ✔  WordPress files deployed"
        log "  Stage  19    ✔  PHP-FPM pool: $POOL_USER"
        log "  Stage  20    ✔  WordPress hardened (ownership, perms, open_basedir)"
        log "  Stage  21    ✔  HTTPS + HTTP/3 + renewal cron"
        log "  Stage  22    ✔  Nginx app hardening (headers, WAF, rate limiting)"
        log "  Stage  23    ✔  WordPress app hardening (DISALLOW_FILE_MODS, DB perms)"
        log ""
        log "  Site: https://${SITE_DOMAIN}/"
        log ""
        log "  Remaining manual steps:"
        log "    □ Browser wizard: http://${SITE_DOMAIN}/ (if not done)"
        log "    □ REST API plugin: WP Admin → Plugins → Add New"
        log "      Search: 'Disable REST API' by Dave McHale"
        log "    □ Hotlinking (Cloudflare): Scrape Shield → Hotlink Protection → ON"
        log "    □ SSL check: https://www.ssllabs.com/ssltest/?d=${SITE_DOMAIN}"
        log "    □ Headers: https://securityheaders.com/?q=${SITE_DOMAIN}"
        separator
        disable_service
        ;;

    *)
        log "Unexpected stage value: '$STAGE'"
        log "Setup is already complete or the state file is corrupted."
        log "Run: sudo ./main.sh --reset   to start over."
        ;;
esac
