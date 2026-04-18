#!/bin/bash
# scripts/optimize_mariadb.sh
# ================================================================
# Optimizes MariaDB for production use by:
#   1. Backing up and writing /etc/mysql/mariadb.conf.d/50-server.cnf
#      with Performance Schema, skip-name-resolve, binary log
#      retention, and InnoDB buffer pool/log file size settings.
#   2. Applying binary log retention at runtime via SQL.
#   3. Creating a systemd drop-in to raise the MariaDB open file
#      descriptor limit (LimitNOFILE).
#   4. Downloading MySQLTuner into ~/MySQLTuner/ for periodic use.
#   5. Adding the 'mariare' bash alias for SERVER_USER.
#
# ⚠  InnoDB log file size REQUIRES a full MariaDB stop before the
#    config change and a start after. The script handles this safely.
#    Do not interrupt the script between the stop and start steps.
#
# Reads from: configs/mariadb.conf
#             configs/server.conf (for SERVER_USER)
# Writes to : /etc/mysql/mariadb.conf.d/50-server.cnf
#             /etc/systemd/system/mariadb.service.d/limits.conf
#             /home/${SERVER_USER}/MySQLTuner/mysqltuner.pl
#             /home/${SERVER_USER}/.bash_aliases
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/mariadb.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
SYSTEMD_DROP_IN_DIR="/etc/systemd/system/mariadb.service.d"
SYSTEMD_DROP_IN="${SYSTEMD_DROP_IN_DIR}/limits.conf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MARIADB_OPT] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MARIADB_OPT] ────────────────────────────────" \
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
log "Starting MariaDB optimization..."
log "  InnoDB buffer pool : $MARIADB_INNODB_BUFFER_POOL_SIZE"
log "  InnoDB log size    : $MARIADB_INNODB_LOG_FILE_SIZE"
log "  Expire logs days   : $MARIADB_EXPIRE_LOGS_DAYS"
log "  Open file limit    : $MARIADB_OPEN_FILE_LIMIT"

# ── Step 1: Back up 50-server.cnf ────────────────────────────────
log "Step 1/6 — Backing up $MARIADB_CNF..."

if [ ! -f "$MARIADB_CNF" ]; then
    log "ERROR: $MARIADB_CNF not found. Is MariaDB installed?"
    exit 1
fi

if [ ! -f "${MARIADB_CNF}.bak" ]; then
    cp "$MARIADB_CNF" "${MARIADB_CNF}.bak"
    log "  Backup created: ${MARIADB_CNF}.bak"
else
    log "  Backup already exists — skipping."
fi

# ── Step 2: Stop MariaDB before changing innodb_log_file_size ────
# Changing innodb_log_file_size while MariaDB is running and
# restarting can corrupt InnoDB tables. Stop first, always.
log "Step 2/6 — Stopping MariaDB (required for innodb_log_file_size change)..."
systemctl stop mariadb >> "$LOG_FILE" 2>&1

if systemctl is-active --quiet mariadb; then
    log "ERROR: MariaDB did not stop cleanly. Aborting to protect data."
    exit 1
fi
log "  MariaDB stopped."

# ── Step 3: Write the optimized 50-server.cnf ────────────────────
# We inject our tuning block into the [mysqld] section by appending
# directives after the existing Basic Settings. The original file
# structure and all existing directives are preserved — only our
# ServerForge block is added/replaced.
log "Step 3/6 — Writing optimization directives to $MARIADB_CNF..."

# Remove any previously written ServerForge block to make idempotent
if grep -q "# ServerForge optimizations" "$MARIADB_CNF"; then
    # Remove everything from the ServerForge marker to the next section
    # header or end of file (handles re-runs cleanly)
    sed -i '/# ServerForge optimizations/,/^\[/{/^\[/!d; /# ServerForge/d}' \
        "$MARIADB_CNF"
    log "  Existing ServerForge block removed for refresh."
fi

# Append the ServerForge optimization block to the end of [mysqld] section
cat >> "$MARIADB_CNF" << EOF

# ServerForge optimizations — managed by serverforge/scripts/optimize_mariadb.sh

[mysqld]

# ── Performance Schema ────────────────────────────────────────────
# Enables internal server event monitoring. Used by MySQLTuner and
# other diagnostic tools to profile query stages and thread activity.
performance_schema                              = ON
performance-schema-instrument                   = 'stage/%=ON'
performance-schema-consumer-events-stages-current = ON
performance-schema-consumer-events-stages-history = ON
performance-schema-consumer-events-stages-history-long = ON

# ── DNS Lookups ───────────────────────────────────────────────────
# Disables reverse DNS lookup on every new connection. The double
# DNS round-trip on each connection adds measurable latency.
# Safe to skip when all grants use IP addresses or 'localhost'.
skip-name-resolve

# ── Binary Log Retention ──────────────────────────────────────────
# Default of 10 days can fill disk on a small VPS. 3 days is
# sufficient for a single-instance server with no replication.
expire_logs_days = ${MARIADB_EXPIRE_LOGS_DAYS}

# ── InnoDB Storage Engine ──────────────────────────────────────────
# Buffer pool: the primary RAM cache for table data and indexes.
# ~80% of total server RAM is the recommended production value.
innodb_buffer_pool_size = ${MARIADB_INNODB_BUFFER_POOL_SIZE}

# Log file: the InnoDB redo/transaction log.
# ~25% of innodb_buffer_pool_size is the recommended value.
# ⚠  Requires MariaDB to be STOPPED before changing this value.
innodb_log_file_size = ${MARIADB_INNODB_LOG_FILE_SIZE}
EOF

if [ $? -ne 0 ]; then
    log "ERROR: Failed to write $MARIADB_CNF"
    log "  Restoring backup..."
    cp "${MARIADB_CNF}.bak" "$MARIADB_CNF"
    systemctl start mariadb >> "$LOG_FILE" 2>&1
    exit 1
fi
log "  Optimization directives written to $MARIADB_CNF"

# ── Step 4: Start MariaDB with new configuration ──────────────────
log "Step 4/6 — Starting MariaDB with new configuration..."
systemctl start mariadb >> "$LOG_FILE" 2>&1

# Give MariaDB a moment to fully initialize
sleep 3

if ! systemctl is-active --quiet mariadb; then
    log "ERROR: MariaDB failed to start after config change."
    log "  Check: journalctl -xeu mariadb"
    log "  Attempting to restore backup and restart..."
    cp "${MARIADB_CNF}.bak" "$MARIADB_CNF"
    systemctl start mariadb >> "$LOG_FILE" 2>&1
    exit 1
fi
log "  MariaDB started successfully."

# ── Apply binary log retention at runtime ────────────────────────
log "  Applying binary log retention at runtime..."
mysql -e "SET GLOBAL expire_logs_days = ${MARIADB_EXPIRE_LOGS_DAYS};" >> "$LOG_FILE" 2>&1
mysql -e "FLUSH BINARY LOGS;" >> "$LOG_FILE" 2>&1
log "  Binary logs flushed (old logs purged to $MARIADB_EXPIRE_LOGS_DAYS days)."

# ── Verify InnoDB settings ────────────────────────────────────────
log "  Verifying InnoDB settings:"
mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"
mysql -e "SHOW VARIABLES LIKE 'innodb_log_file_size';" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"
mysql -e "SHOW VARIABLES LIKE 'expire_logs_days';" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"
mysql -e "SHOW VARIABLES LIKE 'performance_schema';" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"
mysql -e "SHOW VARIABLES LIKE 'skip_name_resolve';" 2>> "$LOG_FILE" \
    | tee -a "$LOG_FILE"

# ── Step 5: Systemd open file limit drop-in ───────────────────────
log "Step 5/6 — Creating MariaDB systemd open file limit drop-in..."

mkdir -p "$SYSTEMD_DROP_IN_DIR"

cat > "$SYSTEMD_DROP_IN" << EOF
# ServerForge — MariaDB open file limit override
# Managed by: serverforge/scripts/optimize_mariadb.sh
[Service]
LimitNOFILE=${MARIADB_OPEN_FILE_LIMIT}
EOF

systemctl daemon-reload >> "$LOG_FILE" 2>&1
systemctl restart mariadb >> "$LOG_FILE" 2>&1

sleep 2

if ! systemctl is-active --quiet mariadb; then
    log "ERROR: MariaDB failed to start after applying open file limit."
    exit 1
fi

# Verify the new limit is active
MARIADB_PID=$(pgrep -x mysqld | head -1)
if [ -n "$MARIADB_PID" ]; then
    log "  MariaDB PID: $MARIADB_PID"
    log "  Open file limit (Max open files):"
    grep "Max open files" "/proc/${MARIADB_PID}/limits" 2>/dev/null \
        | tee -a "$LOG_FILE" \
        || log "  (Could not read /proc/$MARIADB_PID/limits — verify manually)"
else
    log "  WARN: Could not find MariaDB PID to verify limit."
fi

log "  Drop-in written: $SYSTEMD_DROP_IN"

# ── Step 6: Download MySQLTuner ───────────────────────────────────
log "Step 6/6 — Downloading MySQLTuner to ${USER_HOME}/MySQLTuner/..."

MYSQLTUNER_DIR="${USER_HOME}/MySQLTuner"
MYSQLTUNER_SCRIPT="${MYSQLTUNER_DIR}/mysqltuner.pl"

if [ -f "$MYSQLTUNER_SCRIPT" ]; then
    log "  MySQLTuner already exists — skipping download."
else
    mkdir -p "$MYSQLTUNER_DIR"
    wget -q -O "$MYSQLTUNER_SCRIPT" "http://mysqltuner.pl/" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ] || [ ! -s "$MYSQLTUNER_SCRIPT" ]; then
        log "  WARN: MySQLTuner download failed. Download manually:"
        log "    wget http://mysqltuner.pl/ -O ~/MySQLTuner/mysqltuner.pl"
    else
        chmod +x "$MYSQLTUNER_SCRIPT"
        chown -R "${SERVER_USER}:${SERVER_USER}" "$MYSQLTUNER_DIR"
        log "  MySQLTuner downloaded: $(du -sh "$MYSQLTUNER_SCRIPT" | cut -f1)"
        log "  Run with: sudo ${MYSQLTUNER_SCRIPT}"
        log "  ⚠  Run only after the server has been under real load"
        log "     for 60–90 days — recommendations need runtime data."
    fi
fi

# ── Add mariare alias ─────────────────────────────────────────────
ALIASES_FILE="${USER_HOME}/.bash_aliases"
touch "$ALIASES_FILE"

if grep -q "# ServerForge MariaDB aliases" "$ALIASES_FILE" 2>/dev/null; then
    log "  mariare alias already present — skipping."
else
    cat >> "$ALIASES_FILE" << 'EOF'

# ServerForge MariaDB aliases — added by serverforge/scripts/optimize_mariadb.sh
alias mariare='sudo systemctl restart mariadb'
EOF
    chown "${SERVER_USER}:${SERVER_USER}" "$ALIASES_FILE"
    log "  mariare alias added to ${USER_HOME}/.bash_aliases"
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "MariaDB optimization complete."
log "  ✔ 50-server.cnf    → Performance Schema, skip-name-resolve, InnoDB tuning"
log "  ✔ Buffer pool      → $MARIADB_INNODB_BUFFER_POOL_SIZE"
log "  ✔ Log file size    → $MARIADB_INNODB_LOG_FILE_SIZE"
log "  ✔ Binary log TTL   → $MARIADB_EXPIRE_LOGS_DAYS days"
log "  ✔ Open file limit  → $MARIADB_OPEN_FILE_LIMIT (systemd drop-in)"
log "  ✔ MySQLTuner       → ${MYSQLTUNER_SCRIPT}"
log "  ✔ mariare alias    → sudo systemctl restart mariadb"
