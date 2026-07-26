# Security Policy

ServerForge modifies SSH, firewall, kernel, database, and web server
configuration on production servers. A vulnerability here can mean a
server left less secure than before the script ran, or a compromised
server outright — take reports seriously and report privately.

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, report privately using one of these methods:

1. **Preferred:** Use GitHub's private vulnerability reporting —
   go to the **Security** tab of this repo → **Report a vulnerability**.
2. **Alternative:** Email the maintainer directly (see the GitHub profile
   at [@Prathamesh-Godse](https://github.com/Prathamesh-Godse) for contact
   info) with the subject line `[SECURITY] ServerForge — <short summary>`.

Please include:

- Which stage/script is affected
- The config values or environment needed to reproduce (redact anything
  sensitive — use placeholder domains/IPs)
- What the impact is (e.g., "leaves SSH open to X", "credentials written
  world-readable", "privilege escalation via Y")
- A proposed fix if you have one, though this isn't required

## What counts as a security issue here

Examples of things to report privately rather than as a normal bug:

- A hardening step that silently fails but reports success
- Secrets (DB passwords, SMTP credentials, SSH keys) written with
  incorrect permissions or logged in plaintext where they shouldn't be
- A firewall/SSH/kernel setting that ends up weaker than intended
- Any way a malicious config value could lead to command injection in
  the scripts (since these run as root)
- Backup/restore logic that could leave a server in a broken or
  insecure intermediate state

Normal bugs (a stage errors out, a config option is misdocumented, a
typo) are fine as regular public issues via the bug report template.

## Response

You should expect an acknowledgment within a few days. Since ServerForge
runs as root against live infrastructure, security reports are
prioritized over feature work.

## Disclosure

Please give the maintainer reasonable time to investigate and patch
before any public disclosure. Credit will be given in the fix's
changelog entry unless you prefer to remain anonymous.
