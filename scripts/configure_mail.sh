#!/bin/bash
# scripts/configure_mail.sh
# ================================================================
# Installs msmtp and configures it to relay outbound mail through
# an external SMTP server (default: Gmail), enabling WordPress to
# send transactional email via PHP's mail() function without any
# SMTP plugin.
#
# Two config files are created:
#   ~/.msmtprc         — used by the admin user for CLI mail
#   /etc/msmtprc       — used by PHP/www-data for WordPress mail
#
# Both config files share identical SMTP credentials. The only
# difference is the logfile path: ~/.msmtp.log vs /var/log/msmtp.log.
#
# ⚠  Credential security:
#    msmtp refuses to run if its config file is world-readable.
#    ~/.msmtprc is set to 600 (root-only). /etc/msmtprc is set
#    to 660 owned by www-data:www-data.
#
# ⚠  Not automated (interactive steps — do manually after setup):
#    Testing PHP mail via sudo -u www-data php php_mail_test.php
#    requires temporarily changing home directory permissions.
#    See the README for the full testing procedure.
#
# Reads from: configs/mail.conf
#             configs/server.conf (for SERVER_USER home directory)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/mail.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MAIL] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MAIL] ────────────────────────────────" \
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

# ── Optional stage: skip gracefully if credentials are not set ────
# Mail is not required for WordPress to function. If SMTP_USER,
# SMTP_PASSWORD, or SMTP_FROM are empty, skip this stage entirely
# and let the pipeline continue. The user can configure mail.conf
# and re-run this stage manually at any time.
_mail_unconfigured=0
for var in SMTP_USER SMTP_PASSWORD SMTP_FROM; do
    val="${!var}"
    if [ -z "$val" ] || echo "$val" | grep -q '^<'; then
        _mail_unconfigured=1
        break
    fi
done

if [ "$_mail_unconfigured" -eq 1 ]; then
    separator
    log "Mail credentials are not configured in configs/mail.conf — skipping."
    log "  To enable mail later, fill in SMTP_USER, SMTP_PASSWORD, and SMTP_FROM"
    log "  in configs/mail.conf, then re-run: sudo bash scripts/configure_mail.sh"
    log "  (WordPress will function normally without mail configured.)"
    exit 0
fi

# Validate remaining required fields now that credentials are present
for var in SMTP_HOST SMTP_PORT; do
    val="${!var}"
    if [ -z "$val" ] || echo "$val" | grep -q '^<'; then
        log "ERROR: $var is not configured in configs/mail.conf"
        exit 1
    fi
done

if [ -z "$SERVER_USER" ] || [ "$SERVER_USER" = "<your-username>" ]; then
    log "ERROR: SERVER_USER is not set in configs/server.conf"
    exit 1
fi

USER_HOME="/home/${SERVER_USER}"
if [ ! -d "$USER_HOME" ]; then
    log "ERROR: Home directory not found: $USER_HOME"
    exit 1
fi

separator
log "Starting mail (msmtp) configuration..."
log "  SMTP host : $SMTP_HOST:$SMTP_PORT"
log "  SMTP user : $SMTP_USER"
log "  From      : $SMTP_FROM"

# ── Step 1: Install msmtp ─────────────────────────────────────────
log "Step 1/5 — Installing msmtp and msmtp-mta..."

if dpkg -s msmtp &>/dev/null && dpkg -s msmtp-mta &>/dev/null; then
    log "  msmtp already installed — skipping."
else
    apt update -qq >> "$LOG_FILE" 2>&1
    # Answer 'no' to AppArmor prompt — the AppArmor profile has known
    # edge cases that produce confusing permission denied errors.
    DEBIAN_FRONTEND=noninteractive apt install -y msmtp msmtp-mta >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR: msmtp installation failed."
        exit 1
    fi
    log "  msmtp installed: $(msmtp --version 2>&1 | head -1)"
fi

# ── Step 2: Create admin user ~/.msmtprc ─────────────────────────
log "Step 2/5 — Writing ${USER_HOME}/.msmtprc..."

cat > "${USER_HOME}/.msmtprc" << EOF
defaults
# TLS DIRECTIVES
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
# LOGGING
logfile ${USER_HOME}/.msmtp.log

# ACCOUNT: MAIL
account MAIL
host ${SMTP_HOST}
port ${SMTP_PORT}
auth on
user ${SMTP_USER}
password ${SMTP_PASSWORD}
from ${SMTP_FROM}

# SET DEFAULT ACCOUNT
account default : MAIL
EOF

# msmtp refuses to run if the config is world-readable
chmod 600 "${USER_HOME}/.msmtprc"
chown "${SERVER_USER}:${SERVER_USER}" "${USER_HOME}/.msmtprc"
log "  ${USER_HOME}/.msmtprc written (permissions: 600, owner: ${SERVER_USER})"

# ── Step 3: Create admin user log file ───────────────────────────
log "Step 3/5 — Creating ${USER_HOME}/.msmtp.log..."

if [ ! -f "${USER_HOME}/.msmtp.log" ]; then
    touch "${USER_HOME}/.msmtp.log"
    chown "${SERVER_USER}:${SERVER_USER}" "${USER_HOME}/.msmtp.log"
    chmod 660 "${USER_HOME}/.msmtp.log"
    log "  ${USER_HOME}/.msmtp.log created."
else
    log "  ${USER_HOME}/.msmtp.log already exists — skipping."
fi

# ── Step 4: Create /etc/msmtprc for PHP/www-data ────────────────
log "Step 4/5 — Writing /etc/msmtprc (for PHP www-data)..."

# Copy the user config, then patch the logfile path — the home-dir
# path (~/.msmtp.log) is invalid for www-data which has no home dir.
cp "${USER_HOME}/.msmtprc" /etc/msmtprc

sed -i "s|logfile .*|logfile /var/log/msmtp.log|" /etc/msmtprc

chown www-data:www-data /etc/msmtprc
chmod 660 /etc/msmtprc
log "  /etc/msmtprc written (permissions: 660, owner: www-data:www-data)"

# ── Step 5: Create PHP mail log file ─────────────────────────────
log "Step 5/5 — Creating /var/log/msmtp.log..."

if [ ! -f /var/log/msmtp.log ]; then
    touch /var/log/msmtp.log
    chown www-data:adm /var/log/msmtp.log
    chmod 640 /var/log/msmtp.log
    log "  /var/log/msmtp.log created (owner: www-data:adm, permissions: 640)"
else
    log "  /var/log/msmtp.log already exists — skipping."
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "Mail configuration complete."
log "  ✔ msmtp installed"
log "  ✔ Admin config  : ${USER_HOME}/.msmtprc (600)"
log "  ✔ Admin log     : ${USER_HOME}/.msmtp.log (660)"
log "  ✔ PHP config    : /etc/msmtprc (660, www-data)"
log "  ✔ PHP log       : /var/log/msmtp.log (640, www-data:adm)"
log ""
log "  To test CLI mail sending (as ${SERVER_USER}):"
log "    msmtp recipient@example.com"
log "    (type message, press Enter, then Ctrl+D to send)"
log ""
log "  To test PHP mail sending, see README — this step is interactive"
log "  and requires a temporary home directory permission change."
