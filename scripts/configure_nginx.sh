#!/bin/bash
# scripts/configure_nginx.sh
# ================================================================
# Hardens and optimizes Nginx by:
#   1. Tuning the main context  (worker limits, priority, JIT)
#   2. Tuning the events context (epoll, connection limits, mutex)
#   3. Creating /etc/nginx/includes/ with 6 modular config files:
#        basic_settings.conf — sendfile, tokens off, headers, MIME
#        buffers.conf        — client/output buffers, directio
#        timeouts.conf       — keepalive, send, header/body timeouts
#        file_handle_cache.conf — open file cache
#        gzip.conf           — gzip compression settings
#        brotli.conf         — Brotli compression settings
#   4. Rewiring the nginx.conf http context to use include directives
#      (removes the default inline directives; disables global
#       access_log — per-site logging goes in each server block)
#   5. Testing the config and reloading Nginx
#   6. Writing bash aliases to ~/.bash_aliases for SERVER_USER
#
# Section 20 (nginx context documentation) is intentionally skipped
# — it is educational content with no automatable commands.
#
# Reads from: configs/nginx_settings.conf
#             configs/server.conf (for SERVER_USER)
# Writes to : /etc/nginx/nginx.conf
#             /etc/nginx/includes/*.conf
#             /home/${SERVER_USER}/.bash_aliases
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/nginx_settings.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_INCLUDES="/etc/nginx/includes"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [NGINX_CFG] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [NGINX_CFG] ────────────────────────────────" \
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

if [ -z "$SERVER_USER" ] || [ "$SERVER_USER" = "<your-username>" ]; then
    log "ERROR: SERVER_USER is not set in configs/server.conf"
    exit 1
fi

USER_HOME="/home/${SERVER_USER}"

separator
log "Starting Nginx hardening and optimization..."
log "  worker_rlimit_nofile : $NGINX_WORKER_RLIMIT_NOFILE"
log "  worker_connections   : $NGINX_WORKER_CONNECTIONS"
log "  client_max_body_size : $NGINX_CLIENT_MAX_BODY_SIZE"

# ── Step 1: Back up nginx.conf ────────────────────────────────────
log "Step 1/6 — Backing up $NGINX_CONF..."
if [ ! -f "${NGINX_CONF}.bak" ]; then
    cp "$NGINX_CONF" "${NGINX_CONF}.bak"
    log "  Backup created: ${NGINX_CONF}.bak"
else
    log "  Backup already exists — skipping."
fi

# ── Step 2: Write the complete nginx.conf ─────────────────────────
# Rather than attempting fragile sed surgery on the default file,
# we write the entire nginx.conf from scratch using the known-good
# structure. The include directives for modules-enabled are preserved.
log "Step 2/6 — Writing hardened nginx.conf..."

cat > "$NGINX_CONF" << EOF
# ================================================================
# ServerForge — Nginx Main Configuration
# Managed by: serverforge/scripts/configure_nginx.sh
# ================================================================

# ── Main context ─────────────────────────────────────────────────
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

# Open file descriptor limit per worker process.
# Must exceed worker_connections plus overhead for static files,
# log handles, cache entries, and upstream connections.
worker_rlimit_nofile ${NGINX_WORKER_RLIMIT_NOFILE};

# Elevate worker scheduling priority above typical user-space apps.
# Range: -20 (highest) to 19 (lowest). -10 is a safe production value.
worker_priority -10;

# Reduce gettimeofday() syscall frequency. Saves overhead on busy servers.
timer_resolution 100ms;

# Enable JIT compilation for PCRE regex used in location blocks.
pcre_jit on;

# ── Events context ────────────────────────────────────────────────
events {
    # Max simultaneous connections per worker.
    worker_connections ${NGINX_WORKER_CONNECTIONS};

    # Prevent thundering herd: only one worker accepts at a time.
    accept_mutex on;
    accept_mutex_delay 200ms;

    # Use Linux epoll — most efficient connection model at scale.
    use epoll;
}

# ── HTTP context ──────────────────────────────────────────────────
http {

    ##
    # Basic Settings
    ##
    include /etc/nginx/includes/basic_settings.conf;

    ##
    # Buffer Settings
    ##
    include /etc/nginx/includes/buffers.conf;

    ##
    # Timeout Settings
    ##
    include /etc/nginx/includes/timeouts.conf;

    ##
    # File Handle Cache Settings
    ##
    include /etc/nginx/includes/file_handle_cache.conf;

    ##
    # Logging Settings
    ##
    # Global access log is disabled — each site's server block
    # enables its own access_log for per-site traffic tracking.
    access_log off;
    error_log /var/log/nginx/error.log;

    ##
    # Compression
    ##
    include /etc/nginx/includes/gzip.conf;
    include /etc/nginx/includes/brotli.conf;

    ##
    # Virtual Host Configs
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

log "  nginx.conf written."

# ── Step 3: Create /etc/nginx/includes/ and all include files ────
log "Step 3/6 — Creating nginx includes directory and config files..."

mkdir -p "$NGINX_INCLUDES"

# ── basic_settings.conf ──────────────────────────────────────────
cat > "${NGINX_INCLUDES}/basic_settings.conf" << 'EOF'
##
# BASIC SETTINGS
##

# Default character set for responses
charset utf-8;

# Kernel-level file transfer (disk→socket) without user-space copy
sendfile on;
sendfile_max_chunk 512k;

# Batch response headers + initial file data into one TCP packet
tcp_nopush on;

# Disable Nagle's algorithm — send data immediately, not buffered
tcp_nodelay on;

# Remove nginx version from error pages and Server header
server_tokens off;

# Remove Server and X-Powered-By headers entirely (requires headers-more module)
more_clear_headers 'Server';
more_clear_headers 'X-Powered-By';

# Use Host header in redirects rather than the primary server_name
server_name_in_redirect off;

server_names_hash_bucket_size 64;
variables_hash_max_size 2048;
types_hash_max_size 2048;

include /etc/nginx/mime.types;
default_type application/octet-stream;
EOF

# ── buffers.conf ─────────────────────────────────────────────────
cat > "${NGINX_INCLUDES}/buffers.conf" << EOF
##
# BUFFERS
##

# Buffer for reading the client request body in memory
client_body_buffer_size 256k;
client_body_in_file_only off;

# Buffer for reading client request headers
client_header_buffer_size 64k;

# Maximum request body size — high during setup to allow theme/plugin
# uploads. Reduce to 8m once the site is fully configured.
client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

connection_pool_size 512;

# Use direct I/O (bypassing OS page cache) for files > 4MB,
# preventing large transfers from evicting hot small files from cache
directio 4m;

# Drop requests with invalid HTTP headers
ignore_invalid_headers on;

# Buffers for large client headers (long URLs, heavy cookie use)
large_client_header_buffers 8 64k;

output_buffers 8 256k;

# Hold output until 1460 bytes (one TCP MSS) to reduce small packets
postpone_output 1460;
request_pool_size 32k;
EOF

# ── timeouts.conf ────────────────────────────────────────────────
cat > "${NGINX_INCLUDES}/timeouts.conf" << 'EOF'
##
# TIMEOUTS
##

# How long an idle keep-alive connection stays open
keepalive_timeout 5;

# Max requests per keep-alive connection before it is closed
keepalive_requests 500;

keepalive_disable msie6;
lingering_time 20s;
lingering_timeout 5s;

# Immediately free memory for timed-out connections (TCP RST)
reset_timedout_connection on;

# Timeout between successive write operations to the client
send_timeout 15s;

# Protect against Slowloris-style slow-read attacks
client_header_timeout 8s;
client_body_timeout 10s;
EOF

# ── file_handle_cache.conf ───────────────────────────────────────
cat > "${NGINX_INCLUDES}/file_handle_cache.conf" << 'EOF'
##
# FILE HANDLE CACHE
##

# Cache up to 50,000 file descriptors; evict files not used in 60s
open_file_cache max=50000 inactive=60s;

# How often nginx rechecks whether cached file metadata has changed
open_file_cache_valid 120s;

# Only keep a file in cache if accessed at least twice in inactive period
open_file_cache_min_uses 2;

# Do not cache file-not-found errors — newly created files are found immediately
open_file_cache_errors off;
EOF

# ── gzip.conf ────────────────────────────────────────────────────
cat > "${NGINX_INCLUDES}/gzip.conf" << 'EOF'
##
# GZIP
##
gzip on;

# Add Vary: Accept-Encoding so CDNs and proxies cache both versions
gzip_vary on;

# Disable for broken IE 6 clients
gzip_disable "MSIE [1-6]\.";

# Serve pre-compressed .gz files instead of compressing on the fly
gzip_static on;

# Only compress responses larger than ~1 TCP packet (1400 bytes)
gzip_min_length 1400;
gzip_buffers 32 8k;
gzip_http_version 1.0;

# Level 5: good balance between CPU cost and compression ratio (1-9)
gzip_comp_level 5;

gzip_proxied any;
gzip_types text/plain text/css text/xml application/javascript application/x-javascript application/xml application/xml+rss application/ecmascript application/json image/svg+xml;
EOF

# ── brotli.conf ──────────────────────────────────────────────────
cat > "${NGINX_INCLUDES}/brotli.conf" << 'EOF'
##
# BROTLI
# Requires: libnginx-mod-http-brotli-filter, libnginx-mod-http-brotli-static
# (installed in the LEMP stage via NGINX_MODULES)
##
brotli on;

# Level 6: strong compression without excessive CPU usage (range: 1-11)
brotli_comp_level 6;

# Serve pre-compressed .br files if they exist
brotli_static on;

brotli_types application/atom+xml application/javascript application/json application/rss+xml application/vnd.ms-fontobject application/x-font-opentype application/x-font-truetype application/x-font-ttf application/x-javascript application/xhtml+xml application/xml font/eot font/opentype font/otf font/truetype image/svg+xml image/vnd.microsoft.icon image/x-icon image/x-win-bitmap text/css text/javascript text/plain text/xml;
EOF

log "  All include files written to $NGINX_INCLUDES:"
ls "$NGINX_INCLUDES" | tee -a "$LOG_FILE"

# ── Step 4: Test the configuration ───────────────────────────────
log "Step 4/6 — Testing Nginx configuration..."

nginx -t >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: Nginx configuration test failed. Full output:"
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    log "  Restoring backup: ${NGINX_CONF}.bak"
    cp "${NGINX_CONF}.bak" "$NGINX_CONF"
    log "  Original nginx.conf restored. Fix the error and re-run."
    exit 1
fi
log "  Configuration test passed."

# ── Step 5: Reload Nginx ──────────────────────────────────────────
log "Step 5/6 — Reloading Nginx..."
systemctl reload nginx >> "$LOG_FILE" 2>&1

if ! systemctl is-active --quiet nginx; then
    log "ERROR: Nginx is not running after reload."
    systemctl status nginx --no-pager -l | tee -a "$LOG_FILE"
    exit 1
fi
log "  Nginx reloaded successfully."

# ── Step 6: Write bash aliases for SERVER_USER ───────────────────
log "Step 6/6 — Writing bash aliases to ${USER_HOME}/.bash_aliases..."

ALIASES_FILE="${USER_HOME}/.bash_aliases"

# Build the set of aliases to ensure (add only if not already present)
declare -A ALIASES=(
    ["server_update"]="sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y"
    ["ngt"]="sudo nginx -t"
    ["ngr"]="sudo systemctl reload nginx"
    ["fpmr"]="sudo systemctl restart php${NGINX_WORKER_CONNECTIONS}-fpm"
    ["ngin"]="cd /etc/nginx/includes && ls"
    ["ngsa"]="cd /etc/nginx/sites-available/ && ls"
)

# We need the PHP version for the fpmr alias — source it from lemp.conf if available
LEMP_CONF="$BASE_DIR/configs/lemp.conf"
PHP_VER="8.3"
if [ -f "$LEMP_CONF" ]; then
    PHP_VER=$(grep '^PHP_VERSION=' "$LEMP_CONF" | cut -d= -f2 | tr -d '"')
fi

# Touch the file if it doesn't exist
touch "$ALIASES_FILE"

# Write a clean, clearly labelled aliases block
# Check for the ServerForge marker to avoid duplicating on re-run
if grep -q "# ServerForge aliases" "$ALIASES_FILE" 2>/dev/null; then
    log "  Bash aliases block already present — skipping."
else
    cat >> "$ALIASES_FILE" << EOF

# ServerForge aliases — added by serverforge/scripts/configure_nginx.sh
alias server_update='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y'
alias ngt='sudo nginx -t'
alias ngr='sudo systemctl reload nginx'
alias fpmr='sudo systemctl restart php${PHP_VER}-fpm'
alias ngin='cd /etc/nginx/includes && ls'
alias ngsa='cd /etc/nginx/sites-available/ && ls'
EOF

    chown "${SERVER_USER}:${SERVER_USER}" "$ALIASES_FILE"
    log "  Bash aliases written to $ALIASES_FILE"
    log "  Aliases added: server_update, ngt, ngr, fpmr, ngin, ngsa"
    log "  Run 'source ~/.bash_aliases' or reconnect via SSH to activate."
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "Nginx hardening and optimization complete."
log "  ✔ nginx.conf          → hardened (main + events + http contexts)"
log "  ✔ worker_rlimit_nofile→ $NGINX_WORKER_RLIMIT_NOFILE"
log "  ✔ worker_connections  → $NGINX_WORKER_CONNECTIONS"
log "  ✔ Includes directory  → $NGINX_INCLUDES"
log "  ✔ Include files       → basic_settings, buffers, timeouts,"
log "                           file_handle_cache, gzip, brotli"
log "  ✔ Compression         → gzip + Brotli enabled"
log "  ✔ access_log          → off (per-site logging via server blocks)"
log "  ✔ Bash aliases        → ngt, ngr, fpmr, ngin, ngsa, server_update"
