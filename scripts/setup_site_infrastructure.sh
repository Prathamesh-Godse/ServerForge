#!/bin/bash
# scripts/setup_site_infrastructure.sh
# ================================================================
# Creates the web root directory structure and configures the Nginx
# virtual host for one site.
#
# Actions:
#   1. Install the 'tree' utility (directory visualiser)
#   2. Create /var/www/${SITE_DOMAIN}/public_html/
#   3. Write /etc/nginx/includes/browser_caching.conf
#   4. Write /etc/nginx/includes/fastcgi_optimize.conf
#   5. Write /etc/nginx/sites-available/${SITE_DOMAIN}.conf
#   6. Create a symlink in sites-enabled to activate the block
#   7. Test the Nginx configuration and reload
#
# The server block uses the default PHP-FPM socket until PHP-FPM
# pool isolation is configured in a later stage.
#
# Covers: sections 29, 30, 31 of the Server Codex.
# Sections 30 Part 1 (theory) and Part 2 (reload vs restart demo)
# are educational and intentionally not automated.
#
# Reads from: configs/site.conf
# Writes to : /var/www/${SITE_DOMAIN}/public_html/
#             /etc/nginx/includes/browser_caching.conf
#             /etc/nginx/includes/fastcgi_optimize.conf
#             /etc/nginx/sites-available/${SITE_DOMAIN}.conf
#             /etc/nginx/sites-enabled/${SITE_DOMAIN}.conf (symlink)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

NGINX_INCLUDES="/etc/nginx/includes"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SITE_INFRA] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SITE_INFRA] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$SITE_DOMAIN" ] || [ "$SITE_DOMAIN" = "<your-domain.com>" ]; then
    log "ERROR: SITE_DOMAIN is not configured in $CONFIG_FILE"
    exit 1
fi

if [ ! -d "$NGINX_INCLUDES" ]; then
    log "ERROR: Nginx includes directory not found: $NGINX_INCLUDES"
    log "       Run Stage 13 (Nginx Hardening) first."
    exit 1
fi

separator
log "Starting site infrastructure setup..."
log "  Domain     : $SITE_DOMAIN"
log "  PHP version: $SITE_PHP_VERSION"
log "  Web root   : /var/www/${SITE_DOMAIN}/public_html/"

# ── Step 1: Install tree ──────────────────────────────────────────
log "Step 1/7 — Installing 'tree' utility..."

if command -v tree &>/dev/null; then
    log "  tree already installed."
else
    apt install -y tree >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "  WARN: Could not install tree. Non-critical — continuing."
    else
        log "  tree installed."
    fi
fi

# ── Step 2: Create web root directory structure ───────────────────
log "Step 2/7 — Creating web root: /var/www/${SITE_DOMAIN}/public_html/"

mkdir -p "/var/www/${SITE_DOMAIN}/public_html"

if [ $? -ne 0 ]; then
    log "ERROR: Failed to create web root directory."
    exit 1
fi
log "  Web root created (or already exists)."

# Verify the structure
if command -v tree &>/dev/null; then
    log "  Directory structure:"
    tree "/var/www/${SITE_DOMAIN}" 2>/dev/null | tee -a "$LOG_FILE"
fi

# ── Step 3: Write browser_caching.conf ───────────────────────────
# Provides HTTP cache headers for static assets served by this site.
# Included from within each site's server block.
log "Step 3/7 — Writing ${NGINX_INCLUDES}/browser_caching.conf..."

cat > "${NGINX_INCLUDES}/browser_caching.conf" << 'EOF'
##
# BROWSER CACHING
# Instructs clients and CDN/proxy caches to store static assets
# locally, reducing repeat requests and improving load times.
# Include this file inside each site's server block.
##

# Media, documents, and binary assets — cache for 1 year.
# These files change rarely; a long TTL is safe.
location ~* \.(webp|3gp|gif|jpg|jpeg|png|ico|wmv|avi|asf|asx|mpg|mpeg|mp4|pls|mp3|mid|wav|swf|flv|exe|zip|tar|rar|gz|tgz|bz2|uha|7z|doc|docx|xls|xlsx|pdf|iso)$ {
    expires 365d;
    add_header Cache-Control "public, no-transform";
    access_log off;
}

# JavaScript — cache for 30 days.
location ~* \.(js)$ {
    expires 30d;
    add_header Cache-Control "public, no-transform";
    access_log off;
}

# CSS — cache for 30 days.
location ~* \.(css)$ {
    expires 30d;
    add_header Cache-Control "public, no-transform";
    access_log off;
}

# Fonts — cache for 30 days.
location ~* \.(eot|svg|ttf|woff|woff2)$ {
    expires 30d;
    add_header Cache-Control "public, no-transform";
    access_log off;
}
EOF

log "  browser_caching.conf written."

# ── Step 4: Write fastcgi_optimize.conf ──────────────────────────
# Tunes FastCGI buffer sizes and timeouts for PHP-FPM communication.
# Prevents gateway timeouts and avoids disk spill for large responses.
# Included from within each site's PHP location block.
log "Step 4/7 — Writing ${NGINX_INCLUDES}/fastcgi_optimize.conf..."

cat > "${NGINX_INCLUDES}/fastcgi_optimize.conf" << 'EOF'
##
# FASTCGI OPTIMIZATION
# Tunes buffer sizes and timeouts for Nginx ↔ PHP-FPM communication.
# Include this inside the location ~ \.php$ block of each server block.
#
# Larger buffers keep PHP responses in memory rather than spilling
# to disk, reducing I/O latency on pages that generate large output.
##

# Seconds to wait for a connection to PHP-FPM before giving up
fastcgi_connect_timeout 60;

# Seconds to wait between successive writes to PHP-FPM
fastcgi_send_timeout 180;

# Seconds to wait for PHP-FPM to return a response.
# Increase this for sites with slow operations (bulk imports, WP-Cron).
fastcgi_read_timeout 180;

# Buffer for the first part of the PHP-FPM response (headers)
fastcgi_buffer_size 512k;

# Buffer pool for the response body: 512 × 16KB = 8MB total
fastcgi_buffers 512 16k;

# Maximum buffer size in use simultaneously while sending to client
fastcgi_busy_buffers_size 1m;

# Maximum chunk written to a temp file when response overflows buffers
fastcgi_temp_file_write_size 4m;

# Maximum temp file size; set to 0 to disable temp files entirely
fastcgi_max_temp_file_size 4m;

# Allow Nginx to serve custom error pages for PHP-FPM error codes
fastcgi_intercept_errors on;
EOF

log "  fastcgi_optimize.conf written."

# ── Step 5: Write Nginx server block ─────────────────────────────
SITE_CONF="${SITES_AVAILABLE}/${SITE_DOMAIN}.conf"
PHP_SOCKET="/run/php/php${SITE_PHP_VERSION}-fpm.sock"

log "Step 5/7 — Writing server block: $SITE_CONF"
log "  PHP socket: $PHP_SOCKET"

# Back up any existing config for this domain
if [ -f "$SITE_CONF" ]; then
    cp "$SITE_CONF" "${SITE_CONF}.bak"
    log "  Existing config backed up to ${SITE_CONF}.bak"
fi

cat > "$SITE_CONF" << EOF
# ServerForge — Nginx server block for ${SITE_DOMAIN}
# Managed by: serverforge/scripts/setup_site_infrastructure.sh
#
# Note: The fastcgi_pass socket uses the default PHP-FPM pool until
# PHP-FPM pool isolation is configured (a later ServerForge stage).
server {

    listen 80;

    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};

    root /var/www/${SITE_DOMAIN}/public_html;
    index index.php;

    # WordPress permalink handling.
    # try_files checks for a real file, then a real directory, then
    # falls back to index.php with the original query string — this
    # is what makes WordPress pretty URLs work.
    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    # Route all .php requests to PHP-FPM via the Unix socket.
    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCKET};
        include /etc/nginx/includes/fastcgi_optimize.conf;
    }

    # Static asset caching (browser Cache-Control and Expires headers)
    include /etc/nginx/includes/browser_caching.conf;

    # Per-site access log with buffered writes (reduces disk I/O)
    access_log /var/log/nginx/${SITE_DOMAIN}.access.log combined buffer=256k flush=60m;

    # Per-site error log (separate from global and other sites)
    error_log /var/log/nginx/${SITE_DOMAIN}.error.log;

}
EOF

log "  Server block written for $SITE_DOMAIN"

# ── Step 6: Enable the site with a symlink ────────────────────────
SITE_LINK="${SITES_ENABLED}/${SITE_DOMAIN}.conf"

log "Step 6/7 — Enabling site: $SITE_LINK → $SITE_CONF"

if [ -L "$SITE_LINK" ]; then
    log "  Symlink already exists — removing and recreating."
    rm "$SITE_LINK"
fi

ln -s "$SITE_CONF" "$SITE_LINK"

if [ $? -ne 0 ]; then
    log "ERROR: Failed to create symlink in sites-enabled."
    exit 1
fi
log "  Site enabled via symlink."

# ── Step 7: Test Nginx config and reload ─────────────────────────
log "Step 7/7 — Testing Nginx configuration..."

nginx -t >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: Nginx configuration test failed."
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    log "  Removing symlink to prevent broken config from persisting..."
    rm -f "$SITE_LINK"
    log "  Fix the error and re-run Stage 17."
    exit 1
fi
log "  Configuration test passed."

log "Reloading Nginx..."
systemctl reload nginx >> "$LOG_FILE" 2>&1

if ! systemctl is-active --quiet nginx; then
    log "ERROR: Nginx is not running after reload."
    exit 1
fi
log "  Nginx reloaded."

# ── Summary ───────────────────────────────────────────────────────
separator
log "Site infrastructure setup complete."
log "  ✔ Web root          → /var/www/${SITE_DOMAIN}/public_html/"
log "  ✔ browser_caching   → ${NGINX_INCLUDES}/browser_caching.conf"
log "  ✔ fastcgi_optimize  → ${NGINX_INCLUDES}/fastcgi_optimize.conf"
log "  ✔ Server block      → ${SITE_CONF}"
log "  ✔ Site enabled      → ${SITE_LINK}"
log "  ✔ Nginx reloaded"
log ""
log "  A GET to http://${SITE_DOMAIN}/ will return 403 Forbidden"
log "  until WordPress is installed (empty document root is expected)."
