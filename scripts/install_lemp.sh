#!/bin/bash
# scripts/install_lemp.sh
# ================================================================
# Installs the full LEMP stack:
#   L — Linux (already running)
#   E — Nginx (from Ondrej PPA, with required modules)
#   M — MariaDB (from official Ubuntu repos)
#   P — PHP-FPM 8.3 (from Ondrej PPA, with all WordPress extensions)
#
# Also fixes the post-install IPv6 socket failure in the default
# Nginx vhost — required when IPv6 was disabled in Stage 8.
#
# All three services are enabled to start on boot and their status
# is verified before the stage is marked complete.
#
# Reads from: configs/lemp.conf
#             configs/server.conf (for SERVER_USER)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/lemp.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

NGINX_DEFAULT_VHOST="/etc/nginx/sites-available/default"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [LEMP] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [LEMP] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
for conf in "$CONFIG_FILE" "$SERVER_CONF"; do
    if [ ! -f "$conf" ]; then
        log "ERROR: Config not found: $conf"
        exit 1
    fi
done

source "$CONFIG_FILE"
source "$SERVER_CONF"

export DEBIAN_FRONTEND=noninteractive

separator
log "Starting LEMP stack installation..."
log "  Nginx PPA  : $NGINX_PPA"
log "  PHP version: $PHP_VERSION"
log "  PHP PPA    : $PHP_PPA"

# ── Step 1: Refresh package index ────────────────────────────────
log "Step 1/9 — Refreshing package index..."
apt update -qq >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: apt update failed."
    exit 1
fi
log "Package index refreshed."

# ── Step 2: Add Nginx PPA ─────────────────────────────────────────
log "Step 2/9 — Adding Nginx PPA: $NGINX_PPA"
if grep -rq "ondrej/nginx" /etc/apt/sources.list.d/ 2>/dev/null; then
    log "  Nginx PPA already present — skipping add."
else
    add-apt-repository -y "$NGINX_PPA" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to add Nginx PPA."
        exit 1
    fi
    apt update -qq >> "$LOG_FILE" 2>&1
    log "  Nginx PPA added and package index refreshed."
fi

# ── Step 3: Install Nginx and modules ────────────────────────────
log "Step 3/9 — Installing Nginx and modules..."
log "  Modules: $NGINX_MODULES"

apt install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nginx $NGINX_MODULES >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: Nginx installation failed."
    exit 1
fi
log "  Nginx installed: $(nginx -v 2>&1)"

# ── Step 4: Fix IPv6 socket error in default vhost ───────────────
# When IPv6 was disabled in Stage 8 via GRUB, the default Nginx
# vhost still contains `listen [::]:80` which causes nginx to fail
# on startup with: "socket() [::]:80 failed (97: Address family
# not supported)". Comment out the IPv6 listen directive.
log "Step 4/9 — Patching default vhost for disabled IPv6..."

if [ -f "$NGINX_DEFAULT_VHOST" ]; then
    if grep -q "^\s*listen \[::\]:80" "$NGINX_DEFAULT_VHOST"; then
        # Back up before modifying
        cp "$NGINX_DEFAULT_VHOST" "${NGINX_DEFAULT_VHOST}.bak"
        sed -i 's|^\(\s*\)listen \[::\]:80|\1# listen [::]:80|' "$NGINX_DEFAULT_VHOST"
        log "  IPv6 listen directive commented out in default vhost."
    else
        log "  IPv6 listen directive not present or already commented — skipping."
    fi
else
    log "  WARN: Default vhost not found at $NGINX_DEFAULT_VHOST — skipping patch."
fi

# ── Step 5: Enable and start Nginx ───────────────────────────────
log "Step 5/9 — Enabling and starting Nginx..."
systemctl enable nginx >> "$LOG_FILE" 2>&1
systemctl start nginx >> "$LOG_FILE" 2>&1

if ! systemctl is-active --quiet nginx; then
    log "ERROR: Nginx failed to start. Full status:"
    systemctl status nginx --no-pager -l | tee -a "$LOG_FILE"
    exit 1
fi
log "  Nginx: active (running), enabled."

# ── Step 6: Install MariaDB ───────────────────────────────────────
log "Step 6/9 — Installing MariaDB from official Ubuntu repos..."

if dpkg -s mariadb-server &>/dev/null; then
    log "  MariaDB already installed — skipping."
else
    apt install -y mariadb-server >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: MariaDB installation failed."
        exit 1
    fi
fi

systemctl enable mariadb >> "$LOG_FILE" 2>&1
systemctl start mariadb >> "$LOG_FILE" 2>&1

if ! systemctl is-active --quiet mariadb; then
    log "ERROR: MariaDB failed to start."
    systemctl status mariadb --no-pager -l | tee -a "$LOG_FILE"
    exit 1
fi
log "  MariaDB: active (running), enabled."
log "  Version: $(mysql --version 2>&1)"

# ── Step 7: Add PHP PPA ───────────────────────────────────────────
log "Step 7/9 — Adding PHP PPA: $PHP_PPA"

if grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
    log "  PHP PPA already present — skipping add."
else
    add-apt-repository -y "$PHP_PPA" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to add PHP PPA."
        exit 1
    fi
    apt update -qq >> "$LOG_FILE" 2>&1
    log "  PHP PPA added and package index refreshed."
fi

# ── Step 8: Install PHP and extensions ───────────────────────────
log "Step 8/9 — Installing PHP ${PHP_VERSION} and extensions..."
log "  Extensions: $PHP_EXTENSIONS"

# Build the full package list: php8.3-fpm php8.3-gd ... etc.
PHP_PACKAGES=""
for ext in $PHP_EXTENSIONS; do
    PHP_PACKAGES="$PHP_PACKAGES php${PHP_VERSION}-${ext}"
done

apt install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    $PHP_PACKAGES >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: PHP installation failed."
    exit 1
fi

PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
systemctl enable "$PHP_FPM_SERVICE" >> "$LOG_FILE" 2>&1
systemctl start "$PHP_FPM_SERVICE" >> "$LOG_FILE" 2>&1

if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    log "ERROR: PHP-FPM failed to start."
    systemctl status "$PHP_FPM_SERVICE" --no-pager -l | tee -a "$LOG_FILE"
    exit 1
fi
log "  PHP-FPM: active (running), enabled."
log "  Version: $(php -v 2>&1 | head -1)"

# ── Step 9: Final verification ────────────────────────────────────
log "Step 9/9 — Verifying all services..."
separator
log "Service status summary:"

for svc in nginx mariadb "php${PHP_VERSION}-fpm"; do
    if systemctl is-active --quiet "$svc"; then
        STATE="active (running)"
    else
        STATE="FAILED"
    fi
    if systemctl is-enabled --quiet "$svc"; then
        ENABLED="enabled"
    else
        ENABLED="disabled"
    fi
    log "  $svc → $STATE, $ENABLED"
done

log "LEMP stack installation complete."
log "  ✔ Nginx   → $(nginx -v 2>&1)"
log "  ✔ MariaDB → $(mysql --version 2>&1 | awk '{print $1, $2, $3}')"
log "  ✔ PHP     → $(php -v 2>&1 | head -1)"
