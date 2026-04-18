#!/bin/bash
# scripts/nginx_application_hardening.sh
# ================================================================
# Adds the final Nginx application-layer hardening for the site:
#
#   1. Write /etc/nginx/includes/http_headers.conf
#      Security response headers: Referrer-Policy, X-Content-Type-Options,
#      X-Frame-Options, X-XSS-Protection, Permissions-Policy
#
#   2. Rewrite /etc/nginx/includes/browser_caching.conf
#      Each location block now also includes http_headers.conf so
#      security headers are present on static asset responses.
#      (Nginx add_header does NOT inherit from parent context when a
#      child location block defines its own add_header directives.)
#
#   3. Write /etc/nginx/includes/nginx_security_directives.conf
#      WordPress WAF ruleset: blocks sensitive file access, PHP
#      execution in writable dirs, bad request methods, path
#      traversal, SQL injection, file injection, common exploits,
#      spam query strings, and known scanner user agents.
#
#   4. Add limit_req_zone to the nginx.conf http block
#      Creates the 'wp' rate limiting zone (30r/m per IP, 10MB pool)
#      for use by the rate limiting include file.
#
#   5. Write /etc/nginx/includes/rate_limiting_${DOMAIN}.conf
#      Rate-limited exact-match location blocks for wp-login.php and
#      xmlrpc.php (burst=20, nodelay, status=444 on excess).
#
#   6. Rewrite the site Nginx server block
#      Complete final-state rewrite incorporating all new includes.
#      Hotlinking protection added if HOTLINK_PROTECTION=nginx.
#
#   7. Test and reload Nginx
#
# Section 44 (DDoS protection) requires no scripted commands — handle
# DDoS at the CDN/host layer (Cloudflare recommended). See README.
#
# Section 47 (hotlinking) Cloudflare option requires a dashboard toggle
# in Scrape Shield — not automatable. If HOTLINK_PROTECTION=nginx, a
# valid_referers location block is written into the server block.
#
# Covers: sections 42, 43, 44 (architectural note only), 45, 47.
#
# Reads from: configs/site.conf
# Writes to : /etc/nginx/includes/http_headers.conf
#             /etc/nginx/includes/browser_caching.conf (rewrite)
#             /etc/nginx/includes/nginx_security_directives.conf
#             /etc/nginx/nginx.conf (limit_req_zone insertion)
#             /etc/nginx/includes/rate_limiting_${DOMAIN}.conf
#             /etc/nginx/sites-available/${DOMAIN}.conf (rewrite)
# ================================================================

BASE_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
CONFIG_FILE="$BASE_DIR/configs/site.conf"
LOG_FILE="$BASE_DIR/serverforge.log"

NGINX_INCLUDES="/etc/nginx/includes"
NGINX_CONF="/etc/nginx/nginx.conf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [NGINX_APP] $1" | tee -a "$LOG_FILE"
}

separator() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [NGINX_APP] ────────────────────────────────" \
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

POOL_USER=$(echo "$SITE_DOMAIN" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
POOL_SOCKET="/run/php/php${SITE_PHP_VERSION}-fpm-${POOL_USER}.sock"
NGINX_SITE_CONF="/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
RATE_LIMIT_CONF="${NGINX_INCLUDES}/rate_limiting_${SITE_DOMAIN}.conf"

separator
log "Starting Nginx application hardening..."
log "  Domain             : $SITE_DOMAIN"
log "  Pool socket        : $POOL_SOCKET"
log "  Hotlink protection : $HOTLINK_PROTECTION"

# ── Step 1: Write http_headers.conf ──────────────────────────────
log "Step 1/7 — Writing ${NGINX_INCLUDES}/http_headers.conf..."

cat > "${NGINX_INCLUDES}/http_headers.conf" << 'EOF'
##
# HTTP SECURITY RESPONSE HEADERS
# Managed by: serverforge/scripts/nginx_application_hardening.sh
#
# Include this file in every server block AND inside each static
# asset location block in browser_caching.conf — Nginx add_header
# does NOT inherit from parent contexts when a child location block
# defines its own add_header directives.
##

# Controls how much referrer info is sent with requests leaving the site.
# strict-origin-when-cross-origin: full URL for same-origin, origin only
# for cross-origin HTTPS, nothing for cross-origin HTTP.
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Prevents MIME-type sniffing — browsers must respect the declared
# Content-Type header rather than guessing from file contents.
add_header X-Content-Type-Options "nosniff" always;

# Prevents the site from being embedded in an iframe on another origin.
# Mitigates clickjacking attacks.
add_header X-Frame-Options "sameorigin" always;

# Legacy XSS filter for older browsers (Chrome/Firefox have removed theirs).
# A proper Content-Security-Policy is the correct long-term solution.
add_header X-XSS-Protection "1; mode=block" always;

# Restricts browser access to hardware APIs and sensitive features.
# Disables geolocation, camera, microphone, sensors, clipboard, payments,
# and USB by default. Allows fullscreen for same-origin and YouTube
# (required for embedded video players in WordPress).
add_header Permissions-Policy 'accelerometer=(), camera=(), clipboard-read=(), clipboard-write=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=(), fullscreen=(self "https://www.youtube.com")' always;
EOF

log "  http_headers.conf written (5 security response headers)."

# ── Step 2: Rewrite browser_caching.conf ─────────────────────────
# Each location block must include http_headers.conf explicitly —
# add_header does not inherit from parent context when child blocks
# define their own add_header. Also adds etag and if_modified_since
# for conditional request support.
log "Step 2/7 — Rewriting ${NGINX_INCLUDES}/browser_caching.conf..."

cp "${NGINX_INCLUDES}/browser_caching.conf" \
   "${NGINX_INCLUDES}/browser_caching.conf.bak" 2>/dev/null || true

cat > "${NGINX_INCLUDES}/browser_caching.conf" << 'EOF'
##
# BROWSER CACHING
# Managed by: serverforge/scripts/nginx_application_hardening.sh
#
# Each location block explicitly includes http_headers.conf — add_header
# directives do NOT inherit from parent server block contexts when a child
# location block defines its own add_header.
##

# Media, documents, and binary assets — cache for 1 year
location ~* \.(webp|3gp|gif|jpg|jpeg|png|ico|wmv|avi|asf|asx|mpg|mpeg|mp4|pls|mp3|mid|wav|swf|flv|exe|zip|tar|rar|gz|tgz|bz2|uha|7z|doc|docx|xls|xlsx|pdf|iso)$ {
    expires 365d;
    etag on;
    if_modified_since exact;
    add_header Pragma "public";
    add_header Cache-Control "public, no-transform";
    try_files $uri $uri/ /index.php?$args;
    include /etc/nginx/includes/http_headers.conf;
    access_log off;
}

# JavaScript — cache for 30 days
location ~* \.(js)$ {
    expires 30d;
    etag on;
    if_modified_since exact;
    add_header Pragma "public";
    add_header Cache-Control "public, no-transform";
    try_files $uri $uri/ /index.php?$args;
    include /etc/nginx/includes/http_headers.conf;
    access_log off;
}

# Stylesheets — cache for 30 days
location ~* \.(css)$ {
    expires 30d;
    etag on;
    if_modified_since exact;
    add_header Pragma "public";
    add_header Cache-Control "public, no-transform";
    try_files $uri $uri/ /index.php?$args;
    include /etc/nginx/includes/http_headers.conf;
    access_log off;
}

# Web fonts — cache for 30 days
location ~* \.(eot|svg|ttf|woff|woff2)$ {
    expires 30d;
    etag on;
    if_modified_since exact;
    add_header Pragma "public";
    add_header Cache-Control "public, no-transform";
    try_files $uri $uri/ /index.php?$args;
    include /etc/nginx/includes/http_headers.conf;
    access_log off;
}
EOF

log "  browser_caching.conf rewritten (4 location blocks + etag + http_headers include)."

# ── Step 3: Write nginx_security_directives.conf ─────────────────
# Static file — no site-specific values. Same ruleset applies to
# every WordPress site on the server.
log "Step 3/7 — Writing ${NGINX_INCLUDES}/nginx_security_directives.conf..."

cat > "${NGINX_INCLUDES}/nginx_security_directives.conf" << 'EOF'
##
# WORDPRESS-SAFE NGINX FIREWALL RULESET
# Managed by: serverforge/scripts/nginx_application_hardening.sh
#
# Apply to a site with:
#   include /etc/nginx/includes/nginx_security_directives.conf;
#
# This is a static file — no site-specific values. The same ruleset
# is applied to every WordPress site on the server.
##

# -------------------------------------------------------
# SUPPRESS COMMON BENIGN 404s FROM ERROR LOG
# -------------------------------------------------------
location = /favicon.ico {
    access_log off;
    log_not_found off;
}

location = /robots.txt {
    access_log off;
    log_not_found off;
}

# -------------------------------------------------------
# BLOCK ACCESS TO SENSITIVE WORDPRESS FILES
# -------------------------------------------------------

# xmlrpc.php — commented out by default: some plugins and mobile apps
# require XML-RPC. Uncomment to block if it is not needed.
# xmlrpc.php is also covered by rate limiting in the per-site include.
#location = /xmlrpc.php { deny all; }

location = /wp-config.php          { deny all; }
location = /wp-admin/install.php   { deny all; }

location ~* /readme\.html$         { deny all; }
location ~* /readme\.txt$          { deny all; }
location ~* /licence\.txt$         { deny all; }
location ~* /license\.txt$         { deny all; }

location ~ ^/wp-admin/includes/                       { deny all; }
location ~ ^/wp-includes/[^/]+\.php$                  { deny all; }
location ~ ^/wp-includes/js/tinymce/langs/.+\.php$    { deny all; }
location ~ ^/wp-includes/theme-compat/                { deny all; }

# -------------------------------------------------------
# BLOCK PHP EXECUTION IN UPLOADS, PLUGINS, AND THEMES
# -------------------------------------------------------
# Blocks all valid PHP file extensions (php, php1-7, pht, phtml, phps).
# ~* makes matching case-insensitive (.PHP, .Php, etc. are all caught).
location ~* ^/wp-content/uploads/.*\.(?:php[1-7]?|pht|phtml?|phps)$  { deny all; }
location ~* ^/wp-content/plugins/.*\.(?:php[1-7]?|pht|phtml?|phps)$  { deny all; }
location ~* ^/wp-content/themes/.*\.(?:php[1-7]?|pht|phtml?|phps)$   { deny all; }

# Block site-level PHP override file
location = /.user.ini { deny all; }

# -------------------------------------------------------
# FILTER REQUEST METHODS
# -------------------------------------------------------
if ( $request_method ~* ^(TRACE|DELETE|TRACK)$ ) { return 403; }

# -------------------------------------------------------
# FILTER SUSPICIOUS QUERY STRINGS
# Nginx if-blocks do not chain — the variable approach is the correct
# way to aggregate multiple conditions in Nginx configuration.
# Whitelist entries at the bottom reset $susquery for known-safe
# WordPress patterns (logged-in users, Google Maps, password resets).
# -------------------------------------------------------
set $susquery 0;
if ( $args ~* "\.\.\/"                                            ) { set $susquery 1; }
if ( $args ~* "\.(bash|git|hg|log|svn|swp|cvs)"                 ) { set $susquery 1; }
if ( $args ~* "etc/passwd"                                       ) { set $susquery 1; }
if ( $args ~* "boot\.ini"                                        ) { set $susquery 1; }
if ( $args ~* "ftp:"                                             ) { set $susquery 1; }
if ( $args ~* "(<|%3C)script(>|%3E)"                            ) { set $susquery 1; }
if ( $args ~* "mosConfig_[a-zA-Z_]{1,21}(=|%3D)"               ) { set $susquery 1; }
if ( $args ~* "base64_decode\("                                  ) { set $susquery 1; }
if ( $args ~* "%24&x"                                            ) { set $susquery 1; }
if ( $args ~* "127\.0"                                           ) { set $susquery 1; }
if ( $args ~* "(globals|encode|request|localhost|loopback|insert|concat|union|declare)" ) { set $susquery 1; }
if ( $args ~* "%[01][0-9A-F]"                                   ) { set $susquery 1; }
# Whitelist — reset for known-safe WordPress patterns
if ( $args ~ "^loggedout=true"                                   ) { set $susquery 0; }
if ( $args ~ "^action=jetpack-sso"                               ) { set $susquery 0; }
if ( $args ~ "^action=rp"                                        ) { set $susquery 0; }
if ( $http_cookie ~ "wordpress_logged_in_"                       ) { set $susquery 0; }
if ( $http_referer ~* "^https?://maps\.googleapis\.com/"         ) { set $susquery 0; }
if ( $susquery = 1 ) { return 403; }

# -------------------------------------------------------
# BLOCK COMMON SQL INJECTIONS
# -------------------------------------------------------
set $block_sql_injections 0;
if ($query_string ~ "union.*select.*\("      ) { set $block_sql_injections 1; }
if ($query_string ~ "union.*all.*select.*"   ) { set $block_sql_injections 1; }
if ($query_string ~ "concat.*\("             ) { set $block_sql_injections 1; }
if ($block_sql_injections = 1) { return 403; }

# -------------------------------------------------------
# BLOCK FILE INJECTIONS
# -------------------------------------------------------
set $block_file_injections 0;
if ($query_string ~ "[a-zA-Z0-9_]=http://"          ) { set $block_file_injections 1; }
if ($query_string ~ "[a-zA-Z0-9_]=(\.\.//?)+"       ) { set $block_file_injections 1; }
if ($query_string ~ "[a-zA-Z0-9_]=/([a-z0-9_.]//?)+") { set $block_file_injections 1; }
if ($block_file_injections = 1) { return 403; }

# -------------------------------------------------------
# BLOCK COMMON EXPLOITS
# -------------------------------------------------------
set $block_common_exploits 0;
if ($query_string ~ "(<|%3C).*script.*(>|%3E)"              ) { set $block_common_exploits 1; }
if ($query_string ~ "GLOBALS(=|\[|\%[0-9A-Z]{0,2})"        ) { set $block_common_exploits 1; }
if ($query_string ~ "_REQUEST(=|\[|\%[0-9A-Z]{0,2})"       ) { set $block_common_exploits 1; }
if ($query_string ~ "proc/self/environ"                     ) { set $block_common_exploits 1; }
if ($query_string ~ "mosConfig_[a-zA-Z_]{1,21}(=|\%3D)"    ) { set $block_common_exploits 1; }
if ($query_string ~ "base64_(en|de)code\(.*\)"              ) { set $block_common_exploits 1; }
if ($block_common_exploits = 1) { return 403; }

# -------------------------------------------------------
# BLOCK SPAM QUERY STRINGS
# -------------------------------------------------------
set $block_spam 0;
if ($query_string ~ "\b(ultram|unicauca|valium|viagra|vicodin|xanax|ypxaieo)\b"      ) { set $block_spam 1; }
if ($query_string ~ "\b(erections|hoodia|huronriveracres|impotence|levitra|libido)\b" ) { set $block_spam 1; }
if ($query_string ~ "\b(ambien|blue\spill|cialis|cocaine|ejaculation|erectile)\b"     ) { set $block_spam 1; }
if ($query_string ~ "\b(lipitor|phentermin|pro[sz]ac|sandyauer|tramadol|troyhamby)\b" ) { set $block_spam 1; }
if ($block_spam = 1) { return 403; }

# -------------------------------------------------------
# BLOCK KNOWN VULNERABILITY SCANNER USER AGENTS
# -------------------------------------------------------
set $block_user_agents 0;
if ($http_user_agent ~ "Indy Library"     ) { set $block_user_agents 1; }
if ($http_user_agent ~ "libwww-perl"      ) { set $block_user_agents 1; }
if ($http_user_agent ~ "GetRight"         ) { set $block_user_agents 1; }
if ($http_user_agent ~ "GetWeb!"          ) { set $block_user_agents 1; }
if ($http_user_agent ~ "Go!Zilla"         ) { set $block_user_agents 1; }
if ($http_user_agent ~ "Download Demon"   ) { set $block_user_agents 1; }
if ($http_user_agent ~ "Go-Ahead-Got-It"  ) { set $block_user_agents 1; }
if ($http_user_agent ~ "TurnitinBot"      ) { set $block_user_agents 1; }
if ($http_user_agent ~ "GrabNet"          ) { set $block_user_agents 1; }
if ($http_user_agent ~ "dirbuster"        ) { set $block_user_agents 1; }
if ($http_user_agent ~ "nikto"            ) { set $block_user_agents 1; }
if ($http_user_agent ~ "SF"               ) { set $block_user_agents 1; }
if ($http_user_agent ~ "sqlmap"           ) { set $block_user_agents 1; }
if ($http_user_agent ~ "fimap"            ) { set $block_user_agents 1; }
if ($http_user_agent ~ "nessus"           ) { set $block_user_agents 1; }
if ($http_user_agent ~ "whatweb"          ) { set $block_user_agents 1; }
if ($http_user_agent ~ "Openvas"          ) { set $block_user_agents 1; }
if ($http_user_agent ~ "jbrofuzz"         ) { set $block_user_agents 1; }
if ($http_user_agent ~ "libwhisker"       ) { set $block_user_agents 1; }
if ($http_user_agent ~ "webshag"          ) { set $block_user_agents 1; }
if ($http_user_agent ~ "Acunetix-Product" ) { set $block_user_agents 1; }
if ($http_user_agent ~ "Acunetix"         ) { set $block_user_agents 1; }
if ($block_user_agents = 1) { return 403; }
EOF

log "  nginx_security_directives.conf written (WAF ruleset, ~120 lines)."

# ── Step 4: Add limit_req_zone to nginx.conf ──────────────────────
log "Step 4/7 — Adding rate limiting zone to $NGINX_CONF..."

if grep -q "limit_req_zone" "$NGINX_CONF"; then
    log "  limit_req_zone already present in nginx.conf — skipping."
else
    cp "$NGINX_CONF" "${NGINX_CONF}.pre-ratelimit.bak"

    # Insert the rate limiting zone into the http block.
    # The zone is placed before the Virtual Host Configs section.
    python3 << 'PYEOF'
import sys

nginx_conf = '/etc/nginx/nginx.conf'
with open(nginx_conf, 'r') as f:
    content = f.read()

zone_block = (
    '        ##\n'
    '        # Rate Limiting\n'
    '        # limit_req_zone: tracks per-IP request rates for WordPress\n'
    '        # endpoints. Zone "wp" = 10MB shared memory, 30 req/min per IP.\n'
    '        ##\n'
    '        limit_req_zone $binary_remote_addr zone=wp:10m rate=30r/m;\n'
    '\n'
)

# Try to insert before the Virtual Host Configs section
target = '        ##\n        # Virtual Host Configs\n'
if target in content:
    content = content.replace(target, zone_block + target, 1)
elif 'sites-enabled' in content:
    # Fallback: insert before sites-enabled include
    content = content.replace(
        '        include /etc/nginx/sites-enabled/*;',
        zone_block + '        include /etc/nginx/sites-enabled/*;',
        1
    )
else:
    print('ERROR: Could not find insertion point in nginx.conf', file=sys.stderr)
    sys.exit(1)

with open(nginx_conf, 'w') as f:
    f.write(content)

print('limit_req_zone added.')
PYEOF

    if [ $? -ne 0 ]; then
        log "ERROR: Failed to add limit_req_zone to nginx.conf"
        cp "${NGINX_CONF}.pre-ratelimit.bak" "$NGINX_CONF"
        exit 1
    fi
    log "  limit_req_zone \$binary_remote_addr zone=wp:10m rate=30r/m; added."
fi

# ── Step 5: Write per-site rate limiting include file ─────────────
log "Step 5/7 — Writing rate limiting include: $RATE_LIMIT_CONF..."

cat > "$RATE_LIMIT_CONF" << EOF
##
# RATE LIMITING — wp-login.php and xmlrpc.php
# Managed by: serverforge/scripts/nginx_application_hardening.sh
#
# Uses the 'wp' zone defined in nginx.conf: 30 requests/minute per IP.
# burst=20: allows brief bursts without immediate rejection (e.g. multiple
# tabs opened simultaneously). nodelay: burst requests are served immediately
# rather than queued. limit_req_status 444: close connection with no response.
#
# The fastcgi_pass must point to the site's dedicated PHP-FPM pool socket.
##

location = /wp-login.php {
    limit_req zone=wp burst=20 nodelay;
    limit_req_status 444;
    include snippets/fastcgi-php.conf;
    fastcgi_param HTTP_HOST \$host;
    fastcgi_pass unix:${POOL_SOCKET};
    include /etc/nginx/includes/fastcgi_optimize.conf;
}

location = /xmlrpc.php {
    limit_req zone=wp burst=20 nodelay;
    limit_req_status 444;
    include snippets/fastcgi-php.conf;
    fastcgi_param HTTP_HOST \$host;
    fastcgi_pass unix:${POOL_SOCKET};
    include /etc/nginx/includes/fastcgi_optimize.conf;
}
EOF

log "  rate_limiting_${SITE_DOMAIN}.conf written."
log "  Endpoints protected: /wp-login.php, /xmlrpc.php"
log "  Rate: 30r/m per IP, burst=20, status=444 on excess"

# ── Step 6: Rewrite Nginx server block — complete final state ─────
log "Step 6/7 — Rewriting Nginx server block: $NGINX_SITE_CONF"
log "  Includes: http_headers, nginx_security_directives, rate_limiting, browser_caching"

# Back up before replacing
cp "$NGINX_SITE_CONF" "${NGINX_SITE_CONF}.pre-appharden.bak"

# Build the optional hotlinking block
if [ "$HOTLINK_PROTECTION" = "nginx" ]; then
    DOMAIN_ESCAPED=$(echo "$SITE_DOMAIN" | sed 's/\./\\./g')
    HOTLINK_BLOCK="
    # Hotlinking protection (nginx mode)
    # WARNING: This does not work correctly when Cloudflare proxy is active.
    # Images embedded on external sites will return 403. Direct visits,
    # Google, Bing, Facebook, Twitter, and Pinterest are whitelisted.
    location ~* \\.(gif|ico|jpg|jpeg|png|webp|svg)\$ {
        valid_referers none blocked server_names
                       ~\\.${DOMAIN_ESCAPED}
                       ~\\.google\\.
                       ~\\.bing\\.
                       ~\\.facebook\\.
                       ~\\.twitter\\.
                       ~\\.pinterest\\.;
        if (\$invalid_referer) {
            return 403;
        }
        expires 30d;
        add_header Cache-Control \"public, no-transform\";
        access_log off;
    }
"
    log "  Hotlinking: nginx mode (valid_referers location block added)"
elif [ "$HOTLINK_PROTECTION" = "cloudflare" ]; then
    HOTLINK_BLOCK=""
    log "  Hotlinking: cloudflare mode — enable in Cloudflare Dashboard:"
    log "    Domain → Scrape Shield → Hotlink Protection → ON"
else
    HOTLINK_BLOCK=""
    log "  Hotlinking: disabled"
fi

cat > "$NGINX_SITE_CONF" << EOF
# ServerForge — Final Nginx server block for ${SITE_DOMAIN}
# Last updated by: serverforge/scripts/nginx_application_hardening.sh

# HTTP → HTTPS permanent redirect
server {
    listen 80;
    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};
    return 301 https://${SITE_DOMAIN}\$request_uri;
}

# HTTPS server block — complete hardened configuration
server {

    # SSL + HTTP/2
    listen 443 ssl;
    http2  on;

    # HTTP/3 via QUIC — reuseport is for the FIRST site only.
    # Additional sites: listen 443 quic;  (no reuseport)
    listen 443 quic reuseport;
    http3  on;

    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};

    root  /var/www/${SITE_DOMAIN}/public_html;
    index index.php;

    # Site-specific TLS certificate paths
    include /etc/nginx/ssl/ssl_${SITE_DOMAIN}.conf;

    # Shared TLS protocols, ciphers, HSTS, HTTP/3 settings
    include /etc/nginx/ssl/ssl_all_sites.conf;

    # Security response headers (Referrer-Policy, X-Frame-Options, etc.)
    include /etc/nginx/includes/http_headers.conf;

    # WordPress firewall ruleset (sensitive file blocks, PHP exec, bad agents)
    include /etc/nginx/includes/nginx_security_directives.conf;

    # Rate limiting for wp-login.php and xmlrpc.php
    include /etc/nginx/includes/rate_limiting_${SITE_DOMAIN}.conf;

    # WordPress permalink handling
    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    # PHP requests → PHP-FPM pool socket
    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_param HTTP_HOST \$host;
        fastcgi_pass unix:${POOL_SOCKET};
        include /etc/nginx/includes/fastcgi_optimize.conf;
    }

    # Static asset browser caching + security headers
    include /etc/nginx/includes/browser_caching.conf;
${HOTLINK_BLOCK}
    # Per-site logs (buffered access, separate error)
    access_log /var/log/nginx/${SITE_DOMAIN}.access.log combined buffer=256k flush=60m;
    error_log  /var/log/nginx/${SITE_DOMAIN}.error.log;

}
EOF

log "  Server block rewritten with all hardening includes."

# ── Step 7: Test and reload Nginx ─────────────────────────────────
log "Step 7/7 — Testing and reloading Nginx..."

nginx -t >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "ERROR: Nginx config test failed."
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    log "  Restoring backups..."
    cp "${NGINX_SITE_CONF}.pre-appharden.bak" "$NGINX_SITE_CONF"
    [ -f "${NGINX_CONF}.pre-ratelimit.bak" ] && \
        cp "${NGINX_CONF}.pre-ratelimit.bak" "$NGINX_CONF"
    exit 1
fi

systemctl reload nginx >> "$LOG_FILE" 2>&1
log "  Nginx reloaded."

# ── DDoS note ─────────────────────────────────────────────────────
log ""
log "  NOTE — DDoS protection (section 44):"
log "    Handle at the CDN/host layer, NOT at Nginx level. For a"
log "    WordPress site, broad Nginx rate limiting risks blocking"
log "    legitimate plugin traffic, WP-Cron, and REST API calls."
log "    Recommended: enable Cloudflare proxy + DDoS protection rules."

# ── Summary ───────────────────────────────────────────────────────
separator
log "Nginx application hardening complete."
log "  ✔ http_headers.conf              → 5 security response headers"
log "  ✔ browser_caching.conf           → rewritten with etag + http_headers include"
log "  ✔ nginx_security_directives.conf → WordPress WAF ruleset"
log "  ✔ nginx.conf                     → limit_req_zone wp:10m rate=30r/m"
log "  ✔ rate_limiting_${SITE_DOMAIN}.conf → wp-login.php + xmlrpc.php protected"
log "  ✔ ${SITE_DOMAIN}.conf            → complete hardened server block"
log "  ✔ Hotlink protection             → $HOTLINK_PROTECTION"
