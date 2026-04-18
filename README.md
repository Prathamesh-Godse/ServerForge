# ServerForge

Automated, reboot-persistent server hardening for Ubuntu/Debian.
Runs a ten-stage sequence — surviving reboots between each stage —
via a systemd one-shot service that installs itself on first launch
and self-disables when the final stage completes.

---

## Stage Map

| Stage | Concept                  | Script                              | Reboots? |
|-------|--------------------------|-------------------------------------|----------|
| 1     | User Management          | `scripts/user_management.sh`        | No (→ 2) |
| 2     | SSH Hardening            | `scripts/ssh_hardening.sh`          | Yes      |
| 3     | System Updates           | `scripts/system_updates.sh`         | Yes      |
| 4     | Timezone                 | `scripts/timezone.sh`               | Yes      |
| 5     | Firewall                 | `scripts/firewall.sh`               | Yes      |
| 6     | Fail2ban                 | `scripts/fail2ban.sh`               | Yes      |
| 7     | Swap                     | `scripts/swap.sh`                   | Yes      |
| 8     | Kernel Hardening         | `scripts/kernel_hardening.sh`       | Yes      |
| 9     | fstab Hardening          | `scripts/fstab_hardening.sh`        | Yes      |
| 10    | Open File Limits         | `scripts/open_file_limits.sh`       | Yes      |
| 11    | LEMP Stack Installation  | `scripts/install_lemp.sh`           | No (→ 12)|
| 12    | Mail (msmtp)             | `scripts/configure_mail.sh`         | No (→ 13)|
| 13    | Nginx Hardening          | `scripts/configure_nginx.sh`        | No (→ 14)|
| 14    | MariaDB Hardening        | `scripts/harden_mariadb.sh`         | No (→ 15)|
| 15    | MariaDB Optimization     | `scripts/optimize_mariadb.sh`       | No (→ 16)|
| 16    | PHP Hardening            | `scripts/harden_optimize_php.sh`    | No (→ 17)|
| 17    | Site Infrastructure      | `scripts/setup_site_infrastructure.sh` | No (→ 18)|
| 18    | WordPress Installation   | `scripts/install_wordpress.sh`         | No (→ 19)|
| 19    | PHP-FPM Pool Isolation   | `scripts/configure_php_pool.sh`        | No (→ 20)|
| 20    | WordPress Hardening      | `scripts/harden_wordpress.sh`          | No (→ 21)|
| 21    | SSL / HTTPS              | `scripts/configure_ssl.sh`             | No (→ 22)|
| 22    | Nginx App Hardening      | `scripts/nginx_application_hardening.sh` | No (→ 23)|
| 23    | WordPress App Hardening  | `scripts/wordpress_application_hardening.sh` | No ★ |

★ After Stage 23, install the "Disable REST API" plugin manually in WordPress Admin
and enable Cloudflare Hotlink Protection if applicable.

Stages 1→2 and 11→23 chain without reboots. Stages 2–10 each reboot.
After Stage 23 the service disables itself permanently.

---

## Project Structure

```
serverforge/
├── main.sh                           # Orchestrator — run this to start
├── serverforge.service               # Systemd service template
├── serverforge.log                   # All stage output, timestamped
├── configs/
│   ├── server.conf                   # Identity, timezone, fail2ban
│   ├── users.conf                    # User creation and SSH key
│   ├── ssh.conf                      # SSH daemon hardening
│   ├── firewall.conf                 # UFW port rules
│   ├── swap.conf                     # Swap file size and path
│   ├── kernel.conf                   # Kernel tuning: swappiness, IPv6, BBR
│   ├── limits.conf                   # OS open file descriptor limit
│   ├── lemp.conf                     # LEMP stack: PPAs, PHP version, modules
│   ├── mail.conf                     # SMTP credentials for msmtp
│   ├── nginx_settings.conf           # Nginx: worker limits, body size
│   ├── mariadb.conf                  # MariaDB: InnoDB, binary logs, file limit
│   ├── php.conf                      # PHP: upload limits, memory, rlimit
│   └── site.conf                     # Site: domain, PHP, permissions, Certbot email
└── scripts/
    ├── user_management.sh            # Stage 1
    ├── ssh_hardening.sh              # Stage 2
    ├── system_updates.sh             # Stage 3
    ├── timezone.sh                   # Stage 4
    ├── firewall.sh                   # Stage 5
    ├── fail2ban.sh                   # Stage 6
    ├── swap.sh                       # Stage 7
    ├── kernel_hardening.sh           # Stage 8
    ├── fstab_hardening.sh            # Stage 9
    ├── open_file_limits.sh           # Stage 10
    ├── install_lemp.sh               # Stage 11
    ├── configure_mail.sh             # Stage 12
    ├── configure_nginx.sh            # Stage 13
    ├── harden_mariadb.sh             # Stage 14
    ├── optimize_mariadb.sh           # Stage 15
    ├── harden_optimize_php.sh        # Stage 16
    ├── setup_site_infrastructure.sh  # Stage 17
    ├── install_wordpress.sh          # Stage 18
    ├── configure_php_pool.sh         # Stage 19
    ├── harden_wordpress.sh           # Stage 20
    ├── configure_ssl.sh              # Stage 21
    ├── nginx_application_hardening.sh    # Stage 22
    └── wordpress_application_hardening.sh # Stage 23
```

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/Prathamesh-Godse/serverforge.git
cd serverforge

# 2. Configure — edit all config files before starting
nano configs/server.conf         # SERVER_USER, TIMEZONE, fail2ban settings
nano configs/users.conf          # SERVER_USER, USER_PASSWORD, SSH_PUBLIC_KEY
nano configs/ssh.conf            # root login and password auth policy
nano configs/firewall.conf       # allowed/denied ports
nano configs/swap.conf           # swap file size (default: 2 GB)
nano configs/kernel.conf         # swappiness, IPv6, BBR, apport
nano configs/limits.conf         # open file descriptor limit
nano configs/lemp.conf           # PHP version, PPAs, extensions (defaults usually fine)
nano configs/mail.conf           # SMTP host, user, App Password, from address
nano configs/nginx_settings.conf # worker limits, body size (defaults usually fine)
nano configs/site.conf           # SITE_DOMAIN — your domain name (required)

# 3. Make all scripts executable
chmod +x main.sh scripts/*.sh

# 4. Run as root — service installs itself for reboot persistence
sudo ./main.sh
```

The server reboots **nine times** (after Stages 2–10). Each time it comes
back up the service resumes at the next stage automatically. Stages 11–13
run back-to-back without reboots. After Stage 13 completes the service
disables and removes itself.

---

## Configuration Reference

### `configs/server.conf`

| Variable            | Description                                        |
|---------------------|----------------------------------------------------|
| `SERVER_USER`       | Non-root username (must match `users.conf`)        |
| `TIMEZONE`          | System timezone (e.g. `Asia/Kolkata`)              |
| `FAIL2BAN_BANTIME`  | Ban duration (e.g. `7d`, `1h`, `-1` for permanent)|
| `FAIL2BAN_FINDTIME` | Window for counting failures (e.g. `3h`)           |
| `FAIL2BAN_MAXRETRY` | Failures before a ban is issued                    |

### `configs/users.conf`

| Variable         | Description                                           |
|------------------|-------------------------------------------------------|
| `SERVER_USER`    | Username to create (must match `server.conf`)         |
| `USER_PASSWORD`  | Password for the new user                             |
| `REMOVE_USERS`   | Space-separated list of cloud default users to delete |
| `SSH_PUBLIC_KEY` | Public key string to inject into `authorized_keys`    |

### `configs/ssh.conf`

| Variable            | Description                                        |
|---------------------|----------------------------------------------------|
| `PERMIT_ROOT_LOGIN` | `yes` or `no` — whether root can log in via SSH   |
| `PASSWORD_AUTH`     | `yes` or `no` — whether password login is allowed |
| `SSH_DROPIN_FILE`   | Path to the cloud-init SSH drop-in config file    |

### `configs/firewall.conf`

| Variable           | Description                                         |
|--------------------|-----------------------------------------------------|
| `ALLOW`            | Comma-separated ports/services to allow             |
| `DENY`             | Comma-separated ports to deny                       |
| `DEFAULT_INCOMING` | `deny` or `allow`                                   |
| `DEFAULT_OUTGOING` | `deny` or `allow`                                   |
| `ALLOW_PING`       | `yes` or `no`                                       |

### `configs/swap.conf`

| Variable       | Description                                              |
|----------------|----------------------------------------------------------|
| `SWAP_PATH`    | Path for the swap file (default: `/swapfile`)            |
| `SWAP_SIZE_MB` | Size in MB — formula: `desired_GB × 1024` (default: 2048)|

### `configs/kernel.conf`

| Variable          | Description                                              |
|-------------------|----------------------------------------------------------|
| `SWAPPINESS`      | Kernel swap eagerness: `1` = last resort (default: `1`)  |
| `VFS_CACHE_PRESSURE` | Filesystem cache retention: lower = hold longer (default: `50`) |
| `DISABLE_IPV6`    | `yes` or `no` — disables IPv6 via GRUB kernel parameter  |
| `DISABLE_APPORT`  | `yes` or `no` — disables Ubuntu crash reporter           |

### `configs/limits.conf`

| Variable       | Description                                               |
|----------------|-----------------------------------------------------------|
| `NOFILE_LIMIT` | Max open file descriptors for all users (default: 120000) |

### `configs/lemp.conf`

| Variable          | Description                                                     |
|-------------------|-----------------------------------------------------------------|
| `NGINX_PPA`       | Ondrej Nginx PPA (default: `ppa:ondrej/nginx`)                  |
| `PHP_VERSION`     | PHP version to install (default: `8.3`)                         |
| `PHP_PPA`         | Ondrej PHP PPA (default: `ppa:ondrej/php`)                      |
| `PHP_EXTENSIONS`  | Space-separated list of PHP extension names (no `php8.3-` prefix)|
| `NGINX_MODULES`   | Space-separated Nginx module package names                       |

### `configs/mail.conf`

| Variable        | Description                                                         |
|-----------------|---------------------------------------------------------------------|
| `SMTP_HOST`     | SMTP relay hostname (default: `smtp.gmail.com`)                     |
| `SMTP_PORT`     | SMTP port (default: `587`)                                          |
| `SMTP_USER`     | Gmail address used for SMTP authentication                          |
| `SMTP_PASSWORD` | 16-character Gmail App Password (not your account password)         |
| `SMTP_FROM`     | From address on outbound email (must match `SMTP_USER` for Gmail)   |

### `configs/nginx_settings.conf`

| Variable                      | Description                                               |
|-------------------------------|-----------------------------------------------------------|
| `NGINX_WORKER_RLIMIT_NOFILE`  | Open file descriptor limit per worker (default: `45000`)  |
| `NGINX_WORKER_CONNECTIONS`    | Max simultaneous connections per worker (default: `4096`) |
| `NGINX_CLIENT_MAX_BODY_SIZE`  | Max request body (default: `100m` — reduce to `8m` later)|

### `configs/mariadb.conf`

| Variable                          | Description                                              |
|-----------------------------------|----------------------------------------------------------|
| `MARIADB_INNODB_BUFFER_POOL_SIZE` | InnoDB RAM cache — ~80% of server RAM (default: `800M`) |
| `MARIADB_INNODB_LOG_FILE_SIZE`    | InnoDB redo log — ~25% of buffer pool (default: `200M`) |
| `MARIADB_EXPIRE_LOGS_DAYS`        | Binary log retention in days (default: `3`)              |
| `MARIADB_OPEN_FILE_LIMIT`         | systemd `LimitNOFILE` for MariaDB (default: `40000`)    |

### `configs/php.conf`

| Variable                  | Description                                                  |
|---------------------------|--------------------------------------------------------------|
| `PHP_VERSION`             | PHP version matching `lemp.conf` (default: `8.3`)            |
| `PHP_UPLOAD_MAX_FILESIZE` | Max single file upload size (default: `100M`)                |
| `PHP_POST_MAX_SIZE`       | Max POST body — must exceed upload max (default: `125M`)     |
| `PHP_MAX_INPUT_VARS`      | Max input variables per request (default: `3000`)            |
| `PHP_MEMORY_LIMIT`        | Max memory per PHP process (default: `256M`)                 |
| `PHP_RLIMIT_FILES`        | Max open file descriptors for PHP-FPM (default: `32768`)     |

### `configs/site.conf`

| Variable          | Description                                                    |
|-------------------|----------------------------------------------------------------|
| `SITE_DOMAIN`     | Bare domain name for the site (e.g. `example.com`) — required |
| `SITE_PHP_VERSION`| PHP version for FastCGI socket (default: `8.3`)                |
| `PERMISSION_MODE` | `hardened` (production) or `standard` (update phase)          |
| `CERTBOT_EMAIL`   | Email for Let's Encrypt renewal notices — required for Stage 21|
| `HOTLINK_PROTECTION` | `cloudflare` (default), `nginx`, or `disabled` (Stage 22) |
| `DB_PRIVILEGE_HARDEN` | `yes` or `no` — restrict DB user to SELECT/INSERT/UPDATE/DELETE (Stage 23) |

---

## Log Format

Every line of output from every script is appended to `serverforge.log`
in the project root. Each entry is timestamped and tagged with its source:

```
2024-07-03 17:02:11 [MAIN]       Stage 1/13 — User Management
2024-07-03 17:02:11 [USER_MGMT]  Starting user management...
2024-07-03 17:05:33 [SSH_HARDEN] SSH hardening complete.
2024-07-03 17:05:33 [MAIN]       Rebooting to apply changes (will resume at Stage 3)...
2024-07-03 17:08:01 [MAIN]       ServerForge — Resuming at Stage 3 of 13
...
2024-07-03 18:14:55 [LIMITS]     Open file limits configuration complete.
2024-07-03 18:15:01 [MAIN]       Stage 11/13 — LEMP Stack Installation
2024-07-03 18:15:01 [LEMP]       Starting LEMP stack installation...
2024-07-03 18:22:44 [LEMP]       LEMP stack installation complete.
2024-07-03 18:22:44 [MAIN]       Stage 12/13 — Mail (msmtp)
2024-07-03 18:22:44 [MAIL]       Starting mail (msmtp) configuration...
2024-07-03 18:22:46 [MAIL]       Mail configuration complete.
2024-07-03 18:22:46 [MAIN]       Stage 13/13 — Nginx Hardening & Optimization
2024-07-03 18:22:46 [NGINX_CFG]  Starting Nginx hardening and optimization...
2024-07-03 18:22:49 [NGINX_CFG]  Nginx hardening and optimization complete.
2024-07-03 18:22:49 [MAIN]       ServerForge setup complete!
```

| Tag               | Source script              |
|-------------------|----------------------------|
| `[MAIN]`          | `main.sh`                  |
| `[USER_MGMT]`     | `user_management.sh`       |
| `[SSH_HARDEN]`    | `ssh_hardening.sh`         |
| `[SYS_UPDATE]`    | `system_updates.sh`        |
| `[TIMEZONE]`      | `timezone.sh`              |
| `[FIREWALL]`      | `firewall.sh`              |
| `[FAIL2BAN]`      | `fail2ban.sh`              |
| `[SWAP]`          | `swap.sh`                  |
| `[KERNEL]`        | `kernel_hardening.sh`      |
| `[FSTAB]`         | `fstab_hardening.sh`       |
| `[LIMITS]`        | `open_file_limits.sh`      |
| `[LEMP]`          | `install_lemp.sh`          |
| `[MAIL]`          | `configure_mail.sh`        |
| `[NGINX_CFG]`     | `configure_nginx.sh`       |
| `[MARIADB_HARDEN]`| `harden_mariadb.sh`        |
| `[MARIADB_OPT]`   | `optimize_mariadb.sh`      |
| `[PHP_HARDEN]`    | `harden_optimize_php.sh`   |
| `[SITE_INFRA]`    | `setup_site_infrastructure.sh` |
| `[WP_INSTALL]`    | `install_wordpress.sh`         |
| `[PHP_POOL]`      | `configure_php_pool.sh`        |
| `[WP_HARDEN]`     | `harden_wordpress.sh`          |
| `[SSL]`           | `configure_ssl.sh`             |
| `[NGINX_APP]`     | `nginx_application_hardening.sh` |
| `[WP_APP_HARDEN]` | `wordpress_application_hardening.sh` |

---

## CLI Options

```bash
sudo ./main.sh             # start or resume the sequence
sudo ./main.sh --status    # show current stage without running
sudo ./main.sh --reset     # delete stage file and restart from Stage 1
```

---

## Retrying a Failed Stage

If a stage fails, check `serverforge.log` for the error, fix the issue,
then re-run:

```bash
sudo ./main.sh
```

The `current_stage.txt` file tracks which stage to resume from. The
failed stage retries on the next run. To start over completely:

```bash
sudo ./main.sh --reset
```

---

## Important Notes

- **SSH keys before disabling passwords** — If `PASSWORD_AUTH=no` in
  `ssh.conf`, ensure `SSH_PUBLIC_KEY` is set in `users.conf` first.
  Otherwise you will be locked out of the server after Stage 2.

- **REMOVE_USERS safety guard** — The script will never remove the user
  defined as `SERVER_USER`, even if it appears in the `REMOVE_USERS` list.

- **SSH config backups** — `ssh_hardening.sh` backs up both `sshd_config`
  and `50-cloud-init.conf` before modifying them (`.bak` extension).
  If the `sshd -t` validation fails, the originals are restored automatically.

- **fstab backups** — Both `swap.sh` and `fstab_hardening.sh` back up
  `/etc/fstab` to `/etc/fstab.bak` before making any changes.

- **GRUB backup** — `kernel_hardening.sh` backs up `/etc/default/grub`
  to `/etc/default/grub.bak` before appending the `ipv6.disable=1`
  parameter. If `update-grub` fails, the original is restored.

- **Swap idempotency** — If a swap file already exists at `SWAP_PATH`
  and is already in `/etc/fstab`, Stage 7 skips creation and logs the
  current state without making any changes.

- **fstab noatime** — `fstab_hardening.sh` detects the root filesystem
  line automatically. If detection fails (unusual fstab layout), it logs
  a warning and skips that step rather than corrupting fstab.

- **suid_dumpable and apport** — If `fs.suid_dumpable` reads back as `2`
  after Stage 8, it means Ubuntu's `apport` crash reporter is overriding
  it. Set `DISABLE_APPORT=yes` in `kernel.conf` (the default) to prevent
  this — the script stops and masks the apport service automatically.

- **LEMP: IPv6 vhost fix** — If IPv6 was disabled in Stage 8, Nginx will
  fail to start after install because the default vhost includes a
  `listen [::]:80` directive. `install_lemp.sh` automatically comments
  this out and backs up the original file before doing so.

- **LEMP: Nginx PPA name** — The PPA changed from `ppa:ondrej/nginx-mainline`
  to `ppa:ondrej/nginx` in April 2025. The default in `lemp.conf` is
  the current name. Update it if you add the PPA manually beforehand.

- **Mail: Gmail App Password required** — Gmail rejects plain account
  passwords for SMTP. An App Password must be created under Google
  Account → Security → 2-Step Verification → App passwords. Set it as
  `SMTP_PASSWORD` in `configs/mail.conf` before running Stage 12.

- **Mail: PHP mail test is manual** — Testing `mail()` as `www-data`
  requires temporarily setting the home directory to `755` to allow
  `sudo -u www-data php` to read the test script. This is interactive
  and intentionally not automated. See the procedure below.

- **Nginx: nginx.conf is fully replaced** — `configure_nginx.sh` writes
  the entire `nginx.conf` from scratch rather than using `sed`. The
  original is backed up to `nginx.conf.bak` before any changes. If
  `nginx -t` fails after writing, the backup is restored automatically.

- **Nginx: client_max_body_size** — Set to `100m` by default to allow
  WordPress theme and plugin uploads during site setup. Change
  `NGINX_CLIENT_MAX_BODY_SIZE` to `8m` in `nginx_settings.conf` and
  re-run Stage 13 once the site is fully configured.

- **Nginx: bash aliases** — Stage 13 appends aliases (`ngt`, `ngr`,
  `fpmr`, `ngin`, `ngsa`, `server_update`) to `~/.bash_aliases` for
  `SERVER_USER`. They become active on the next SSH login or after
  running `source ~/.bash_aliases`.

- **MariaDB hardening is non-interactive** — Stage 14 runs the
  equivalent SQL of `mysql_secure_installation` directly via
  `mysql -e` — no interactive prompts are needed. On Ubuntu, MariaDB
  root uses unix socket auth (no password), so `sudo mysql` is used
  throughout. The script is idempotent — safe to re-run.

- **MariaDB InnoDB log file size requires a stop** — Stage 15 stops
  MariaDB before editing `50-server.cnf`, then starts it again. This
  is mandatory — changing `innodb_log_file_size` while MariaDB is
  running and then restarting can corrupt InnoDB tables. The script
  checks that MariaDB stopped cleanly before proceeding.

- **InnoDB buffer pool sizing** — The default `MARIADB_INNODB_BUFFER_POOL_SIZE`
  of `800M` assumes a 1 GB RAM server. Scale it to ~80% of your actual
  RAM: `2 GB → 1600M`, `4 GB → 3200M`. Update `configs/mariadb.conf`
  before Stage 15 runs.

- **MySQLTuner** — Stage 15 downloads `mysqltuner.pl` to
  `~/MySQLTuner/`. Do **not** run it immediately — MySQLTuner needs
  the server to have been under real load for 60–90 days before its
  recommendations are meaningful. Run it periodically as a health check:
  `sudo ~/MySQLTuner/mysqltuner.pl`

- **OPcache is intentionally deferred** — Stage 16 does not configure
  OPcache. Each WordPress site will get its own PHP-FPM pool with a
  dedicated OPcache instance. Configuring OPcache in the shared
  `server_override.ini` here would apply a single global cache to all
  pools, removing per-site isolation. OPcache is configured per pool.

- **PHP error logging is intentionally deferred** — Per-site PHP error
  log paths are set inside each site's PHP-FPM pool config. The global
  `display_errors = Off` (via `expose_php = Off`) ensures errors are
  suppressed from browser output even before per-site logging is set up.

- **allow_url_fopen per site** — Stage 16 sets `allow_url_fopen = Off`
  globally. WordPress requires it to be `On` for plugin/theme updates
  and the HTTP API. Enable it per-site in each pool config:
  `php_admin_flag[allow_url_fopen] = on`

- **PHP-FPM restart vs reload** — Stage 16 uses `systemctl restart`
  (not `reload`) for PHP-FPM. `rlimit_files` and `rlimit_core` changes
  in `php-fpm.conf` require re-launching the master process — a reload
  applies ini changes but does not change the process-level resource limits.

- **DNS must be live before Stage 17** — `setup_site_infrastructure.sh`
  creates the Nginx server block and reloads Nginx. Nginx will start
  accepting traffic for `SITE_DOMAIN` after reload. If DNS is not yet
  pointing to the server, the server block will exist but no real traffic
  will hit it — this is fine. The browser wizard (Stage 18's manual step)
  requires DNS to be live and resolving correctly.

- **Site domain is required** — `SITE_DOMAIN` in `configs/site.conf` must
  be set before Stage 17 runs. The script will exit with an error if it is
  still the placeholder value `<your-domain.com>`.

- **DB credentials are auto-generated** — Stage 18 generates random values
  for the database name, username, password, and table prefix using
  `/dev/urandom`. These are written to `~/serverforge-${SITE_DOMAIN}-credentials.txt`
  (chmod 600). The file also has placeholder fields for the WordPress admin
  credentials you create during the browser wizard — fill them in and store
  the file in a password manager.

- **WordPress browser wizard is manual** — Stage 18 deploys the WordPress
  files and configures `wp-config.php`, but the final database table
  creation and admin account setup require navigating to
  `http://${SITE_DOMAIN}/` in a browser to complete the wizard.

- **WordPress first-login housekeeping (manual after wizard):**
  - Settings → Permalinks → Post name structure → Save
  - Plugins → delete Akismet and Hello Dolly (unused defaults)
  - Appearance → delete unused default themes (TT3, TT4, etc.)
  - Users → Profile → update Nickname and "Display name publicly as"
  - Install a maintenance mode plugin while configuring the site

- **FastCGI socket will change** — Stage 17 creates the server block
  pointing to the default PHP-FPM socket (`php8.3-fpm.sock`). When
  PHP-FPM pool isolation is configured in a later stage, the socket path
  in the server block will be updated to the site-specific pool socket.

- **Browser caching and FastCGI include files** — `browser_caching.conf`
  and `fastcgi_optimize.conf` are written to `/etc/nginx/includes/` in
  Stage 17. They are referenced from the server block and any future
  server blocks via a single `include` directive each.

---

## PHP Mail Test (Manual — Post Stage 12)

Testing PHP's `mail()` function running as `www-data` requires a brief
home directory permission change. Run these commands manually after
Stage 12 completes:

```bash
# 1. Temporarily allow www-data to read from the home directory
sudo chmod 755 /home/$USER/

# 2. Create a test script
cat > ~/php_mail_test.php << 'EOF'
<?php
    ini_set('display_errors', 1);
    error_reporting(E_ALL);
    $from    = "your.address@gmail.com";  // must match SMTP_FROM in mail.conf
    $to      = "recipient@example.com";
    $subject = "PHP Mail Test";
    $message = "Testing PHP mail() via msmtp";
    $headers = "From:" . $from;
    mail($to, $subject, $message, $headers);
    echo "Test email sent\n";
?>
EOF

# 3. Run as www-data
sudo -u www-data php ~/php_mail_test.php

# 4. Check the PHP mail log
sudo cat /var/log/msmtp.log

# 5. Restore home directory permissions
sudo chmod 750 /home/$USER/

# 6. Remove the test script
rm ~/php_mail_test.php
```

---

## Pool User, Hardened Permissions & SSL — Key Notes

**Pool username derivation (Stage 19)** — The PHP-FPM pool user is
auto-derived from the first DNS label of `SITE_DOMAIN`: `example.com → example`,
`mysite.co.uk → mysite`. This system user has no login shell and no home
directory. It owns the site files and is the identity under which PHP runs.
Group changes (cross-membership of www-data ↔ pool user) require the admin
to reconnect via SSH before they take effect in an interactive session.

**PERMISSION_MODE toggle (Stage 20)** — `hardened` locks WordPress core to
read-only (`550`/`440`) while keeping `wp-content/` writable. To run WordPress
core or plugin updates:
1. Set `PERMISSION_MODE=standard` in `configs/site.conf`
2. Re-run Stage 20: `sudo ./main.sh --reset` then advance to Stage 20
3. Perform updates in WordPress admin
4. Set `PERMISSION_MODE=hardened` and re-run Stage 20

`wp-config.php` is always locked to `440` regardless of mode.

**open_basedir and plugin compatibility (Stage 20)** — PHP is sandboxed to
`public_html/` and the site-local `tmp/`. If a plugin fails with a file
access error, check `/var/log/fpm-php.POOL_USER.log`. Add the required path
to `open_basedir` in the pool config (`/etc/php/8.3/fpm/pool.d/DOMAIN.conf`)
and reload PHP-FPM.

**disable_functions and plugin compatibility (Stage 20)** — Shell/process/
POSIX functions are disabled globally per pool. If a plugin requires one
(e.g. backup plugins that call `exec()`), remove it from `disable_functions`
in the pool config after verifying it is needed by a trusted plugin.

**DH parameter generation (Stage 21)** — `openssl dhparam -out dhparam.pem 2048`
takes several minutes. This is normal — it computes a 2048-bit safe prime.
The systemd service waits indefinitely; do not interrupt it. The file is
written once to `/etc/nginx/ssl/dhparam.pem` and reused for all sites.

**OCSP stapling is disabled** — Let's Encrypt removed OCSP stapling in May
2025. Both `ssl_stapling` lines in `ssl_all_sites.conf` are commented out.
Do not uncomment them when using Let's Encrypt certificates.

**ssl_all_sites.conf is written once** — Stage 21 only creates
`/etc/nginx/ssl/ssl_all_sites.conf` if it does not already exist. This is
intentional — it is shared across all sites on the server. To regenerate
it (e.g. to update cipher configuration), delete the file and re-run Stage 21.

**reuseport on the QUIC listener (Stage 21)** — The HTTPS server block
includes `listen 443 quic reuseport`. This must appear on the FIRST site
only. For any additional site added later, use `listen 443 quic;` without
`reuseport` to avoid a binding conflict.

**SSL renewal cron (Stage 21)** — Two entries are added to the root crontab:
force-renew at 01:00 on the 14th and 28th, Nginx reload at 02:00. The
one-hour gap ensures Certbot finishes before Nginx picks up the new cert.
The script checks for existing entries before adding — re-running is safe.

**Certbot dry-run (Stage 21)** — Stage 21 runs `certbot renew --dry-run`
automatically after setup. A failure means auto-renewal would also fail —
fix DNS or port 80 accessibility before relying on the cron.

**WordPress URL update (Stage 21)** — WP-CLI updates the WordPress site
URLs from `http://` to `https://` automatically, but only if the browser
wizard has already been completed (database tables must exist). If the
wizard has not been run, the script logs the manual command and continues.
After completing the wizard, run:
```bash
sudo -u POOL_USER wp option update siteurl 'https://DOMAIN' --path=/var/www/DOMAIN/public_html
sudo -u POOL_USER wp option update home   'https://DOMAIN' --path=/var/www/DOMAIN/public_html
```
---

## Nginx Application & WordPress Application Hardening — Key Notes

**browser_caching.conf is rewritten in Stage 22** — Nginx `add_header` directives do NOT inherit from parent server block contexts when a child `location` block defines its own `add_header`. Because each caching location block sets its own headers, `http_headers.conf` must be explicitly included inside every location block. Stage 22 rewrites `browser_caching.conf` from scratch to include `etag on`, `if_modified_since exact`, `Pragma "public"`, `try_files`, and the `http_headers.conf` include in each block.

**nginx_security_directives.conf is static** — No site-specific values. The same file is included in every site's server block. The `xmlrpc.php` deny block is commented out by default — some plugins and mobile apps require XML-RPC. If it is not needed, uncomment it. Note that `xmlrpc.php` is already rate-limited in the per-site rate_limiting include regardless.

**DDoS protection is handled at the CDN layer (section 44)** — Broad Nginx-level rate limiting is not applied because WordPress's legitimate traffic (REST API, plugin callbacks, WP-Cron, admin sessions) makes it impractical to set a threshold that stops attacks without also blocking real users. Enable Cloudflare proxy and configure DDoS protection rules in the Cloudflare dashboard instead.

**limit_req_zone is global, location blocks are per-site** — Stage 22 inserts the `limit_req_zone $binary_remote_addr zone=wp:10m rate=30r/m;` directive into the `nginx.conf` http block once (guarded against duplicates). Each site gets its own `rate_limiting_${DOMAIN}.conf` include file with exact-match location blocks for `wp-login.php` and `xmlrpc.php`. The zone name `wp` is shared across all sites.

**Hotlinking with Cloudflare (recommended)** — Set `HOTLINK_PROTECTION=cloudflare` (the default). Enable via: Cloudflare Dashboard → Domain → Scrape Shield → Hotlink Protection → ON. No Nginx config is written in this mode. If `HOTLINK_PROTECTION=nginx`, a `valid_referers` location block is written into the server block — but this will NOT work correctly when Cloudflare proxy is active, because Cloudflare's IPs appear as the referer.

**DISALLOW_FILE_MODS blocks all dashboard file writes** — After Stage 23, WordPress cannot install, update, or delete plugins and themes from the admin dashboard. All updates must be done via SSH (`rsync` or WP-CLI). This is intentional — combined with `PERMISSION_MODE=hardened`, it prevents any PHP code running on the server from modifying WordPress core files.

**DB privilege hardening will break WooCommerce** — `DB_PRIVILEGE_HARDEN=yes` reduces the WordPress database user to `SELECT, INSERT, UPDATE, DELETE` only. WooCommerce requires `CREATE`, `ALTER`, and `INDEX` during plugin activations and order processing. Set `DB_PRIVILEGE_HARDEN=no` for WooCommerce sites. For other sites, if a plugin fails to activate after this step, temporarily grant the additional privilege it needs during activation, then revoke again if it is not needed for ongoing operation.

**REST API plugin must be installed manually (section 50)** — The WordPress REST API is publicly accessible by default, exposing endpoints like `/wp-json/wp/v2/users` (username enumeration). The "Disable REST API" plugin by Dave McHale restricts this to authenticated users. Install from WordPress Admin → Plugins → Add New Plugin → search "disable rest api". Test your page builder and plugins after activation — some require unauthenticated REST access for editor previews. This cannot be automated because plugin installation requires the WordPress admin dashboard (which requires the browser wizard to be complete first).

**Verify security headers** — After Stage 22, check `https://securityheaders.com/?q=DOMAIN` to confirm all five headers are present. `X-Content-Type-Options`, `X-Frame-Options`, `X-XSS-Protection`, `Referrer-Policy`, and `Permissions-Policy` should all appear. Note that `Content-Security-Policy` is not configured — it requires per-site tuning based on the scripts and resources the WordPress theme and plugins load.
