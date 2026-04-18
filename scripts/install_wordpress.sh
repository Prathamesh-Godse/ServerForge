#!/bin/bash
# scripts/install_wordpress.sh
# ================================================================
# Installs WordPress for the site defined in configs/site.conf.
#
# Actions:
#   1. Generate random DB credentials and table prefix
#   2. Create the MariaDB database and database user
#   3. Download the latest WordPress from wordpress.org
#   4. Configure wp-config.php:
#        - Database credentials
#        - Authentication salts (fetched from WordPress API)
#        - Randomised table prefix
#        - Operational constants (FS_METHOD, DISALLOW_FILE_EDIT, etc.)
#   5. Deploy WordPress files to /var/www/${SITE_DOMAIN}/public_html/
#      via rsync (preserves permissions and symlinks)
#   6. Set file ownership to www-data:www-data
#   7. Write generated credentials to ~/serverforge-${DOMAIN}-credentials.txt
#
# ⚠  The browser-based WordPress installation wizard is NOT automated.
#    Navigate to http://${SITE_DOMAIN}/ after this stage completes
#    to run the wizard and create the WordPress admin account.
#    See README for first-login housekeeping steps.
#
# ⚠  After PHP-FPM pool isolation is configured (a later stage),
#    file ownership will change from www-data to the pool user.
#
# Covers: sections 32 (Part 2) and 33 (Steps 1–4) of Server Codex.
# Sections 32 Part 1 (MariaDB tutorial) and 33 Steps 5–7 (browser
# wizard, housekeeping, maintenance plugin) are intentionally manual.
#
# Reads from: configs/site.conf
#             configs/server.conf (for SERVER_USER home directory)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

WP_DOWNLOAD_URL="https://wordpress.org/latest.tar.gz"
WP_SALT_API="https://api.wordpress.org/secret-key/1.1/salt/"
WP_TMP_DIR="/tmp/serverforge-wordpress-$$"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WP_INSTALL] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WP_INSTALL] ────────────────────────────────" \
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
    log "ERROR: SITE_DOMAIN is not configured in $CONFIG_FILE"
    exit 1
fi

if [ -z "$SERVER_USER" ] || [ "$SERVER_USER" = "<your-username>" ]; then
    log "ERROR: SERVER_USER is not set in $SERVER_CONF"
    exit 1
fi

DOCUMENT_ROOT="/var/www/${SITE_DOMAIN}/public_html"
if [ ! -d "$DOCUMENT_ROOT" ]; then
    log "ERROR: Document root not found: $DOCUMENT_ROOT"
    log "       Run Stage 17 (Site Infrastructure) first."
    exit 1
fi

if ! systemctl is-active --quiet mariadb; then
    log "ERROR: MariaDB is not running. Start it before installing WordPress."
    exit 1
fi

separator
log "Starting WordPress installation for: $SITE_DOMAIN"

# ── Step 1: Generate credentials ──────────────────────────────────
log "Step 1/7 — Generating credentials..."

# DB name: derive from domain (dots and dashes → underscores, lowercase)
DB_NAME=$(echo "$SITE_DOMAIN" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')

# DB user: 12-char random alphanumeric
DB_USER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)

# DB password: 24-char random alphanumeric
DB_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 24)

# Table prefix: 3 random letters + 1 digit + underscore (e.g. bF6_)
TABLE_PREFIX="$(cat /dev/urandom | tr -dc 'a-zA-Z' | head -c 3)$(cat /dev/urandom | tr -dc '0-9' | head -c 1)_"

log "  DB name   : $DB_NAME"
log "  DB user   : $DB_USER"
log "  DB pass   : [generated — see credentials file]"
log "  Table prefix: $TABLE_PREFIX"

# ── Step 2: Create MariaDB database and user ──────────────────────
log "Step 2/7 — Creating MariaDB database and user..."

# Check if database already exists
DB_EXISTS=$(mysql -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" 2>/dev/null)
if [ -n "$DB_EXISTS" ]; then
    log "  WARN: Database '$DB_NAME' already exists — skipping creation."
    log "        Delete it manually before re-running if you want a fresh install:"
    log "        sudo mysql -e \"DROP DATABASE ${DB_NAME};\""
else
    mysql -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to create database '$DB_NAME'."
        exit 1
    fi
    log "  Database '$DB_NAME' created."
fi

# Create user and grant privileges (idempotent)
mysql >> "$LOG_FILE" 2>&1 << SQL
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
SQL

if [ $? -ne 0 ]; then
    log "ERROR: Failed to create database user '$DB_USER'."
    exit 1
fi
log "  User '$DB_USER'@'localhost' created with privileges on '$DB_NAME'."

# Verify
log "  Verifying grant:"
mysql -e "SHOW GRANTS FOR '${DB_USER}'@'localhost';" 2>/dev/null | tee -a "$LOG_FILE"

# ── Step 3: Download WordPress ────────────────────────────────────
log "Step 3/7 — Downloading WordPress..."

mkdir -p "$WP_TMP_DIR"
cd "$WP_TMP_DIR"

wget -q -O latest.tar.gz "$WP_DOWNLOAD_URL"
if [ $? -ne 0 ] || [ ! -s latest.tar.gz ]; then
    log "ERROR: WordPress download failed. Check network connectivity."
    log "       URL: $WP_DOWNLOAD_URL"
    rm -rf "$WP_TMP_DIR"
    exit 1
fi
log "  Downloaded: $(du -sh latest.tar.gz | cut -f1)"

log "  Extracting..."
tar xf latest.tar.gz
if [ $? -ne 0 ] || [ ! -d wordpress ]; then
    log "ERROR: Extraction failed."
    rm -rf "$WP_TMP_DIR"
    exit 1
fi
log "  Extracted to $WP_TMP_DIR/wordpress/"

# ── Step 4: Fetch WordPress salts ────────────────────────────────
log "Step 4/7 — Fetching authentication salts from WordPress API..."

SALTS=$(curl -s "$WP_SALT_API")
if [ $? -ne 0 ] || [ -z "$SALTS" ]; then
    log "ERROR: Failed to fetch salts from WordPress API."
    log "       URL: $WP_SALT_API"
    log "       Check network connectivity."
    rm -rf "$WP_TMP_DIR"
    exit 1
fi
log "  Salts fetched (${#SALTS} bytes)."

# ── Step 5: Configure wp-config.php ──────────────────────────────
log "Step 5/7 — Configuring wp-config.php..."

cd "$WP_TMP_DIR/wordpress"
cp wp-config-sample.php wp-config.php

# Write salts to a temp file (avoids escaping issues in Python heredoc)
SALTS_FILE="/tmp/wp-salts-$$.txt"
echo "$SALTS" > "$SALTS_FILE"

# Use Python for all wp-config.php edits — Python handles the special
# characters in salt values safely via environment variables.
python3 << PYEOF
import re, os, sys

wp_config_path = os.path.join("${WP_TMP_DIR}", "wordpress", "wp-config.php")

with open(wp_config_path, "r") as f:
    content = f.read()

# ── Database credentials ──────────────────────────────────────────
content = content.replace("database_name_here", "${DB_NAME}")
content = content.replace("username_here",      "${DB_USER}")
content = content.replace("password_here",      "${DB_PASS}")
# DB_HOST stays as localhost — correct for same-server database

# ── Authentication salts ──────────────────────────────────────────
# Replace the 8-line salt placeholder block with API-generated values.
# The pattern matches from 'AUTH_KEY' through the end of 'NONCE_SALT'.
with open("${SALTS_FILE}", "r") as sf:
    salts = sf.read().strip()

salt_pattern = re.compile(
    r"define\s*\(\s*'AUTH_KEY'.*?define\s*\(\s*'NONCE_SALT'\s*,\s*'[^']*'\s*\)\s*;",
    re.DOTALL
)
if salt_pattern.search(content):
    content = salt_pattern.sub(salts, content)
else:
    sys.stderr.write("WARN: Salt block pattern not found — appending salts.\n")
    content += "\n" + salts + "\n"

# ── Table prefix ──────────────────────────────────────────────────
# Randomised prefix makes table names unpredictable (default 'wp_' is
# targeted by automated SQL injection scanners).
content = content.replace(
    "\$table_prefix = 'wp_';",
    "\$table_prefix = '${TABLE_PREFIX}';"
)

# ── Operational constants ─────────────────────────────────────────
# Injected in the designated custom-values zone, before the
# "stop editing" comment that marks the end of the config area.
operational = """
/** Allow Direct File Operations Without FTP Credentials */
define('FS_METHOD', 'direct');

/** Disable the Built-In Theme and Plugin Code Editor */
define('DISALLOW_FILE_EDIT', 'true');

/** Disable Automatic WordPress Core Updates */
define('WP_AUTO_UPDATE_CORE', false);
define('AUTOMATIC_UPDATER_DISABLED', 'true');

/** WordPress Memory Limit — matches server-override.ini setting */
define('WP_MEMORY_LIMIT', '256M');
"""

stop_editing_marker = "/* That's all, stop editing!"
if stop_editing_marker in content:
    content = content.replace(
        stop_editing_marker,
        operational + "\n" + stop_editing_marker
    )
else:
    content += "\n" + operational

with open(wp_config_path, "w") as f:
    f.write(content)

print("wp-config.php configured successfully.")
PYEOF

PY_EXIT=$?
rm -f "$SALTS_FILE"

if [ $PY_EXIT -ne 0 ]; then
    log "ERROR: wp-config.php configuration failed (Python exit $PY_EXIT)."
    rm -rf "$WP_TMP_DIR"
    exit 1
fi
log "  wp-config.php configured:"
log "    DB name      : $DB_NAME"
log "    DB user      : $DB_USER"
log "    Table prefix : $TABLE_PREFIX"
log "    Salts        : API-generated"
log "    FS_METHOD    : direct"
log "    File editing : disabled"
log "    Auto-updates : disabled"

# ── Step 6: Deploy WordPress to document root ─────────────────────
log "Step 6/7 — Deploying WordPress to $DOCUMENT_ROOT..."

# rsync with trailing slash on source copies CONTENTS (not the directory itself)
rsync -a --info=progress2 "${WP_TMP_DIR}/wordpress/" "$DOCUMENT_ROOT/" \
    >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: rsync deployment failed."
    rm -rf "$WP_TMP_DIR"
    exit 1
fi

# Set ownership: www-data owns files initially.
# This will change to the pool user when PHP-FPM pool isolation is set up.
chown -R www-data:www-data "$DOCUMENT_ROOT/"
log "  WordPress deployed. Ownership set to www-data:www-data."

# Clean up temp files
rm -rf "$WP_TMP_DIR"
log "  Temp files cleaned up."

# Verify deployment
WP_FILES=$(ls "$DOCUMENT_ROOT" | wc -l)
log "  Document root contains $WP_FILES items."

# ── Step 7: Save credentials to file ─────────────────────────────
log "Step 7/7 — Saving credentials to ~${SERVER_USER}/..."

CREDS_FILE="/home/${SERVER_USER}/serverforge-${SITE_DOMAIN}-credentials.txt"

cat > "$CREDS_FILE" << EOF
# ================================================================
# ServerForge — Site Credentials: ${SITE_DOMAIN}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ================================================================
# IMPORTANT: Store these credentials securely and delete this file
# once they are saved in a password manager or secrets vault.
# ================================================================

Site Domain   : ${SITE_DOMAIN}
Document Root : ${DOCUMENT_ROOT}

# ── MariaDB ───────────────────────────────────────────────────────
DB Host       : localhost
DB Name       : ${DB_NAME}
DB User       : ${DB_USER}
DB Password   : ${DB_PASS}
Table Prefix  : ${TABLE_PREFIX}

# ── Next Steps (manual) ───────────────────────────────────────────
# 1. Complete the WordPress browser wizard:
#    http://${SITE_DOMAIN}/
#
# 2. During the wizard, set a WordPress admin username and password.
#    Use a random 30-character string for the username — do NOT use
#    'admin'. Store the admin credentials here once created.
#
# WordPress Admin Username : <set during wizard>
# WordPress Admin Password : <set during wizard>
# WordPress Admin Email    : <set during wizard>
EOF

chown "${SERVER_USER}:${SERVER_USER}" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
log "  Credentials saved to $CREDS_FILE (mode 600)"

# ── Summary ───────────────────────────────────────────────────────
separator
log "WordPress installation complete."
log "  ✔ MariaDB database : $DB_NAME"
log "  ✔ MariaDB user     : $DB_USER"
log "  ✔ Table prefix     : $TABLE_PREFIX"
log "  ✔ WordPress files  : deployed to $DOCUMENT_ROOT"
log "  ✔ Ownership        : www-data:www-data"
log "  ✔ Credentials file : $CREDS_FILE"
log ""
log "  ═══════════════════════════════════════════════════"
log "  NEXT STEP: Complete the browser-based wizard:"
log "    http://${SITE_DOMAIN}/"
log "  ═══════════════════════════════════════════════════"
log "  During the wizard:"
log "    - Site title: your site name"
log "    - Username: use a random 30-char string (NOT 'admin')"
log "    - Password: use a strong generated password"
log "    - Email: your admin email address"
log "  Save the admin credentials to $CREDS_FILE"
log ""
log "  First-login housekeeping (after wizard):"
log "    - Settings → Permalinks → Post name"
log "    - Delete Akismet and Hello Dolly plugins"
log "    - Delete unused default themes"
log "    - Update Profile → Nickname and Display Name"
log "    - Install a maintenance mode plugin if needed"
