#!/bin/bash
# scripts/harden_optimize_php.sh
# ================================================================
# Hardens and optimizes the PHP-FPM installation by:
#   1. Writing /etc/php/${PHP_VERSION}/fpm/conf.d/server_override.ini
#      with all hardening and optimization directives in one file.
#   2. Raising the PHP-FPM open file limit via rlimit_files and
#      rlimit_core in php-fpm.conf (requires a full FPM restart).
#   3. Reloading Nginx and restarting PHP-FPM.
#
# Covers sections 27 and 28 of the Server Codex (combined because
# both sections write to the same config files).
#
# ⚠  OPcache (section 28) is intentionally NOT configured here.
#    OPcache will be configured per-site inside each PHP-FPM pool
#    config to maintain per-site cache isolation. See README.
#
# ⚠  PHP error logging is intentionally NOT configured here.
#    Per-site error log paths are set in each site's pool config.
#
# Reads from: configs/php.conf
#             configs/lemp.conf  (for PHP_VERSION if php.conf differs)
# Writes to : /etc/php/${PHP_VERSION}/fpm/conf.d/server_override.ini
#             /etc/php/${PHP_VERSION}/fpm/php-fpm.conf
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/php.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [PHP_HARDEN] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [PHP_HARDEN] ────────────────────────────────" \
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

# Derived paths
PHP_CONF_D="/etc/php/${PHP_VERSION}/fpm/conf.d"
PHP_OVERRIDE="${PHP_CONF_D}/server_override.ini"
PHP_FPM_CONF="/etc/php/${PHP_VERSION}/fpm/php-fpm.conf"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

# Validate PHP installation
if [ ! -d "$PHP_CONF_D" ]; then
    log "ERROR: PHP conf.d directory not found: $PHP_CONF_D"
    log "       Is PHP ${PHP_VERSION} installed? Run Stage 11 first."
    exit 1
fi

if [ ! -f "$PHP_FPM_CONF" ]; then
    log "ERROR: php-fpm.conf not found: $PHP_FPM_CONF"
    exit 1
fi

separator
log "Starting PHP hardening and optimization..."
log "  PHP version          : $PHP_VERSION"
log "  upload_max_filesize  : $PHP_UPLOAD_MAX_FILESIZE"
log "  post_max_size        : $PHP_POST_MAX_SIZE"
log "  max_input_vars       : $PHP_MAX_INPUT_VARS"
log "  memory_limit         : $PHP_MEMORY_LIMIT"
log "  rlimit_files         : $PHP_RLIMIT_FILES"

# ── Step 1: Write server_override.ini ────────────────────────────
log "Step 1/4 — Writing $PHP_OVERRIDE..."

cat > "$PHP_OVERRIDE" << EOF
; ================================================================
; ServerForge — PHP Server-Wide Override
; Managed by: serverforge/scripts/harden_optimize_php.sh
;
; This file is loaded automatically by PHP-FPM from conf.d/.
; Values here override php.ini for ALL PHP-FPM pools on the server.
; Per-site overrides go in each site's pool config via php_admin_value.
; ================================================================

; ── HARDEN PHP ───────────────────────────────────────────────────

; Disable PHP's ability to open remote URLs with fopen/file_get_contents.
; Removes the remote file inclusion attack vector. WordPress uses its
; own WP_HTTP API for remote requests and does not need this.
; Note: WordPress requires allow_url_fopen=On per site — enable it
; with php_admin_flag[allow_url_fopen]=on in each site's pool config.
allow_url_fopen = Off

; Prevent Nginx + PHP-FPM path traversal vulnerability.
; Without this, PHP tries to find the nearest .php file in a path
; like /uploads/malicious.jpg/index.php — which can execute PHP
; code embedded in uploaded image files.
cgi.fix_pathinfo = 0

; Remove X-Powered-By: PHP/x.x header from all responses.
; Pairs with more_clear_headers 'X-Powered-By' in Nginx basic_settings.conf.
expose_php = Off

; ── OPTIMIZE PHP ─────────────────────────────────────────────────

; Maximum size of a single uploaded file.
; Set high to allow WordPress theme and plugin uploads.
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}

; Maximum size of the entire HTTP POST body (files + fields).
; Must always exceed upload_max_filesize to account for form overhead.
post_max_size = ${PHP_POST_MAX_SIZE}

; Maximum number of input variables per request (POST + GET + cookies).
; Default 1000 silently truncates complex WordPress admin pages.
max_input_vars = ${PHP_MAX_INPUT_VARS}

; Maximum memory a single PHP process may consume.
; Also set define('WP_MEMORY_LIMIT', '${PHP_MEMORY_LIMIT}') in each wp-config.php.
memory_limit = ${PHP_MEMORY_LIMIT}

; max_execution_time and max_input_time are left as defaults.
; Uncomment and increase only if specific plugins require longer windows
; (e.g. bulk importers, long-running WP-Cron tasks).
;max_execution_time = 90
;max_input_time = 60
EOF

if [ $? -ne 0 ]; then
    log "ERROR: Failed to write $PHP_OVERRIDE"
    exit 1
fi
log "  $PHP_OVERRIDE written."

# ── Step 2: Raise PHP-FPM open file limit in php-fpm.conf ────────
# PHP-FPM exposes rlimit_files and rlimit_core as native directives.
# These are commented out in the default file — we uncomment and set them.
# A full restart (not just reload) is required for rlimit changes.
log "Step 2/4 — Raising PHP-FPM open file limit in $PHP_FPM_CONF..."

# Back up before modifying
if [ ! -f "${PHP_FPM_CONF}.bak" ]; then
    cp "$PHP_FPM_CONF" "${PHP_FPM_CONF}.bak"
    log "  Backup created: ${PHP_FPM_CONF}.bak"
else
    log "  Backup already exists — skipping."
fi

# The default file has these lines commented out with a semicolon:
#   ;rlimit_files = 1024
#   ;rlimit_core = 0
# We use sed to uncomment and replace the values.

# Handle both semicolon-commented (;rlimit_files) and hash-commented
# forms, and any existing uncommented line from a previous run.

# rlimit_files: uncomment and set value
if grep -qE '^\s*;?\s*rlimit_files\s*=' "$PHP_FPM_CONF"; then
    sed -i -E "s|^\s*;?\s*rlimit_files\s*=.*|rlimit_files = ${PHP_RLIMIT_FILES}|" \
        "$PHP_FPM_CONF"
    log "  rlimit_files set to $PHP_RLIMIT_FILES in $PHP_FPM_CONF"
else
    # Not present at all — append to the global section
    echo "rlimit_files = ${PHP_RLIMIT_FILES}" >> "$PHP_FPM_CONF"
    log "  rlimit_files appended to $PHP_FPM_CONF"
fi

# rlimit_core: uncomment and set to unlimited
if grep -qE '^\s*;?\s*rlimit_core\s*=' "$PHP_FPM_CONF"; then
    sed -i -E "s|^\s*;?\s*rlimit_core\s*=.*|rlimit_core = unlimited|" \
        "$PHP_FPM_CONF"
    log "  rlimit_core set to unlimited in $PHP_FPM_CONF"
else
    echo "rlimit_core = unlimited" >> "$PHP_FPM_CONF"
    log "  rlimit_core appended to $PHP_FPM_CONF"
fi

# Verify the changes
log "  Verifying rlimit directives in $PHP_FPM_CONF:"
grep -E "^rlimit_" "$PHP_FPM_CONF" | tee -a "$LOG_FILE"

# ── Step 3: Reload Nginx and restart PHP-FPM ─────────────────────
# Nginx reload applies the httpd config cleanly.
# PHP-FPM must be RESTARTED (not just reloaded) for rlimit changes —
# a reload applies ini changes but does not re-exec the master process.
log "Step 3/4 — Reloading Nginx and restarting PHP-FPM..."

systemctl reload nginx >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "WARN: Nginx reload returned an error. Check nginx config."
fi

systemctl restart "$PHP_FPM_SERVICE" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: PHP-FPM restart failed."
    systemctl status "$PHP_FPM_SERVICE" --no-pager -l | tee -a "$LOG_FILE"
    exit 1
fi

if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    log "ERROR: PHP-FPM is not running after restart."
    exit 1
fi
log "  Nginx reloaded. PHP-FPM restarted."

# ── Step 4: Verify the new rlimit is active ───────────────────────
log "Step 4/4 — Verifying PHP-FPM open file limit..."

# Give FPM a moment to initialize workers
sleep 2

PHP_MASTER_PID=$(pgrep -o "php-fpm" 2>/dev/null || pgrep -o "php${PHP_VERSION}-fpm" 2>/dev/null)

if [ -n "$PHP_MASTER_PID" ]; then
    log "  PHP-FPM master PID: $PHP_MASTER_PID"
    log "  Max open files:"
    grep "Max open files" "/proc/${PHP_MASTER_PID}/limits" 2>/dev/null \
        | tee -a "$LOG_FILE" \
        || log "  (Could not read limits — verify manually with: cat /proc/\$(pgrep -o php-fpm)/limits)"
else
    log "  WARN: Could not find PHP-FPM master PID — verify the limit manually."
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "PHP hardening and optimization complete."
log "  ✔ server_override.ini → $PHP_OVERRIDE"
log "  ✔ allow_url_fopen     → Off (enable per-site in pool config for WordPress)"
log "  ✔ cgi.fix_pathinfo    → 0"
log "  ✔ expose_php          → Off"
log "  ✔ upload_max_filesize → $PHP_UPLOAD_MAX_FILESIZE"
log "  ✔ post_max_size       → $PHP_POST_MAX_SIZE"
log "  ✔ max_input_vars      → $PHP_MAX_INPUT_VARS"
log "  ✔ memory_limit        → $PHP_MEMORY_LIMIT"
log "  ✔ rlimit_files        → $PHP_RLIMIT_FILES (php-fpm.conf)"
log "  ✔ rlimit_core         → unlimited (php-fpm.conf)"
log ""
log "  OPcache: deferred to per-site pool configuration — see README."
log "  PHP error logging: deferred to per-site pool configuration — see README."
