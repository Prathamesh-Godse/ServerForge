#!/bin/bash
# scripts/harden_wordpress.sh
# ================================================================
# Hardens the WordPress installation by:
#   1. Transferring file ownership from www-data to the pool user
#   2. Applying standard filesystem permissions (dirs 770, files 660)
#   3. Adding pool-level PHP hardening:
#        - allow_url_fopen = on  (WordPress requires it per site)
#        - disable_functions     (blocks shell/process/POSIX calls)
#   4. Creating a site-specific tmp/ directory for upload isolation
#   5. Configuring open_basedir to sandbox PHP to the site's files
#   6. Applying hardened or standard permission mode (configurable)
#   7. Setting wp-config.php to 440 (always read-only)
#   8. Reloading PHP-FPM to apply pool config changes
#
# PERMISSION_MODE in configs/site.conf controls permissions:
#   standard — dirs 770, files 660  (for active dev / update phase)
#   hardened — core dirs 550, core files 440  (for stable production)
#              wp-content stays 770/660 (writable for uploads/plugins)
#
# To revert to standard mode for WordPress updates:
#   Set PERMISSION_MODE=standard in site.conf and re-run Stage 20.
# After updating, re-run Stage 20 with PERMISSION_MODE=hardened.
#
# Covers: sections 36, 37, 38 of the Server Codex.
# The phpinfo() verification step is intentionally manual (browser).
#
# Reads from: configs/site.conf
#             configs/server.conf
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WP_HARDEN] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WP_HARDEN] ────────────────────────────────" \
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
POOL_USER=$(echo "$SITE_DOMAIN" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
SITE_ROOT="/var/www/${SITE_DOMAIN}/public_html"
SITE_TMP="/var/www/${SITE_DOMAIN}/tmp"
WP_CONTENT="${SITE_ROOT}/wp-content"
WP_CONFIG="${SITE_ROOT}/wp-config.php"
POOL_CONF="/etc/php/${SITE_PHP_VERSION}/fpm/pool.d/${SITE_DOMAIN}.conf"

separator
log "Starting WordPress hardening..."
log "  Domain          : $SITE_DOMAIN"
log "  Pool user       : $POOL_USER"
log "  Document root   : $SITE_ROOT"
log "  Permission mode : $PERMISSION_MODE"

# Pre-flight: check required directories exist
if [ ! -d "$SITE_ROOT" ]; then
    log "ERROR: Document root not found: $SITE_ROOT"
    log "       Complete Stage 18 (WordPress install) first."
    exit 1
fi

if [ ! -f "$POOL_CONF" ]; then
    log "ERROR: Pool config not found: $POOL_CONF"
    log "       Complete Stage 19 (PHP-FPM Pool Isolation) first."
    exit 1
fi

if ! id "$POOL_USER" &>/dev/null; then
    log "ERROR: Pool user '$POOL_USER' does not exist."
    log "       Complete Stage 19 (PHP-FPM Pool Isolation) first."
    exit 1
fi

# ── Step 1: Transfer ownership to pool user ───────────────────────
log "Step 1/7 — Transferring ownership to pool user: $POOL_USER"

chown -R "${POOL_USER}:${POOL_USER}" "$SITE_ROOT"

if [ $? -ne 0 ]; then
    log "ERROR: chown failed on $SITE_ROOT"
    exit 1
fi
log "  Ownership set to ${POOL_USER}:${POOL_USER} recursively."

# ── Step 2: Apply standard permissions (baseline) ─────────────────
log "Step 2/7 — Applying standard permissions (dirs 770, files 660)..."

find "$SITE_ROOT" -type d -exec chmod 770 {} \;
find "$SITE_ROOT" -type f -exec chmod 660 {} \;

log "  Directories: 770 (drwxrwx---)"
log "  Files      : 660 (-rw-rw----)"

# ── Step 3: Add pool-level PHP hardening directives ───────────────
log "Step 3/7 — Adding pool-level PHP hardening directives..."

# Remove existing ServerForge hardening block (idempotent re-runs)
if grep -q "# ServerForge pool hardening" "$POOL_CONF"; then
    sed -i '/# ServerForge pool hardening/,/# End hardening/d' "$POOL_CONF"
    log "  Removed existing hardening block for refresh."
fi

# disable_functions list — must be on a single line for PHP-FPM
DISABLE_FUNCS="shell_exec,opcache_get_configuration,opcache_get_status,disk_total_space,diskfreespace,dl,exec,passthru,pclose,pcntl_alarm,pcntl_exec,pcntl_fork,pcntl_get_last_error,pcntl_getpriority,pcntl_setpriority,pcntl_signal,pcntl_signal_dispatch,pcntl_sigprocmask,pcntl_sigtimedwait,pcntl_sigwaitinfo,pcntl_strerror,pcntl_waitpid,pcntl_wait,pcntl_wexitstatus,pcntl_wifcontinued,pcntl_wifexited,pcntl_wifsignaled,pcntl_wifstopped,pcntl_wstopsig,pcntl_wtermsig,popen,posix_getpwuid,posix_kill,posix_mkfifo,posix_setpgid,posix_setsid,posix_setuid,posix_uname,proc_close,proc_get_status,proc_nice,proc_open,proc_terminate,show_source,system"

cat >> "$POOL_CONF" << EOF

# ServerForge pool hardening — managed by harden_wordpress.sh
; WordPress requires allow_url_fopen for HTTP API calls, plugin/theme
; updates, and remote file operations. Enable per-pool only (global Off).
php_admin_flag[allow_url_fopen] = on

; Disable shell execution, process control, and POSIX calls.
; disk_free_space is intentionally left enabled (needed by some plugins).
; All directives must be on a SINGLE LINE — no line continuation in FPM.
php_admin_value[disable_functions] = ${DISABLE_FUNCS}
# End hardening
EOF

log "  allow_url_fopen = on (WordPress requires this)"
log "  disable_functions: $(echo "$DISABLE_FUNCS" | tr ',' '\n' | wc -l) functions disabled"

# ── Step 4: Create site-specific tmp/ directory ───────────────────
log "Step 4/7 — Creating site-specific tmp/ directory: $SITE_TMP"

mkdir -p "$SITE_TMP"
chown "${POOL_USER}:${POOL_USER}" "$SITE_TMP"
chmod 770 "$SITE_TMP"
log "  $SITE_TMP created (owner: ${POOL_USER}:${POOL_USER}, mode: 770)"

# ── Step 5: Configure open_basedir in pool config ─────────────────
log "Step 5/7 — Configuring open_basedir in pool config..."

# Remove existing open_basedir block (idempotent)
if grep -q "# ServerForge open_basedir" "$POOL_CONF"; then
    sed -i '/# ServerForge open_basedir/,/# End open_basedir/d' "$POOL_CONF"
    log "  Removed existing open_basedir block for refresh."
fi

cat >> "$POOL_CONF" << EOF

# ServerForge open_basedir — managed by harden_wordpress.sh
; Redirect file uploads away from the shared system /tmp.
; PHP functions like tempnam() and move_uploaded_file() use this path.
php_admin_value[upload_tmp_dir] = ${SITE_TMP}/
php_admin_value[sys_temp_dir]   = ${SITE_TMP}/

; Restrict PHP file access to this site's document root and tmp only.
; Any attempt to open, include, or read files outside these paths will
; be denied — even if the pool user could read them at the OS level.
php_admin_value[open_basedir]   = ${SITE_ROOT}/:${SITE_TMP}/
# End open_basedir
EOF

log "  upload_tmp_dir → $SITE_TMP/"
log "  sys_temp_dir   → $SITE_TMP/"
log "  open_basedir   → ${SITE_ROOT}/:${SITE_TMP}/"

# ── Step 6: Apply permission mode ────────────────────────────────
log "Step 6/7 — Applying permission mode: $PERMISSION_MODE"

if [ "$PERMISSION_MODE" = "hardened" ]; then
    log "  Locking core directories to 550 (read/execute, no write)..."
    find "$SITE_ROOT" -type d -exec chmod 550 {} \;

    log "  Locking core files to 440 (read-only)..."
    find "$SITE_ROOT" -type f -exec chmod 440 {} \;

    log "  Restoring wp-content to writable (dirs 770, files 660)..."
    if [ -d "$WP_CONTENT" ]; then
        find "$WP_CONTENT" -type d -exec chmod 770 {} \;
        find "$WP_CONTENT" -type f -exec chmod 660 {} \;
    fi

    log "  Hardened permissions applied."
    log "  WordPress core is now read-only. To revert for updates:"
    log "    Set PERMISSION_MODE=standard in site.conf and re-run Stage 20."

elif [ "$PERMISSION_MODE" = "standard" ]; then
    log "  Standard permissions already applied in Step 2 — no further changes."
    log "  WordPress core is writable (suitable for development / update phase)."

else
    log "  WARN: Unknown PERMISSION_MODE='$PERMISSION_MODE' — using standard."
fi

# ── Step 7: Lock wp-config.php to 440 ────────────────────────────
# wp-config.php contains database credentials and secret keys.
# It must never be writable — lock it regardless of PERMISSION_MODE.
log "Step 7/7 — Locking wp-config.php to 440 (always read-only)..."

if [ -f "$WP_CONFIG" ]; then
    chmod 440 "$WP_CONFIG"
    log "  $WP_CONFIG → 440 (-r--r-----)"
else
    log "  WARN: wp-config.php not found at $WP_CONFIG"
    log "        Complete Stage 18 (WordPress install) and the browser wizard first."
fi

# ── Reload PHP-FPM ────────────────────────────────────────────────
log "Reloading PHP-FPM to apply pool config changes..."
systemctl reload "php${SITE_PHP_VERSION}-fpm" >> "$LOG_FILE" 2>&1
log "  PHP-FPM reloaded."

# ── Summary ───────────────────────────────────────────────────────
separator
log "WordPress hardening complete."
log "  ✔ Ownership         : ${POOL_USER}:${POOL_USER}"
log "  ✔ Permission mode   : $PERMISSION_MODE"
log "  ✔ allow_url_fopen   : on (pool-level, WordPress requires it)"
log "  ✔ disable_functions : shell/process/POSIX functions blocked"
log "  ✔ tmp/ directory    : $SITE_TMP"
log "  ✔ open_basedir      : ${SITE_ROOT}/: + ${SITE_TMP}/"
log "  ✔ wp-config.php     : 440 (read-only)"
