#!/bin/bash
# configure_mail.sh — Stage 1
# ================================================================
# Installs msmtp as a lightweight SMTP relay, wired up two ways:
#   - /root/.msmtprc   → used by main.sh's own notification emails
#   - /etc/msmtprc     → used by PHP/WordPress's mail() (www-data)
#
# msmtp-mta makes msmtp a drop-in replacement for /usr/sbin/sendmail,
# so PHP's mail() works transparently once this stage completes —
# no WordPress-side configuration needed.
#
# Sends a real test email at the end and fails the stage (exit 1)
# if it can't — catches a bad App Password immediately rather than
# leaving notifications silently broken for the rest of the run.
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
MAIL_CONF="$BASE_DIR/configs/mail.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [MAIL] $1" | tee -a "$LOG_FILE"
}

log "────────────────────────────────"
log "Starting mail configuration..."

# ── Validate config ────────────────────────────────────────────
if [ ! -f "$MAIL_CONF" ]; then
    log "ERROR: $MAIL_CONF not found."
    exit 1
fi

source "$MAIL_CONF"

for var in ADMIN_EMAIL SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD; do
    if [ -z "${!var}" ]; then
        log "ERROR: $var is not set in configs/mail.conf"
        exit 1
    fi
done

# ── Install msmtp ──────────────────────────────────────────────
# Non-interactive so any debconf prompts (e.g. AppArmor) don't hang
# an unattended/rebooting run.
log "Refreshing package index (Stage 1 runs before System Updates, so this hasn't happened yet)..."
apt-get update >> "$LOG_FILE" 2>&1

log "Installing msmtp and msmtp-mta..."
DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp msmtp-mta >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: msmtp installation failed. See $LOG_FILE for details."
    exit 1
fi

# ── Write one msmtprc, deploy it to both locations ────────────
write_msmtprc() {
    local path="$1"
    local logpath="$2"

    cat > "$path" <<EOF
defaults
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile $logpath

account MAIL
host $SMTP_HOST
port $SMTP_PORT
auth on
user $SMTP_USER
password $SMTP_PASSWORD
from $SMTP_USER

account default : MAIL
EOF
}

log "Step 1/3 — Writing CLI config (/root/.msmtprc) for admin notifications..."
write_msmtprc /root/.msmtprc /root/.msmtp.log
chmod 600 /root/.msmtprc
touch /root/.msmtp.log
chmod 600 /root/.msmtp.log

log "Step 2/3 — Writing PHP config (/etc/msmtprc) for WordPress mail()..."
write_msmtprc /etc/msmtprc /var/log/msmtp.log
chown www-data:www-data /etc/msmtprc
chmod 600 /etc/msmtprc
touch /var/log/msmtp.log
chown www-data:adm /var/log/msmtp.log
chmod 640 /var/log/msmtp.log

# ── Verify: send a real test email ─────────────────────────────
log "Step 3/3 — Sending test email to $ADMIN_EMAIL..."
{
    echo "To: $ADMIN_EMAIL"
    echo "Subject: ServerForge — mail configured successfully"
    echo
    echo "If you're reading this, msmtp is relaying correctly through $SMTP_HOST."
    echo "Stage failure/completion notifications will be sent to this address."
} | msmtp "$ADMIN_EMAIL" 2>>"$LOG_FILE"

if [ $? -ne 0 ]; then
    log "ERROR: Test email failed to send. Check SMTP_USER/SMTP_PASSWORD in"
    log "       configs/mail.conf (must be a Google App Password, not your"
    log "       regular Gmail password) and check $LOG_FILE for details."
    exit 1
fi

log "Test email sent — check $ADMIN_EMAIL to confirm delivery."
log "Mail configuration complete."
exit 0
