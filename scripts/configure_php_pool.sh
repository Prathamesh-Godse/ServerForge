#!/bin/bash
# scripts/configure_php_pool.sh
# ================================================================
# Creates a dedicated PHP-FPM pool for the site, isolating its PHP
# worker processes under their own system user and Unix socket.
#
# Without pool isolation every site shares the same php-fpm process
# running as www-data — a compromised plugin on one site gets
# read access to every other site on the server. A dedicated pool
# confines any exploit to the compromised site's document root only.
#
# Actions:
#   1. Derive the pool username from the site domain
#   2. Create the pool system user (no home dir, no login shell)
#   3. Set up cross-group membership so Nginx and PHP can read each
#      other's files and the admin user can manage site files
#   4. Copy the default www.conf to a site-specific pool config
#   5. Edit the pool config: name, user/group, socket, resource limits,
#      error logging
#   6. Create the PHP-FPM error log file with correct ownership
#   7. Reload PHP-FPM to activate the new pool
#   8. Update the Nginx server block to use the new pool socket
#   9. Test and reload Nginx
#
# Pool username is auto-derived from the site domain:
#   The first label before the first dot is used as the pool user.
#   example.com → example
#   mysite.co.uk → mysite
#
# Reads from: configs/site.conf
#             configs/server.conf (for SERVER_USER)
# Writes to : /etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf
#             /var/log/fpm-php.${POOL_USER}.log
#             /etc/nginx/sites-available/${DOMAIN}.conf (socket update)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [PHP_POOL] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [PHP_POOL] ────────────────────────────────" \
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

if [ -z "$SITE_DOMAIN" ] || [ "$SITE_DOMAIN" = "<your-domain.com>" ]; then
    log "ERROR: SITE_DOMAIN not set in $CONFIG_FILE"
    exit 1
fi

# ── Derived variables ─────────────────────────────────────────────
# Pool user: first DNS label before the first dot, lowercased
POOL_USER=$(echo "$SITE_DOMAIN" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
POOL_SOCKET="/run/php/php${SITE_PHP_VERSION}-fpm-${POOL_USER}.sock"
POOL_CONF="/etc/php/${SITE_PHP_VERSION}/fpm/pool.d/${SITE_DOMAIN}.conf"
WWW_CONF="/etc/php/${SITE_PHP_VERSION}/fpm/pool.d/www.conf"
PHP_LOG="/var/log/fpm-php.${POOL_USER}.log"
NGINX_CONF="/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
SITE_ROOT="/var/www/${SITE_DOMAIN}/public_html"

separator
log "Starting PHP-FPM pool isolation..."
log "  Domain      : $SITE_DOMAIN"
log "  Pool user   : $POOL_USER"
log "  PHP version : $SITE_PHP_VERSION"
log "  Socket      : $POOL_SOCKET"
log "  Pool conf   : $POOL_CONF"

# ── Step 1: Create the pool system user ───────────────────────────
log "Step 1/9 — Creating pool system user: $POOL_USER"

if id "$POOL_USER" &>/dev/null; then
    log "  User '$POOL_USER' already exists — skipping creation."
else
    # System user: no home directory, no login shell, no password
    useradd --system --no-create-home --shell /usr/sbin/nologin "$POOL_USER" \
        >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to create user '$POOL_USER'."
        exit 1
    fi
    log "  User '$POOL_USER' created (system user, no shell, no home)."
fi

# ── Step 2: Set up cross-group membership ─────────────────────────
# www-data → pool group: Nginx workers can read static assets owned
#            by the pool user (CSS, JS, images)
# pool user → www-data group: PHP-FPM workers can read files that
#            Nginx or other processes own as www-data
# SERVER_USER → pool group: admin can manage site files without sudo
log "Step 2/9 — Setting up cross-group membership..."

usermod -a -G "$POOL_USER" www-data      >> "$LOG_FILE" 2>&1
usermod -a -G www-data "$POOL_USER"      >> "$LOG_FILE" 2>&1
usermod -a -G "$POOL_USER" "$SERVER_USER" >> "$LOG_FILE" 2>&1

log "  www-data added to group: $POOL_USER"
log "  $POOL_USER added to group: www-data"
log "  $SERVER_USER added to group: $POOL_USER"
log "  Group memberships: $(id $POOL_USER 2>/dev/null)"

# ── Step 3: Create pool config from www.conf ──────────────────────
log "Step 3/9 — Creating pool config from www.conf..."

if [ ! -f "$WWW_CONF" ]; then
    log "ERROR: Source pool config not found: $WWW_CONF"
    exit 1
fi

if [ -f "$POOL_CONF" ] && [ ! -f "${POOL_CONF}.bak" ]; then
    cp "$POOL_CONF" "${POOL_CONF}.bak"
    log "  Existing pool conf backed up to ${POOL_CONF}.bak"
fi

cp "$WWW_CONF" "$POOL_CONF"
log "  Copied www.conf → $POOL_CONF"

# ── Step 4: Edit pool config — name, user, group, socket ──────────
log "Step 4/9 — Editing pool config directives..."

# Pool name: [www] → [POOL_USER]
sed -i "s/^\[www\]/[${POOL_USER}]/" "$POOL_CONF"

# User and group
sed -i "s/^user = www-data/user = ${POOL_USER}/" "$POOL_CONF"
sed -i "s/^group = www-data/group = ${POOL_USER}/" "$POOL_CONF"

# Unix socket path (site-specific, not the shared default)
sed -i "s|^listen = .*|listen = ${POOL_SOCKET}|" "$POOL_CONF"

# ── Step 5: Set resource limits ───────────────────────────────────
log "Step 5/9 — Setting pool resource limits..."

# rlimit_files: uncomment and set to 15000 (sensible for a WP site)
if grep -qE '^\s*;?\s*rlimit_files\s*=' "$POOL_CONF"; then
    sed -i -E "s|^\s*;?\s*rlimit_files\s*=.*|rlimit_files = 15000|" "$POOL_CONF"
    log "  rlimit_files = 15000"
fi

# rlimit_core: uncomment and set to 100 (small core dumps for crash analysis)
if grep -qE '^\s*;?\s*rlimit_core\s*=' "$POOL_CONF"; then
    sed -i -E "s|^\s*;?\s*rlimit_core\s*=.*|rlimit_core = 100|" "$POOL_CONF"
    log "  rlimit_core = 100"
fi

# ── Step 6: Configure PHP error logging ───────────────────────────
log "Step 6/9 — Configuring PHP error logging in pool config..."

# Remove any existing ServerForge PHP directives block
if grep -q "# ServerForge pool PHP directives" "$POOL_CONF"; then
    sed -i '/# ServerForge pool PHP directives/,/# End ServerForge/d' "$POOL_CONF"
    log "  Removed existing ServerForge directive block for refresh."
fi

# Append the PHP directives section
cat >> "$POOL_CONF" << EOF

# ServerForge pool PHP directives — managed by configure_php_pool.sh
php_flag[display_errors]         = off
php_admin_value[error_log]       = ${PHP_LOG}
php_admin_flag[log_errors]       = on
# End ServerForge
EOF

log "  PHP error logging configured: $PHP_LOG"

# ── Step 7: Create the PHP error log file ─────────────────────────
log "Step 7/9 — Creating PHP error log file: $PHP_LOG"

if [ ! -f "$PHP_LOG" ]; then
    touch "$PHP_LOG"
    chown "${POOL_USER}:www-data" "$PHP_LOG"
    chmod 660 "$PHP_LOG"
    log "  Created (owner: ${POOL_USER}:www-data, mode: 660)"
else
    log "  Log file already exists — verifying ownership..."
    chown "${POOL_USER}:www-data" "$PHP_LOG"
    chmod 660 "$PHP_LOG"
fi

# ── Step 8: Reload PHP-FPM ────────────────────────────────────────
log "Step 8/9 — Reloading PHP-FPM to activate the new pool..."

systemctl reload "php${SITE_PHP_VERSION}-fpm" >> "$LOG_FILE" 2>&1

sleep 2

# Verify the pool socket was created
if [ -S "$POOL_SOCKET" ]; then
    log "  Pool socket active: $POOL_SOCKET"
else
    log "  WARN: Pool socket not found at $POOL_SOCKET"
    log "        Check: journalctl -xeu php${SITE_PHP_VERSION}-fpm"
    log "        Check: grep '$POOL_USER' $POOL_CONF"
fi

log "  Active pools:"
grep "^\[" "$POOL_CONF" | tee -a "$LOG_FILE"

# ── Step 9: Update Nginx server block to use pool socket ──────────
log "Step 9/9 — Updating Nginx server block to use pool socket..."

if [ ! -f "$NGINX_CONF" ]; then
    log "ERROR: Nginx config not found: $NGINX_CONF"
    log "       Run Stage 17 (Site Infrastructure) first."
    exit 1
fi

# Back up before modification
cp "$NGINX_CONF" "${NGINX_CONF}.pre-pool.bak"

# Replace the fastcgi_pass socket path — handles both the default
# socket and any previously set pool socket
sed -i "s|fastcgi_pass unix:/run/php/.*\.sock;|fastcgi_pass unix:${POOL_SOCKET};|" \
    "$NGINX_CONF"

log "  fastcgi_pass updated to: unix:${POOL_SOCKET}"

# Test Nginx config
nginx -t >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: Nginx config test failed after socket update."
    log "  Restoring backup..."
    cp "${NGINX_CONF}.pre-pool.bak" "$NGINX_CONF"
    exit 1
fi

systemctl reload nginx >> "$LOG_FILE" 2>&1
log "  Nginx reloaded."

# ── Summary ───────────────────────────────────────────────────────
separator
log "PHP-FPM pool isolation complete."
log "  ✔ Pool user   : $POOL_USER (system user, no shell)"
log "  ✔ Pool config : $POOL_CONF"
log "  ✔ Socket      : $POOL_SOCKET"
log "  ✔ Error log   : $PHP_LOG"
log "  ✔ Nginx block : fastcgi_pass updated to pool socket"
log ""
log "  Blast radius of any plugin exploit is now confined to"
log "  ${SITE_ROOT} and its siblings only."
