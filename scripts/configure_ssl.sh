#!/bin/bash
# scripts/configure_ssl.sh
# ================================================================
# Configures HTTPS for the site:
#   1. Install Certbot + Cloudflare DNS plugin
#   2. Obtain a Let's Encrypt certificate (webroot challenge)
#   3. Generate Diffie-Hellman parameters (2048-bit)
#   4. Write the site-specific SSL include file (cert paths)
#   5. Write the shared SSL include file (protocols, ciphers, HSTS,
#      HTTP/3) — written once, reused by all sites
#   6. Rewrite the Nginx server block with HTTP redirect + HTTPS
#   7. Install WP-CLI and update WordPress URLs to HTTPS
#   8. Set up renewal cron job (force-renew 14th + 28th each month)
#
# DH parameter generation takes several minutes — do not interrupt.
#
# The certificate webroot challenge requires:
#   - DNS A record for SITE_DOMAIN resolving to this server's IP
#   - The Nginx server block to be active (Stage 17 must be done)
#   - Port 80 to be reachable (UFW must allow http — Stage 5)
#
# Covers: sections 39 and 41 of the Server Codex.
# External verification steps (SSL Labs, http3check.net) and the
# WordPress mixed-content check are manual — see README.
#
# Reads from: configs/site.conf
#             configs/server.conf
# Writes to : /etc/letsencrypt/ (Certbot)
#             /etc/nginx/ssl/dhparam.pem
#             /etc/nginx/ssl/ssl_${DOMAIN}.conf
#             /etc/nginx/ssl/ssl_all_sites.conf
#             /etc/nginx/sites-available/${DOMAIN}.conf
#             /usr/local/bin/wp (WP-CLI)
#             root crontab
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
SERVER_CONF="$BASE_DIR/configs/server.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

NGINX_SSL_DIR="/etc/nginx/ssl"
WP_CLI_BIN="/usr/local/bin/wp"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SSL] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SSL] ────────────────────────────────" \
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

if [ -z "$CERTBOT_EMAIL" ] || [ "$CERTBOT_EMAIL" = "<your-email@example.com>" ]; then
    log "ERROR: CERTBOT_EMAIL not set in $CONFIG_FILE"
    exit 1
fi

POOL_USER=$(echo "$SITE_DOMAIN" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
SITE_ROOT="/var/www/${SITE_DOMAIN}/public_html"
POOL_SOCKET="/run/php/php${SITE_PHP_VERSION}-fpm-${POOL_USER}.sock"
NGINX_CONF="/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
CERT_DIR="/etc/letsencrypt/live/${SITE_DOMAIN}"
SITE_SSL_CONF="${NGINX_SSL_DIR}/ssl_${SITE_DOMAIN}.conf"
ALL_SSL_CONF="${NGINX_SSL_DIR}/ssl_all_sites.conf"
DHPARAM="${NGINX_SSL_DIR}/dhparam.pem"

separator
log "Starting SSL configuration for: $SITE_DOMAIN"
log "  Certbot email : $CERTBOT_EMAIL"
log "  PHP socket    : $POOL_SOCKET"

# ── Step 1: Install Certbot ───────────────────────────────────────
log "Step 1/8 — Installing Certbot..."

apt update -qq >> "$LOG_FILE" 2>&1
apt install -y certbot python3-certbot-dns-cloudflare >> "$LOG_FILE" 2>&1

if ! command -v certbot &>/dev/null; then
    log "ERROR: Certbot installation failed."
    exit 1
fi
log "  Certbot installed: $(certbot --version 2>&1)"

# ── Step 2: Obtain SSL certificate ────────────────────────────────
log "Step 2/8 — Obtaining SSL certificate from Let's Encrypt..."
log "  Webroot : $SITE_ROOT"
log "  Domains : $SITE_DOMAIN, www.$SITE_DOMAIN"

if [ -f "${CERT_DIR}/fullchain.pem" ]; then
    log "  Certificate already exists at $CERT_DIR — skipping issuance."
    log "  To renew: sudo certbot renew --force-renewal"
else
    if [ ! -d "$SITE_ROOT" ]; then
        log "ERROR: Document root not found: $SITE_ROOT"
        log "       Stage 18 must be complete before obtaining the certificate."
        exit 1
    fi

    certbot certonly \
        --webroot \
        --non-interactive \
        --agree-tos \
        --email "$CERTBOT_EMAIL" \
        -w "$SITE_ROOT" \
        -d "$SITE_DOMAIN" \
        -d "www.$SITE_DOMAIN" \
        >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ] || [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
        log "ERROR: Certbot failed to obtain certificate."
        log "  Check: DNS A record for $SITE_DOMAIN points to this server's IP"
        log "  Check: Port 80 is open (UFW allows http)"
        log "  Check: Nginx is serving $SITE_ROOT over port 80"
        log "  Full Certbot log: /var/log/letsencrypt/letsencrypt.log"
        exit 1
    fi
    log "  Certificate obtained:"
    log "    fullchain : ${CERT_DIR}/fullchain.pem"
    log "    privkey   : ${CERT_DIR}/privkey.pem"
    log "    chain     : ${CERT_DIR}/chain.pem"
fi

# ── Step 3: Create SSL directory and generate DH parameters ───────
log "Step 3/8 — Generating Diffie-Hellman parameters (2048-bit)..."
log "  ⚠  This takes several minutes — do not interrupt."

mkdir -p "$NGINX_SSL_DIR"

if [ -f "$DHPARAM" ]; then
    log "  DH parameters file already exists at $DHPARAM — skipping generation."
else
    openssl dhparam -out "$DHPARAM" 2048 >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ] || [ ! -f "$DHPARAM" ]; then
        log "ERROR: DH parameter generation failed."
        exit 1
    fi
    log "  DH parameters generated: $DHPARAM"
fi

# ── Step 4: Write site-specific SSL include file ──────────────────
log "Step 4/8 — Writing site-specific SSL include: $SITE_SSL_CONF"

cat > "$SITE_SSL_CONF" << EOF
# ServerForge — site-specific SSL certificate paths for ${SITE_DOMAIN}
# One copy of this file per site; reuse ssl_all_sites.conf for shared settings.
ssl_certificate         ${CERT_DIR}/fullchain.pem;
ssl_certificate_key     ${CERT_DIR}/privkey.pem;
ssl_trusted_certificate ${CERT_DIR}/chain.pem;
EOF

log "  $SITE_SSL_CONF written."

# ── Step 5: Write shared SSL include file ─────────────────────────
log "Step 5/8 — Writing shared SSL config: $ALL_SSL_CONF"

if [ -f "$ALL_SSL_CONF" ]; then
    log "  ssl_all_sites.conf already exists — skipping (shared across all sites)."
    log "  Delete $ALL_SSL_CONF and re-run to regenerate."
else
    cat > "$ALL_SSL_CONF" << 'EOF'
# ServerForge — Shared SSL configuration for all sites
# Managed by: serverforge/scripts/configure_ssl.sh
# Results in an A+ rating at ssllabs.com (as of May 2025)
# Include this in every HTTPS server block — once per server, not per site.

# SSL session cache — shared across all worker processes (20 MB)
ssl_session_cache   shared:SSL:20m;
ssl_session_timeout 180m;

# Protocol versions — TLS 1.2 and 1.3 only; older versions disabled
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;

# Curated AEAD cipher suite ordered strongest first
# ssl_ciphers must be on a single line — do not split
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

ssl_dhparam /etc/nginx/ssl/dhparam.pem;

# NOTE: Let's Encrypt removed OCSP stapling support on 7 May 2025.
# If using Let's Encrypt certificates, keep both lines commented out.
#ssl_stapling        on;
#ssl_stapling_verify on;

# Resolver (Cloudflare) — used for OCSP and upstream DNS lookups
resolver         1.1.1.1 1.0.0.1;
resolver_timeout 15s;

# Disable TLS session tickets to preserve forward secrecy
ssl_session_tickets off;

# HSTS — instruct browsers to connect via HTTPS only for one year
# Once ALL subdomains use HTTPS, add 'includeSubDomains;' to the header.
add_header Strict-Transport-Security "max-age=31536000;" always;

# HTTP/3 and QUIC — advertise availability and enable QUIC retry
ssl_early_data on;
add_header Alt-Svc 'h3=":$server_port"; ma=86400';
add_header x-quic 'H3';
quic_retry on;
EOF
    log "  ssl_all_sites.conf written."
fi

# ── Step 6: Rewrite Nginx server block for HTTPS ──────────────────
log "Step 6/8 — Rewriting Nginx server block for HTTPS..."

# Back up before replacing
cp "$NGINX_CONF" "${NGINX_CONF}.pre-ssl.bak"

cat > "$NGINX_CONF" << EOF
# ServerForge — Nginx server block for ${SITE_DOMAIN}
# Updated by: serverforge/scripts/configure_ssl.sh

# HTTP → HTTPS permanent redirect (both bare domain and www)
server {
    listen 80;
    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};
    return 301 https://${SITE_DOMAIN}\$request_uri;
}

# HTTPS server block
server {

    # SSL + HTTP/2
    listen 443 ssl;
    http2  on;

    # HTTP/3 via QUIC — reuseport is for the FIRST site on the server only.
    # For any additional site, use: listen 443 quic;  (no reuseport)
    listen 443 quic reuseport;
    http3  on;

    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};

    root  /var/www/${SITE_DOMAIN}/public_html;
    index index.php;

    # Site-specific certificate paths
    include /etc/nginx/ssl/ssl_${SITE_DOMAIN}.conf;

    # Shared TLS protocols, ciphers, HSTS, HTTP/3 settings
    include /etc/nginx/ssl/ssl_all_sites.conf;

    # WordPress permalink handling
    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    # PHP requests → PHP-FPM via pool-specific socket
    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${POOL_SOCKET};
        include /etc/nginx/includes/fastcgi_optimize.conf;
    }

    # Static asset browser caching
    include /etc/nginx/includes/browser_caching.conf;

    # Per-site access log (buffered writes reduce disk I/O)
    access_log /var/log/nginx/${SITE_DOMAIN}.access.log combined buffer=256k flush=60m;

    # Per-site error log
    error_log /var/log/nginx/${SITE_DOMAIN}.error.log;

}
EOF

log "  Nginx server block rewritten with HTTPS configuration."

# Test and reload
nginx -t >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: Nginx config test failed."
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    log "  Restoring backup: ${NGINX_CONF}.pre-ssl.bak"
    cp "${NGINX_CONF}.pre-ssl.bak" "$NGINX_CONF"
    exit 1
fi

systemctl reload nginx >> "$LOG_FILE" 2>&1
log "  Nginx reloaded. Site is now serving HTTPS."

# ── Step 7: Install WP-CLI and update WordPress URLs ──────────────
log "Step 7/8 — Installing WP-CLI and updating WordPress site URLs..."

if [ ! -f "$WP_CLI_BIN" ]; then
    log "  Downloading WP-CLI..."
    curl -s -o /tmp/wp-cli.phar \
        "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" \
        >> "$LOG_FILE" 2>&1

    if [ -f /tmp/wp-cli.phar ] && [ -s /tmp/wp-cli.phar ]; then
        chmod +x /tmp/wp-cli.phar
        mv /tmp/wp-cli.phar "$WP_CLI_BIN"
        log "  WP-CLI installed at $WP_CLI_BIN"
    else
        log "  WARN: WP-CLI download failed. Update WordPress URLs manually:"
        log "    WordPress Dashboard → Settings → General"
        log "    Change both URL fields from http:// to https://${SITE_DOMAIN}"
    fi
else
    log "  WP-CLI already installed."
fi

# Update WordPress URLs only if the database tables exist (wizard complete)
if [ -f "$WP_CLI_BIN" ]; then
    CURRENT_URL=$(sudo -u "$POOL_USER" "$WP_CLI_BIN" option get siteurl \
        --path="$SITE_ROOT" --allow-root 2>/dev/null)

    if [ -n "$CURRENT_URL" ]; then
        if echo "$CURRENT_URL" | grep -q "^https://"; then
            log "  WordPress URLs already use HTTPS ($CURRENT_URL) — skipping update."
        else
            log "  Updating WordPress URLs from http:// to https://..."
            sudo -u "$POOL_USER" "$WP_CLI_BIN" option update siteurl \
                "https://${SITE_DOMAIN}" --path="$SITE_ROOT" --allow-root \
                >> "$LOG_FILE" 2>&1
            sudo -u "$POOL_USER" "$WP_CLI_BIN" option update home \
                "https://${SITE_DOMAIN}" --path="$SITE_ROOT" --allow-root \
                >> "$LOG_FILE" 2>&1
            log "  WordPress siteurl → https://${SITE_DOMAIN}"
            log "  WordPress home    → https://${SITE_DOMAIN}"
        fi
    else
        log "  WordPress database not initialised yet (browser wizard not run)."
        log "  After completing the wizard, update WordPress URLs:"
        log "    WordPress Dashboard → Settings → General"
        log "    OR: sudo -u ${POOL_USER} wp option update siteurl 'https://${SITE_DOMAIN}' --path=${SITE_ROOT}"
        log "        sudo -u ${POOL_USER} wp option update home   'https://${SITE_DOMAIN}' --path=${SITE_ROOT}"
    fi
fi

# ── Step 8: Set up renewal cron job ───────────────────────────────
log "Step 8/8 — Setting up SSL renewal cron job..."

# Force-renew on the 14th and 28th of every month at 01:00.
# Reload Nginx at 02:00 so the new certificates are picked up.
CRON_RENEW="00 1 14,28 * * certbot renew --force-renewal >/dev/null 2>&1"
CRON_RELOAD="00 2 14,28 * * systemctl reload nginx >/dev/null 2>&1"

# Read existing root crontab (suppress error if empty)
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

CRON_UPDATED=false

if echo "$EXISTING_CRON" | grep -qF "certbot renew --force-renewal"; then
    log "  Certbot renewal cron already present — skipping."
else
    (echo "$EXISTING_CRON"; echo "$CRON_RENEW"; echo "$CRON_RELOAD") \
        | crontab -
    CRON_UPDATED=true
    log "  Renewal cron added: $CRON_RENEW"
    log "  Nginx reload cron added: $CRON_RELOAD"
fi

# ── Dry-run verification ──────────────────────────────────────────
log "Running Certbot dry-run to verify renewal setup..."
certbot renew --dry-run >> "$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
    log "  Certbot dry-run: all simulated renewals succeeded."
else
    log "  WARN: Certbot dry-run reported issues. Check:"
    log "    /var/log/letsencrypt/letsencrypt.log"
fi

# ── Summary ───────────────────────────────────────────────────────
separator
log "SSL configuration complete."
log "  ✔ Certificate     : ${CERT_DIR}/fullchain.pem"
log "  ✔ DH parameters   : $DHPARAM"
log "  ✔ Site SSL conf   : $SITE_SSL_CONF"
log "  ✔ Shared SSL conf : $ALL_SSL_CONF"
log "  ✔ Nginx block     : HTTP redirect + HTTPS with HTTP/2 + HTTP/3"
log "  ✔ WP-CLI          : $WP_CLI_BIN"
log "  ✔ Renewal cron    : 1:00 AM on 14th + 28th monthly"
log ""
log "  Verify your setup (manual steps):"
log "    SSL rating : https://www.ssllabs.com/ssltest/?d=${SITE_DOMAIN}"
log "    HTTP/3     : https://http3check.net/?host=${SITE_DOMAIN}"
log "    Redirects  : curl -I http://${SITE_DOMAIN}"
log "                 curl -I https://${SITE_DOMAIN}"
