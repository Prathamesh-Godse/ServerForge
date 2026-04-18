#!/bin/bash
# scripts/wordpress_application_hardening.sh
# ================================================================
# Applies the final WordPress application-layer hardening:
#
#   1. Add DISALLOW_FILE_MODS constant to wp-config.php
#      Prevents WordPress from installing, updating, or modifying
#      any files through the admin dashboard. Plugin and theme
#      updates must be done manually via SSH or WP-CLI.
#
#   2. Restrict MariaDB database user privileges (if DB_PRIVILEGE_HARDEN=yes)
#      Reduces the WordPress DB user from ALL PRIVILEGES to only
#      SELECT, INSERT, UPDATE, DELETE — the minimum needed for
#      day-to-day WordPress operation.
#
#   3. Reload PHP-FPM to apply wp-config.php changes
#
# ⚠  DISALLOW_FILE_MODS makes WordPress unable to install or update
#    plugins and themes from the dashboard. Apply only once the site
#    is fully configured and production-ready.
#
# ⚠  DB privilege hardening will BREAK WooCommerce sites. WooCommerce
#    requires CREATE, ALTER, and INDEX during plugin updates and
#    order processing. Set DB_PRIVILEGE_HARDEN=no if running WooCommerce.
#
# Covers: sections 48 and 49 of the Server Codex.
# Section 50 (REST API hardening via "Disable REST API" plugin) requires
# the WordPress admin dashboard — see README for manual instructions.
#
# Reads from: configs/site.conf
# Modifies  : /var/www/${DOMAIN}/public_html/wp-config.php
#             MariaDB grant tables
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WP_APP_HARDEN] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WP_APP_HARDEN] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$SITE_DOMAIN" ] || [ "$SITE_DOMAIN" = "<your-domain.com>" ]; then
    log "ERROR: SITE_DOMAIN not set in $CONFIG_FILE"
    exit 1
fi

SITE_ROOT="/var/www/${SITE_DOMAIN}/public_html"
WP_CONFIG="${SITE_ROOT}/wp-config.php"
PHP_FPM_SERVICE="php${SITE_PHP_VERSION}-fpm"

separator
log "Starting WordPress application hardening..."
log "  Domain              : $SITE_DOMAIN"
log "  DISALLOW_FILE_MODS  : will be added to wp-config.php"
log "  DB_PRIVILEGE_HARDEN : $DB_PRIVILEGE_HARDEN"

# ── Step 1: Add DISALLOW_FILE_MODS to wp-config.php ──────────────
log "Step 1/3 — Adding DISALLOW_FILE_MODS to wp-config.php..."

if [ ! -f "$WP_CONFIG" ]; then
    log "ERROR: wp-config.php not found: $WP_CONFIG"
    log "       Complete Stage 18 (WordPress install) and the browser wizard first."
    exit 1
fi

# Check if already present
if grep -q "DISALLOW_FILE_MODS" "$WP_CONFIG"; then
    log "  DISALLOW_FILE_MODS already present in wp-config.php — skipping."
else
    # Use Python to inject the constant before the stop-editing marker.
    # Python handles the file reliably without sed escaping issues.
    python3 << PYEOF
import sys

wp_config_path = "${WP_CONFIG}"

with open(wp_config_path, "r") as f:
    content = f.read()

constant = "\n/** DISALLOW FILE MODS — prevents WordPress from modifying files via dashboard */\ndefine('DISALLOW_FILE_MODS', 'true');\n"

# Insert before the stop-editing marker (the correct location per WordPress docs)
stop_marker = "/* That's all, stop editing!"
if stop_marker in content:
    content = content.replace(stop_marker, constant + "\n" + stop_marker, 1)
elif "require_once" in content:
    # Fallback: insert before the require_once ABSPATH line
    lines = content.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if "require_once" in line and "ABSPATH" in line:
            lines.insert(i, constant + "\n")
            break
    content = "".join(lines)
else:
    # Last resort: append to end of file
    content += constant

with open(wp_config_path, "w") as f:
    f.write(content)

print("DISALLOW_FILE_MODS added to wp-config.php")
PYEOF

    if [ $? -ne 0 ]; then
        log "ERROR: Failed to add DISALLOW_FILE_MODS to wp-config.php"
        exit 1
    fi
    log "  DISALLOW_FILE_MODS = true added to wp-config.php"
    log "  Plugin and theme updates must now be done via SSH or WP-CLI."

    # Ensure wp-config.php is still 440 after Python modified it
    chmod 440 "$WP_CONFIG"
    log "  wp-config.php permissions re-set to 440 (read-only)."
fi

# ── Step 2: Restrict MariaDB database user privileges ─────────────
log "Step 2/3 — Database privilege hardening (DB_PRIVILEGE_HARDEN=$DB_PRIVILEGE_HARDEN)..."

if [ "$DB_PRIVILEGE_HARDEN" != "yes" ]; then
    log "  DB_PRIVILEGE_HARDEN is not 'yes' — skipping."
    log "  Set DB_PRIVILEGE_HARDEN=yes in site.conf to enable."
    log "  ⚠  Do NOT enable for WooCommerce sites."
else
    log "  ⚠  Reading DB credentials from wp-config.php..."

    # Extract DB_NAME and DB_USER from wp-config.php using grep
    DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG" 2>/dev/null)
    DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG" 2>/dev/null)

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        log "ERROR: Could not extract DB_NAME or DB_USER from wp-config.php."
        log "       Ensure wp-config.php has been configured (Stage 18)."
        exit 1
    fi

    log "  DB_NAME : $DB_NAME"
    log "  DB_USER : $DB_USER"
    log ""
    log "  ⚠  WARNING: This WILL BREAK WooCommerce sites."
    log "     WooCommerce needs CREATE, ALTER, INDEX privileges."
    log "     Set DB_PRIVILEGE_HARDEN=no in site.conf for WooCommerce."
    log ""

    if ! systemctl is-active --quiet mariadb; then
        log "ERROR: MariaDB is not running."
        exit 1
    fi

    # Show current privileges before changing
    log "  Current privileges for ${DB_USER}@localhost:"
    mysql -e "SHOW GRANTS FOR '${DB_USER}'@'localhost';" 2>/dev/null \
        | tee -a "$LOG_FILE"

    # Revoke all existing privileges
    log "  Revoking ALL PRIVILEGES..."
    mysql -e "REVOKE ALL PRIVILEGES ON \`${DB_NAME}\`.* FROM '${DB_USER}'@'localhost';" \
        >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "  WARN: REVOKE returned non-zero. This is normal if the user"
        log "        had no privileges on this database yet."
    fi

    # Grant only the minimum required for WordPress
    log "  Granting SELECT, INSERT, UPDATE, DELETE only..."
    mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" \
        >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: GRANT failed. Check MariaDB logs."
        exit 1
    fi

    # Flush privileges to apply immediately
    mysql -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1

    # Verify the final state
    log "  Final privileges for ${DB_USER}@localhost:"
    mysql -e "SHOW GRANTS FOR '${DB_USER}'@'localhost';" 2>/dev/null \
        | tee -a "$LOG_FILE"

    log "  ✔ DB user '${DB_USER}' now has: SELECT, INSERT, UPDATE, DELETE only"
    log "  Note: If a plugin breaks with a CREATE/ALTER error after this step,"
    log "  grant those additional privileges temporarily during plugin activation:"
    log "    sudo mysql -e \"GRANT CREATE, ALTER, INDEX ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';\""
fi

# ── Step 3: Reload PHP-FPM ────────────────────────────────────────
log "Step 3/3 — Reloading PHP-FPM to apply wp-config.php changes..."

systemctl reload "$PHP_FPM_SERVICE" >> "$LOG_FILE" 2>&1

if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    log "WARN: PHP-FPM is not running after reload."
else
    log "  PHP-FPM reloaded."
fi

# ── Manual steps note ─────────────────────────────────────────────
separator
log "WordPress application hardening complete."
log ""
log "  ✔ DISALLOW_FILE_MODS = true → wp-config.php"
if [ "$DB_PRIVILEGE_HARDEN" = "yes" ]; then
    log "  ✔ DB user privileges  → SELECT, INSERT, UPDATE, DELETE only"
fi
log ""
log "  ══════════════════════════════════════════════════════"
log "  MANUAL STEP — REST API Hardening (section 50):"
log "  ══════════════════════════════════════════════════════"
log "  The WordPress REST API is publicly accessible by default."
log "  To restrict it to authenticated users only, install the"
log "  'Disable REST API' plugin by Dave McHale:"
log ""
log "    WordPress Admin → Plugins → Add New Plugin"
log "    Search: 'disable rest api'"
log "    Install and Activate: 'Disable REST API' by Dave McHale"
log ""
log "  Verify: visit https://${SITE_DOMAIN}/wp-json/ while logged out."
log "  Expected: 401 Unauthorized (not a list of endpoints)."
log ""
log "  ⚠  Test with your page builder and plugins before final deploy."
log "     Some require unauthenticated REST access for live previews."
log "  ══════════════════════════════════════════════════════"
