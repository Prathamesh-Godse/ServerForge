# Changelog

All notable changes to ServerForge are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/) once
tagged releases begin.

## [Unreleased]

### Added
- Nothing yet.

### Changed
- Nothing yet.

### Fixed
- Nothing yet.

---

## [0.1.0] — Initial public structure

### Added
- 23-stage reboot-persistent hardening pipeline orchestrated by `main.sh`
  via a self-installing, self-disabling systemd service.
- Stages 1–10: user management, SSH hardening, system updates, timezone,
  firewall (UFW), fail2ban, swap, kernel hardening, fstab hardening, open
  file limits.
- Stages 11–23: LEMP stack install, mail (msmtp), Nginx hardening,
  MariaDB hardening + optimization, PHP hardening, site infrastructure,
  WordPress install, PHP-FPM pool isolation, WordPress hardening, SSL/HTTPS,
  Nginx application hardening, WordPress application hardening.
- Per-stage config files under `configs/` for identity, users, SSH,
  firewall, swap, kernel, limits, LEMP, mail, Nginx, MariaDB, PHP, and site.
- Timestamped, tagged logging to `serverforge.log`.
- `--status` and `--reset` CLI flags.
- Idempotent design — safe to re-run after a failed stage.
- MIT License.

<!--
## [X.Y.Z] — YYYY-MM-DD

### Added
- New features.

### Changed
- Changes to existing functionality.

### Deprecated
- Features that will be removed in a future release.

### Removed
- Features removed in this release.

### Fixed
- Bug fixes.

### Security
- Vulnerability fixes — coordinate with SECURITY.md disclosure process
  before publishing details of an exploitable issue.
-->
