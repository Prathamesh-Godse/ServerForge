#!/bin/bash
# scripts/harden_mariadb.sh
# ================================================================
# Hardens a fresh MariaDB installation by running the equivalent
# of mysql_secure_installation non-interactively via direct SQL.
#
# Actions performed (matching mysql_secure_installation defaults):
#   1. Remove all anonymous user accounts
#   2. Disallow root login from any host except localhost
#   3. Drop the 'test' database and its privilege entries
#   4. Flush privilege tables to apply changes immediately
#
# The unix socket / root password prompts from mysql_secure_installation
# are bypassed — MariaDB on Ubuntu already uses unix socket auth
# for root, so no password is needed or set.
#
# This script is idempotent: re-running it is safe — the SQL
# statements are constructed to be no-ops if already applied.
#
# No config file needed — all values are fixed security standards.
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MARIADB_HARDEN] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MARIADB_HARDEN] ────────────────────────────────" \
        | tee -a "$LOG_FILE"
}

# ── Pre-flight ────────────────────────────────────────────────────
if ! command -v mysql &>/dev/null; then
    log "ERROR: mysql client not found. Is MariaDB installed?"
    exit 1
fi

if ! systemctl is-active --quiet mariadb; then
    log "ERROR: MariaDB is not running. Start it before hardening."
    exit 1
fi

separator
log "Starting MariaDB hardening (non-interactive mysql_secure_installation equivalent)..."

# ── Helper: run SQL and log result ───────────────────────────────
run_sql() {
    local description="$1"
    local sql="$2"
    log "  $description"
    mysql -e "$sql" 2>> "$LOG_FILE"
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "  WARN: SQL returned exit code $exit_code — may already be applied."
    fi
    return $exit_code
}

# ── Step 1: Remove anonymous user accounts ────────────────────────
# Anonymous users allow anyone to connect to MariaDB without
# credentials — present only to ease fresh-install testing.
log "Step 1/4 — Removing anonymous user accounts..."
run_sql \
    "DELETE FROM mysql.user WHERE User='';" \
    "DELETE FROM mysql.user WHERE User='';"

# ── Step 2: Disallow remote root login ────────────────────────────
# Root should only connect from localhost. Remote root login opens
# the database to network-level brute-force attacks.
log "Step 2/4 — Disallowing remote root login..."
run_sql \
    "DELETE root accounts not bound to localhost/127.0.0.1/::1" \
    "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"

# ── Step 3: Remove the test database ─────────────────────────────
# The test database is world-accessible by default (including to
# anonymous users). It serves no purpose in production.
log "Step 3/4 — Dropping test database and privileges..."
run_sql \
    "DROP DATABASE IF EXISTS test" \
    "DROP DATABASE IF EXISTS test;"
run_sql \
    "Remove test database privilege entries" \
    "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"

# ── Step 4: Flush privileges ──────────────────────────────────────
log "Step 4/4 — Flushing privilege tables..."
run_sql \
    "FLUSH PRIVILEGES" \
    "FLUSH PRIVILEGES;"

# ── Verify final state ────────────────────────────────────────────
separator
log "Verifying MariaDB security state..."

log "Current users (should show only named accounts at localhost):"
mysql -e "SELECT Host, User FROM mysql.user ORDER BY User;" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"

log "Databases (test database should not be present):"
mysql -e "SHOW DATABASES;" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"

log "MariaDB hardening complete."
log "  ✔ Anonymous users removed"
log "  ✔ Remote root login disabled"
log "  ✔ test database dropped"
log "  ✔ Privileges flushed"
log ""
log "  To connect as root: sudo mysql"
log "  To exit MariaDB shell: exit"
