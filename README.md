# ServerForge

Automated, reboot-persistent provisioning for a single-site Ubuntu
LEMP + WordPress server. Runs a fifteen-stage sequence — surviving
reboots between each stage — via a systemd one-shot service that
installs itself on first launch and self-disables when the final
stage completes.

ServerForge takes a fresh Ubuntu server with an existing sudo user
and turns it into a running WordPress site: OS-level hardening
(updates, firewall, fail2ban, kernel and filesystem tuning), then a
tuned LEMP stack (Nginx, MariaDB, PHP-FPM), then the site itself.

---

## Requirements

- **OS**: Ubuntu (uses the `ondrej/php` and `ondrej/nginx` PPAs, which
  are Ubuntu-specific).
- **Access**: run as root (`sudo ./main.sh`). A non-root sudo user must
  already exist and have working SSH access — ServerForge configures
  the server, it does not create accounts or touch SSH.
- **DNS**: point `SITE_DOMAIN` at the server's IP before Stage 14
  (Site Infrastructure) runs, so Nginx starts serving real traffic.

---

## Stage Map

| Stage | Concept                  | Script                              | Reboots? |
|-------|--------------------------|--------------------------------------|----------|
| 1     | System Updates           | `scripts/system_updates.sh`          | Yes      |
| 2     | Timezone                 | `scripts/timezone.sh`                | Yes      |
| 3     | Firewall                 | `scripts/firewall.sh`                | Yes      |
| 4     | Fail2ban                 | `scripts/fail2ban.sh`                | Yes      |
| 5     | Swap                     | `scripts/swap.sh`                    | Yes      |
| 6     | Kernel Hardening         | `scripts/kernel_hardening.sh`        | Yes      |
| 7     | fstab Hardening          | `scripts/fstab_hardening.sh`         | Yes      |
| 8     | Open File Limits         | `scripts/open_file_limits.sh`        | Yes      |
| 9     | LEMP Stack Installation  | `scripts/install_lemp.sh`            | No (→ 10)|
| 10    | Nginx Hardening          | `scripts/configure_nginx.sh`         | No (→ 11)|
| 11    | MariaDB Hardening        | `scripts/harden_mariadb.sh`          | No (→ 12)|
| 12    | MariaDB Optimization     | `scripts/optimize_mariadb.sh`        | No (→ 13)|
| 13    | PHP Hardening            | `scripts/harden_optimize_php.sh`     | No (→ 14)|
| 14    | Site Infrastructure      | `scripts/setup_site_infrastructure.sh` | No (→ 15)|
| 15    | WordPress Installation   | `scripts/install_wordpress.sh`       | No ★     |

★ After Stage 15, finish the WordPress install by completing the
browser setup wizard at `http://${SITE_DOMAIN}/`.

Stages 9→15 chain without reboots. Stages 1–8 each reboot.
After Stage 15 the service disables itself permanently.

The site is served over plain HTTP, under a single shared PHP-FPM
pool (`www-data`). There is no per-site pool isolation and no
built-in TLS termination — put a reverse proxy or your own Certbot
setup in front if you need HTTPS.

---

## Project Structure

```
serverforge/
├── main.sh                           # Orchestrator — run this to start
├── serverforge.service               # Systemd service template
├── serverforge.log                   # All stage output, timestamped
├── configs/
│   ├── server.conf                   # Identity, timezone, fail2ban
│   ├── firewall.conf                 # UFW port rules
│   ├── swap.conf                     # Swap file size and path
│   ├── kernel.conf                   # Kernel tuning: swappiness, IPv6, BBR
│   ├── limits.conf                   # OS open file descriptor limit
│   ├── lemp.conf                     # LEMP stack: PPAs, PHP version, modules
│   ├── nginx_settings.conf           # Nginx: worker limits, body size
│   ├── mariadb.conf                  # MariaDB: InnoDB, binary logs, file limit
│   ├── php.conf                      # PHP: upload limits, memory, rlimit
│   └── site.conf                     # Site: domain, PHP version
└── scripts/
    ├── system_updates.sh             # Stage 1
    ├── timezone.sh                   # Stage 2
    ├── firewall.sh                   # Stage 3
    ├── fail2ban.sh                   # Stage 4
    ├── swap.sh                       # Stage 5
    ├── kernel_hardening.sh           # Stage 6
    ├── fstab_hardening.sh            # Stage 7
    ├── open_file_limits.sh           # Stage 8
    ├── install_lemp.sh               # Stage 9
    ├── configure_nginx.sh            # Stage 10
    ├── harden_mariadb.sh             # Stage 11
    ├── optimize_mariadb.sh           # Stage 12
    ├── harden_optimize_php.sh        # Stage 13
    ├── setup_site_infrastructure.sh  # Stage 14
    └── install_wordpress.sh          # Stage 15
```

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/Prathamesh-Godse/serverforge.git
cd serverforge

# 2. Configure — edit all config files before starting
nano configs/server.conf         # SERVER_USER (must already exist), TIMEZONE, fail2ban settings
nano configs/firewall.conf       # allowed/denied ports
nano configs/swap.conf           # swap file size (default: 2 GB)
nano configs/kernel.conf         # swappiness, IPv6, BBR, apport
nano configs/limits.conf         # open file descriptor limit
nano configs/lemp.conf           # PHP version, PPAs, extensions (defaults usually fine)
nano configs/nginx_settings.conf # worker limits, body size (defaults usually fine)
nano configs/site.conf           # SITE_DOMAIN — your domain name (required)

# 3. Make all scripts executable
chmod +x main.sh scripts/*.sh

# 4. Run as root — service installs itself for reboot persistence
sudo ./main.sh
```

The server reboots **eight times** (after Stages 1–8). Each time it comes
back up the service resumes at the next stage automatically. Stages 9–15
run back-to-back without reboots. After Stage 15 completes the service
disables and removes itself.

---

## Configuration Reference

### `configs/server.conf`

| Variable            | Description                                        |
|---------------------|----------------------------------------------------|
| `SERVER_USER`       | Non-root username — must already exist on the server |
| `TIMEZONE`          | System timezone (e.g. `Asia/Kolkata`)              |
| `FAIL2BAN_BANTIME`  | Ban duration (e.g. `7d`, `1h`, `-1` for permanent)|
| `FAIL2BAN_FINDTIME` | Window for counting failures (e.g. `3h`)           |
| `FAIL2BAN_MAXRETRY` | Failures before a ban is issued                    |

### `configs/firewall.conf`

| Variable           | Description                                         |
|--------------------|-------------------------------------------------------|
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
|-------------------|------------------------------------------------------------|
| `SWAPPINESS`      | Kernel swap eagerness: `1` = last resort (default: `1`)  |
| `VFS_CACHE_PRESSURE` | Filesystem cache retention: lower = hold longer (default: `50`) |
| `DISABLE_IPV6`    | `yes` or `no` — disables IPv6 via GRUB kernel parameter  |
| `DISABLE_APPORT`  | `yes` or `no` — disables Ubuntu crash reporter           |

### `configs/limits.conf`

| Variable       | Description                                               |
|----------------|-------------------------------------------------------------|
| `NOFILE_LIMIT` | Max open file descriptors for all users (default: 120000) |

### `configs/lemp.conf`

| Variable          | Description                                                     |
|-------------------|---------------------------------------------------------------------|
| `NGINX_PPA`       | Ondrej Nginx PPA (default: `ppa:ondrej/nginx`)                  |
| `PHP_VERSION`     | PHP version to install (default: `8.3`)                         |
| `PHP_PPA`         | Ondrej PHP PPA (default: `ppa:ondrej/php`)                      |
| `PHP_EXTENSIONS`  | Space-separated list of PHP extension names (no `php8.3-` prefix)|
| `NGINX_MODULES`   | Space-separated Nginx module package names                       |

### `configs/nginx_settings.conf`

| Variable                      | Description                                               |
|-------------------------------|---------------------------------------------------------------|
| `NGINX_WORKER_RLIMIT_NOFILE`  | Open file descriptor limit per worker (default: `45000`)  |
| `NGINX_WORKER_CONNECTIONS`    | Max simultaneous connections per worker (default: `4096`) |
| `NGINX_CLIENT_MAX_BODY_SIZE`  | Max request body (default: `100m` — reduce to `8m` later)|

### `configs/mariadb.conf`

| Variable                          | Description                                              |
|-----------------------------------|--------------------------------------------------------------|
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

---

## Log Format

Every line of output from every script is appended to `serverforge.log`
in the project root. Each entry is timestamped and tagged with its source:

```
2024-07-03 17:02:11 [MAIN]       Stage 1/15 — System Updates
2024-07-03 17:02:11 [SYS_UPDATE] Starting system updates...
2024-07-03 17:05:33 [SYS_UPDATE] System updates complete.
2024-07-03 17:05:33 [MAIN]       Rebooting to apply changes (will resume at Stage 2)...
2024-07-03 17:08:01 [MAIN]       ServerForge — Resuming at Stage 2 of 15
...
2024-07-03 18:14:55 [LIMITS]     Open file limits configuration complete.
2024-07-03 18:15:01 [MAIN]       Stage 9/15 — LEMP Stack Installation
2024-07-03 18:15:01 [LEMP]       Starting LEMP stack installation...
2024-07-03 18:22:44 [LEMP]       LEMP stack installation complete.
2024-07-03 18:22:44 [MAIN]       Stage 10/15 — Nginx Hardening & Optimization
2024-07-03 18:22:44 [NGINX_CFG]  Starting Nginx hardening and optimization...
2024-07-03 18:22:49 [NGINX_CFG]  Nginx hardening and optimization complete.
...
2024-07-03 18:40:12 [MAIN]       ServerForge setup complete!
```

| Tag               | Source script              |
|-------------------|-----------------------------|
| `[MAIN]`          | `main.sh`                  |
| `[SYS_UPDATE]`    | `system_updates.sh`        |
| `[TIMEZONE]`      | `timezone.sh`              |
| `[FIREWALL]`      | `firewall.sh`              |
| `[FAIL2BAN]`      | `fail2ban.sh`              |
| `[SWAP]`          | `swap.sh`                  |
| `[KERNEL]`        | `kernel_hardening.sh`      |
| `[FSTAB]`         | `fstab_hardening.sh`       |
| `[LIMITS]`        | `open_file_limits.sh`      |
| `[LEMP]`          | `install_lemp.sh`          |
| `[NGINX_CFG]`     | `configure_nginx.sh`       |
| `[MARIADB_HARDEN]`| `harden_mariadb.sh`        |
| `[MARIADB_OPT]`   | `optimize_mariadb.sh`      |
| `[PHP_HARDEN]`    | `harden_optimize_php.sh`   |
| `[SITE_INFRA]`    | `setup_site_infrastructure.sh` |
| `[WP_INSTALL]`    | `install_wordpress.sh`         |

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

- **SERVER_USER must already exist** — create your sudo user and
  confirm you can SSH in *before* running `main.sh`; `SERVER_USER` in
  `server.conf` must match an existing account or `main.sh` exits with
  an error.

- **fstab backups** — Both `swap.sh` and `fstab_hardening.sh` back up
  `/etc/fstab` to `/etc/fstab.bak` before making any changes.

- **GRUB backup** — `kernel_hardening.sh` backs up `/etc/default/grub`
  to `/etc/default/grub.bak` before appending the `ipv6.disable=1`
  parameter. If `update-grub` fails, the original is restored.

- **Swap idempotency** — If a swap file already exists at `SWAP_PATH`
  and is already in `/etc/fstab`, Stage 5 skips creation and logs the
  current state without making any changes.

- **fstab noatime** — `fstab_hardening.sh` detects the root filesystem
  line automatically. If detection fails (unusual fstab layout), it logs
  a warning and skips that step rather than corrupting fstab.

- **suid_dumpable and apport** — If `fs.suid_dumpable` reads back as `2`
  after Stage 6, it means Ubuntu's `apport` crash reporter is overriding
  it. Set `DISABLE_APPORT=yes` in `kernel.conf` (the default) to prevent
  this — the script stops and masks the apport service automatically.

- **LEMP: IPv6 vhost fix** — If IPv6 was disabled in Stage 6, Nginx will
  fail to start after install because the default vhost includes a
  `listen [::]:80` directive. `install_lemp.sh` automatically comments
  this out and backs up the original file before doing so.

- **LEMP: Nginx PPA name** — The PPA changed from `ppa:ondrej/nginx-mainline`
  to `ppa:ondrej/nginx` in April 2025. The default in `lemp.conf` is
  the current name. Update it if you add the PPA manually beforehand.

- **Nginx: nginx.conf is fully replaced** — `configure_nginx.sh` writes
  the entire `nginx.conf` from scratch rather than using `sed`. The
  original is backed up to `nginx.conf.bak` before any changes. If
  `nginx -t` fails after writing, the backup is restored automatically.

- **Nginx: client_max_body_size** — Set to `100m` by default to allow
  WordPress theme and plugin uploads during site setup. Change
  `NGINX_CLIENT_MAX_BODY_SIZE` to `8m` in `nginx_settings.conf` and
  re-run Stage 10 once the site is fully configured.

- **Nginx: bash aliases** — Stage 10 appends aliases (`ngt`, `ngr`,
  `fpmr`, `ngin`, `ngsa`, `server_update`) to `~/.bash_aliases` for
  `SERVER_USER`. They become active on the next SSH login or after
  running `source ~/.bash_aliases`.

- **MariaDB hardening is non-interactive** — Stage 11 runs the
  equivalent SQL of `mysql_secure_installation` directly via
  `mysql -e` — no interactive prompts are needed. On Ubuntu, MariaDB
  root uses unix socket auth (no password), so `sudo mysql` is used
  throughout. The script is idempotent — safe to re-run.

- **MariaDB InnoDB log file size requires a stop** — Stage 12 stops
  MariaDB before editing `50-server.cnf`, then starts it again. This
  is mandatory — changing `innodb_log_file_size` while MariaDB is
  running and then restarting can corrupt InnoDB tables. The script
  checks that MariaDB stopped cleanly before proceeding.

- **InnoDB buffer pool sizing** — The default `MARIADB_INNODB_BUFFER_POOL_SIZE`
  of `800M` assumes a 1 GB RAM server. Scale it to ~80% of your actual
  RAM: `2 GB → 1600M`, `4 GB → 3200M`. Update `configs/mariadb.conf`
  before Stage 12 runs.

- **MySQLTuner** — Stage 12 downloads `mysqltuner.pl` to
  `~/MySQLTuner/`. Do **not** run it immediately — MySQLTuner needs
  the server to have been under real load for 60–90 days before its
  recommendations are meaningful. Run it periodically as a health check:
  `sudo ~/MySQLTuner/mysqltuner.pl`

- **Single shared PHP-FPM pool** — All PHP execution runs under the
  default `www-data` pool — there's no per-site pool isolation.
  `display_errors = Off` globally (via `expose_php = Off`) suppresses
  errors from browser output.

- **allow_url_fopen** — Stage 13 sets `allow_url_fopen = Off`
  globally. WordPress requires it to be `On` for plugin/theme updates
  and the HTTP API. If you need this, enable it manually in
  `/etc/php/8.3/fpm/pool.d/www.conf` (or your active pool config).

- **PHP-FPM restart vs reload** — Stage 13 uses `systemctl restart`
  (not `reload`) for PHP-FPM. `rlimit_files` and `rlimit_core` changes
  in `php-fpm.conf` require re-launching the master process — a reload
  applies ini changes but does not change the process-level resource limits.

- **DNS must be live before Stage 14** — `setup_site_infrastructure.sh`
  creates the Nginx server block and reloads Nginx. Nginx will start
  accepting traffic for `SITE_DOMAIN` after reload. If DNS is not yet
  pointing to the server, the server block will exist but no real traffic
  will hit it — this is fine. The browser wizard (Stage 15's manual step)
  requires DNS to be live and resolving correctly.

- **Site domain is required** — `SITE_DOMAIN` in `configs/site.conf` must
  be set before Stage 14 runs. The script will exit with an error if it is
  still the placeholder value `<your-domain.com>`.

- **DB credentials are auto-generated** — Stage 15 generates random values
  for the database name, username, password, and table prefix using
  `/dev/urandom`. These are written to `~/serverforge-${SITE_DOMAIN}-credentials.txt`
  (chmod 600). The file also has placeholder fields for the WordPress admin
  credentials you create during the browser wizard — fill them in and store
  the file in a password manager.

- **WordPress browser wizard is manual** — Stage 15 deploys the WordPress
  files and configures `wp-config.php`, but the final database table
  creation and admin account setup require navigating to
  `http://${SITE_DOMAIN}/` in a browser to complete the wizard.

- **WordPress first-login housekeeping (manual after wizard):**
  - Settings → Permalinks → Post name structure → Save
  - Plugins → delete Akismet and Hello Dolly (unused defaults)
  - Appearance → delete unused default themes (TT3, TT4, etc.)
  - Users → Profile → update Nickname and "Display name publicly as"
  - Install a maintenance mode plugin while configuring the site

- **FastCGI socket** — Stage 14 creates the server block pointing to
  the default PHP-FPM socket (`php8.3-fpm.sock`), matching the shared
  pool set up in Stage 9.

- **Browser caching and FastCGI include files** — `browser_caching.conf`
  and `fastcgi_optimize.conf` are written to `/etc/nginx/includes/` in
  Stage 14. They are referenced from the server block and any future
  server blocks via a single `include` directive each.

---

## Security Notes

- Traffic is served over plain HTTP. If you need TLS, terminate it at
  a reverse proxy (e.g. Cloudflare, an upstream load balancer) or add
  your own Certbot configuration — ServerForge doesn't manage
  certificates.
- SSH access and user accounts are entirely out of scope — lock down
  SSH (key-only auth, no root login) before pointing this at a
  public-facing server.
- The WordPress database user retains full privileges, and the REST
  API and admin dashboard file-write access are left at WordPress
  defaults. If you need a more locked-down posture, apply it manually
  after Stage 15.
