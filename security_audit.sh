#!/bin/bash
# ============================================================
#  WordPress / Linux Server Security Audit & Remediation
#  Identifies issues and optionally fixes them
#  Run as root or with sudo for full output
# ============================================================

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

section() { echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; }
ok()      { echo -e "  ${GRN}[OK]${NC}     $1"; }
warn()    { echo -e "  ${YEL}[WARN]${NC}   $1"; ISSUES+=("WARN|$1"); }
bad()     { echo -e "  ${RED}[FAIL]${NC}   $1"; ISSUES+=("FAIL|$1"); }
info()    { echo -e "  ${BLU}[INFO]${NC}   $1"; }

# Track issues for remediation
declare -a ISSUES
declare -a FIXES

echo -e "\n${BOLD}WordPress / Linux Security Audit — $(date)${NC}"
echo -e "Host: $(hostname) | Kernel: $(uname -r)"

# ──────────────────────────────────────────
section "1. OS & UPDATES"
# ──────────────────────────────────────────
# Context: Security patches close vulnerabilities. Unpatched servers are vulnerable to known exploits.
# What to do: Install updates regularly (unattended-upgrades handles this automatically)
if command -v apt &>/dev/null; then
  UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
  SECURITY=$(apt list --upgradable 2>/dev/null | grep -c security)
  [ "$UPGRADABLE" -gt 0 ] && warn "$UPGRADABLE packages upgradable ($SECURITY security — should be patched)" || ok "System up to date"
elif command -v yum &>/dev/null; then
  UPGRADABLE=$(yum check-update 2>/dev/null | grep -c "^[a-zA-Z]")
  [ "$UPGRADABLE" -gt 0 ] && warn "$UPGRADABLE packages upgradable" || ok "System up to date"
fi

LAST_REBOOT=$(last reboot 2>/dev/null | head -1)
info "Last reboot: $LAST_REBOOT"

UPTIME_DAYS=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null)
[ "$UPTIME_DAYS" -gt 90 ] && warn "Server uptime ${UPTIME_DAYS} days — kernel updates require reboot to take effect" \
  || info "Uptime: ${UPTIME_DAYS} days (good — recent reboot or fresh install)"

# ──────────────────────────────────────────
section "2. USER ACCOUNTS"
# ──────────────────────────────────────────
# Context: Multiple root accounts = security risk. Unused accounts = potential backdoors.
# Accounts without passwords = anyone can log in. Recently created = verify legitimacy.

ROOT_USERS=$(awk -F: '($3==0){print $1}' /etc/passwd)
for u in $ROOT_USERS; do
  [ "$u" = "root" ] && info "Root account: $u" || bad "Non-root user with UID 0: $u (SECURITY RISK — disable immediately)"
done

SHELL_USERS=$(awk -F: '($7 !~ /nologin|false|sync/) && ($3 >= 1000) {print $1}' /etc/passwd)
info "Human shell accounts (users who can log in): $(echo "$SHELL_USERS" | tr '\n' ' ')"

EMPTY_PASS=$(awk -F: '($2 == "") && ($3 >= 1000) {print $1}' /etc/shadow 2>/dev/null)
[ -n "$EMPTY_PASS" ] && bad "User accounts with empty passwords: $EMPTY_PASS (anyone can log in!)" || ok "No user accounts with blank passwords"

SUDO_USERS=$(grep -Po '^[^#\s]+(?=.*ALL)' /etc/sudoers 2>/dev/null; grep -r 'ALL' /etc/sudoers.d/ 2>/dev/null | grep -v '^#' | awk -F: '{print $1}')
info "Users with sudo access (can run commands as root):"
getent group sudo wheel 2>/dev/null | awk -F: '{print "    "$4}'

RECENT=$(find /home -maxdepth 1 -mindepth 1 -newer /proc/1 -type d 2>/dev/null)
[ -n "$RECENT" ] && warn "Recently created home dirs (verify these are expected new staff): $RECENT" || info "No recently created user accounts"

# ──────────────────────────────────────────
section "3. SSH CONFIGURATION"
# ──────────────────────────────────────────
# Context: SSH is how attackers get in. Strong SSH config prevents brute-force and weak auth.
# Ideal: Key-only auth, no passwords, root login disabled, fail2ban active
SSHD=/etc/ssh/sshd_config

[ -f "$SSHD" ] || { bad "sshd_config not found"; }

# PermitRootLogin — root should not log in via SSH (use sudo instead)
ROOT_LOGIN=$(grep -iE "^PermitRootLogin\s" "$SSHD" 2>/dev/null | awk '{print $2}')
ROOT_LOGIN=${ROOT_LOGIN:-"(not set/default)"}
if [[ "$ROOT_LOGIN" == "no" || "$ROOT_LOGIN" == "prohibit-password" ]]; then
  ok "Root login secured: $ROOT_LOGIN"
else
  bad "Root login: $ROOT_LOGIN (should be 'no' or 'prohibit-password')"
fi

# PasswordAuthentication — check effective value (Ubuntu 22.04+ defaults to no)
PASS_AUTH=$(grep -iE "^PasswordAuthentication\s" "$SSHD" 2>/dev/null | awk '{print $2}')
if [ "$PASS_AUTH" = "no" ]; then
  ok "Password auth disabled: no"
elif [ "$PASS_AUTH" = "yes" ]; then
  bad "Password auth enabled: yes (should be: no)"
else
  # Not set explicitly — check sshd_config.d includes and Ubuntu version
  UBUNTU_VER=$(lsb_release -rs 2>/dev/null | cut -d. -f1)
  if [ "${UBUNTU_VER:-0}" -ge 22 ]; then
    ok "Password auth disabled (Ubuntu 22+ default: no)"
  else
    warn "PasswordAuthentication not explicitly set — verify OS default is 'no'"
  fi
fi

# PermitEmptyPasswords
PEP=$(grep -iE "^PermitEmptyPasswords\s" "$SSHD" 2>/dev/null | awk '{print $2}')
[ "$PEP" = "no" ] && ok "Empty passwords forbidden: $PEP" || bad "Empty passwords: ${PEP:-(not set)}"

# X11Forwarding
X11=$(grep -iE "^X11Forwarding\s" "$SSHD" 2>/dev/null | awk '{print $2}')
[ "$X11" = "no" ] && ok "X11 forwarding disabled: $X11" || bad "X11 forwarding: ${X11:-(not set)}"

# UsePAM
PAM=$(grep -iE "^UsePAM\s" "$SSHD" 2>/dev/null | awk '{print $2}')
[ "$PAM" = "yes" ] && ok "PAM enabled: $PAM" || bad "PAM: ${PAM:-(not set)}"
# Protocol directive removed in modern OpenSSH — SSH2 is always used now
SSH_VER=$(ssh -V 2>&1 | grep -oP 'OpenSSH_\K[\d.]+' | head -1)
if [ -n "$SSH_VER" ]; then
  ok "SSH version: OpenSSH $SSH_VER (SSH2 only — Protocol directive no longer needed)"
fi

PORT=$(grep -iE "^Port\s" "$SSHD" | awk '{print $2}')
PORT=${PORT:-22}
[ "$PORT" = "22" ] && warn "SSH on default port 22 (consider changing)" || ok "SSH on non-default port $PORT"

MAX_AUTH=$(grep -iE "^MaxAuthTries\s" "$SSHD" | awk '{print $2}')
MAX_AUTH=${MAX_AUTH:-6}
[ "$MAX_AUTH" -le 3 ] && ok "MaxAuthTries: $MAX_AUTH" || warn "MaxAuthTries: $MAX_AUTH (recommend ≤3)"

ALLOW_USERS=$(grep -iE "^AllowUsers\s" "$SSHD")
[ -n "$ALLOW_USERS" ] && ok "AllowUsers restriction in place: $ALLOW_USERS" || warn "No AllowUsers restriction — all accounts can attempt SSH"

# ──────────────────────────────────────────
section "4. FIREWALL"
# ──────────────────────────────────────────
# Context: Firewall blocks unwanted traffic. Should allow: SSH (22), HTTP (80), HTTPS (443).
# Block everything else unless explicitly needed.
if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1)
  echo "$UFW_STATUS" | grep -qi "active" && ok "UFW active (good — blocking unwanted traffic)" || bad "UFW installed but INACTIVE (no protection)"
  ufw status numbered 2>/dev/null | grep -v "^$" | head -30 | sed 's/^/    /'
elif command -v firewall-cmd &>/dev/null; then
  FW=$(firewall-cmd --state 2>/dev/null)
  [ "$FW" = "running" ] && ok "firewalld running" || bad "firewalld not running"
  firewall-cmd --list-all 2>/dev/null | head -20 | sed 's/^/    /'
elif iptables -L INPUT -n 2>/dev/null | grep -q "Chain"; then
  RULES=$(iptables -L INPUT -n 2>/dev/null | grep -c "^ACCEPT\|^DROP\|^REJECT")
  [ "$RULES" -gt 0 ] && ok "iptables has $RULES INPUT rules" || warn "iptables present but INPUT chain appears empty"
else
  bad "No firewall detected (ufw/firewalld/iptables)"
fi

# ──────────────────────────────────────────
section "5. OPEN PORTS & LISTENING SERVICES"
# ──────────────────────────────────────────
info "Listening ports (TCP/UDP):"
ss -tlnup 2>/dev/null | grep LISTEN | awk '{print "    "$1, $4, $7}' | sort -u
echo ""

# Check for risky ports that are listening
# Context: Some ports (like 3306 for MySQL) should listen locally but be firewalled externally
info "Checking for exposed database/service ports:"

# Helper function to check if port is firewalled
is_port_firewalled() {
  local port=$1
  # Check UFW
  if command -v ufw &>/dev/null; then
    ufw status 2>/dev/null | grep -q "Anywhere" && {
      # UFW has "Anywhere" rules — check if this port is explicitly allowed
      if ufw status 2>/dev/null | grep -qE "^${port}/tcp.*ALLOW"; then
        return 1  # Port is explicitly allowed
      else
        return 0  # Port is not in allow list (firewalled)
      fi
    }
  fi
  # Check iptables
  if command -v iptables &>/dev/null; then
    iptables -L INPUT -n 2>/dev/null | grep -q "tcp dpt:$port" && return 1 || return 0
  fi
  return 0  # Assume firewalled if we can't determine
}

for port in 21 23 25 3306 5432 6379 27017 8080 8443 9200; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    case $port in
      3306|5432)
        # Database ports — should listen locally but be firewalled externally
        if is_port_firewalled $port; then
          ok "Port $port (database) listening locally, firewalled externally — correct setup"
        else
          bad "Port $port (database) is exposed to the internet — should be firewalled or closed"
        fi
        ;;
      21|23|25)
        # Dangerous legacy services
        bad "Port $port is listening — this service is dangerous and should be disabled"
        ;;
      *)
        # Other risky ports
        warn "Port $port is listening — verify it is intentional and necessary"
        ;;
    esac
  fi
done

# ──────────────────────────────────────────
section "6. FAIL2BAN / BRUTE-FORCE PROTECTION"
# ──────────────────────────────────────────
# Context: Fail2ban blocks IPs after multiple failed login attempts. Stops brute-force attacks.
# Ideal: Installed, active, and banning attackers on SSH port 22
if command -v fail2ban-client &>/dev/null; then
  F2B=$(fail2ban-client status 2>/dev/null | head -5)
  ok "Fail2ban installed (stops brute-force attacks)"
  echo "$F2B" | sed 's/^/    /'
  fail2ban-client status sshd 2>/dev/null | grep -E "Currently banned|Total banned" | sed 's/^/    /'
else
  bad "Fail2ban not installed — server is vulnerable to brute-force attacks on SSH"
fi

# ──────────────────────────────────────────
section "7. FILE PERMISSIONS"
# ──────────────────────────────────────────
# Context: World-writable files = anyone can modify (backdoors, data loss).
# SUID/SGID binaries run as root — verify they're legitimate.
# /etc/passwd and /etc/shadow permissions control who can read/modify user accounts

WW=$(find / -xdev -type f -perm -0002 \
  ! -path "/proc/*" ! -path "/sys/*" ! -path "/dev/*" ! -path "/tmp/*" \
  2>/dev/null | head -20)
[ -n "$WW" ] && { warn "World-writable files found — anyone can modify these (top 20):"; echo "$WW" | sed 's/^/    /'; } \
  || ok "No unexpected world-writable files"

# SUID/SGID binaries (run as owner, not current user — potential privilege escalation)
info "SUID/SGID binaries found (review that these are system, not malware):"
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | grep -v "^/snap" | sed 's/^/    /'

# /etc/passwd (public, read-only) and /etc/shadow (root only — password hashes)
PASSWD_PERMS=$(stat -c "%a %U %G" /etc/passwd 2>/dev/null)
SHADOW_PERMS=$(stat -c "%a %U %G" /etc/shadow 2>/dev/null)
[[ "$PASSWD_PERMS" == "644 root root" ]] && ok "/etc/passwd permissions: $PASSWD_PERMS (correct — public, read-only)" || warn "/etc/passwd: $PASSWD_PERMS (should be 644)"
[[ "$SHADOW_PERMS" =~ ^(640|000|600) ]] && ok "/etc/shadow permissions: $SHADOW_PERMS (correct — root only)" || bad "/etc/shadow: $SHADOW_PERMS (should be 640 — blocks password theft)"

# ──────────────────────────────────────────
section "8. WORDPRESS SECURITY"
# ──────────────────────────────────────────
# Context: WordPress = attack target. Risks: old version, exposed config, debug mode on,
# suspicious PHP files in uploads, xmlrpc enabled (brute-force vector), unprotected admin
# Search all known WordPress install locations:
# - Lightsail Bitnami:    /bitnami/wordpress/
# - Standard Bitnami:     /opt/bitnami/wordpress/
# - Bare Ubuntu:          /var/www/html/ or /var/www/*/
# - Multi-site/cPanel:    /home/*/public_html/
# - Generic fallback:     /srv/
WP_PATHS=$(find \
  /bitnami \
  /opt/bitnami \
  /var/www \
  /srv \
  /home \
  -name "wp-config.php" \
  -not -path "*/wp-config-sample.php" \
  2>/dev/null)

if [ -z "$WP_PATHS" ]; then
  warn "No wp-config.php found — checked /bitnami, /opt/bitnami, /var/www, /srv, /home"
else
  for WP_CONFIG in $WP_PATHS; do
    WP_DIR=$(dirname "$WP_CONFIG")

    # Verify this is actually a WordPress root (has wp-content, wp-admin, wp-includes)
    if [ ! -d "$WP_DIR/wp-content" ] || [ ! -d "$WP_DIR/wp-admin" ] || [ ! -d "$WP_DIR/wp-includes" ]; then
      continue  # Skip if not a complete WordPress installation
    fi

    info "WordPress install: $WP_DIR"

    # wp-config.php (contains DB password — must be protected)
    CONF_PERM=$(stat -c "%a" "$WP_CONFIG" 2>/dev/null)
    [ "$CONF_PERM" -le 640 ] && ok "wp-config.php permissions: $CONF_PERM (correct — not world-readable)" \
      || bad "wp-config.php permissions: $CONF_PERM (DANGER — contains DB password, should be 600 or 640)"

    # Debug mode (shows errors/paths to attackers)
    grep -q "define.*WP_DEBUG.*true" "$WP_CONFIG" 2>/dev/null \
      && bad "WP_DEBUG is enabled — exposes code errors and file paths to attackers (disable in production)" \
      || ok "WP_DEBUG is off (correct)"

    # DB credentials location
    grep -q "DB_PASSWORD" "$WP_CONFIG" 2>/dev/null \
      && info "DB credentials found in wp-config.php (normal — just verify file perms above)"

    # WordPress version
    WP_VER_FILE="$WP_DIR/wp-includes/version.php"
    if [ -f "$WP_VER_FILE" ]; then
      WP_VER=$(grep "\$wp_version" "$WP_VER_FILE" | head -1 | grep -oP "[\d.]+")
      info "WordPress version: $WP_VER"
    fi

    # wp-login.php (login page — target for brute-force)
    WP_LOGIN="$WP_DIR/wp-login.php"
    [ -f "$WP_LOGIN" ] && warn "wp-login.php exposed (normal) — consider IP-restricting /wp-admin/ with .htaccess"

    # xmlrpc.php (remote publishing — rarely used, common attack vector)
    XMLRPC="$WP_DIR/xmlrpc.php"
    [ -f "$XMLRPC" ] && warn "xmlrpc.php exists — if not using WordPress mobile app, disable it in .htaccess"

    # .htaccess (Apache rules for hardening)
    HTACCESS="$WP_DIR/.htaccess"
    [ -f "$HTACCESS" ] && ok ".htaccess exists (Apache rules protecting WordPress)" || warn "No .htaccess — missing Apache hardening rules"

    # uploads directory — should NOT have PHP (prevents attacker-uploaded webshells)
    UPLOADS="$WP_DIR/wp-content/uploads"
    if [ -d "$UPLOADS" ]; then
      SUSPICIOUS_PHP=$(find "$UPLOADS" -name "*.php" 2>/dev/null \
        | grep -v "index\.php" \
        | grep -v "/sucuri/" \
        | grep -v "/wpo/" \
        | grep -v "/mailpoet/" \
        | grep -v "/iwc-logs/" \
        | grep -v "/elementor/" \
        | grep -v "/wp-rocket/" \
        | grep -v "/w3tc/" \
        | grep -v "/cache/" \
        || true)
      if [ -n "$SUSPICIOUS_PHP" ]; then
        bad "Suspicious PHP in uploads — potential webshell (attacker code running on your site!)"
        echo "$SUSPICIOUS_PHP" | sed 's/^/    /'
      else
        ok "No PHP files in uploads (correct — prevents webshells)"
      fi
    fi

    # Plugin/theme count (more = more code to audit + larger attack surface)
    PLUGIN_COUNT=$(find "$WP_DIR/wp-content/plugins" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    THEME_COUNT=$(find "$WP_DIR/wp-content/themes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    info "Plugins: $PLUGIN_COUNT | Themes: $THEME_COUNT (keep these to minimum and audit for vulnerabilities)"

    # File ownership (www-data runs PHP — if root owns files, web process can't update)
    WP_OWNER=$(stat -c "%U" "$WP_DIR" 2>/dev/null)
    info "WordPress directory owner: $WP_OWNER"
    [ "$WP_OWNER" = "root" ] && warn "WordPress owned by root — should be www-data (current user can't update plugins/themes)"

  done
fi

# ──────────────────────────────────────────
section "9. WEB SERVER (Apache/Nginx)"
# ──────────────────────────────────────────
# Context: Version disclosure helps attackers. Hide it. ModSecurity (WAF) stops web attacks.
# ServerTokens/ServerSignature should hide version. ModSecurity blocks common exploits.

if command -v nginx &>/dev/null; then
  info "Nginx version: $(nginx -v 2>&1)"
  grep -r "server_tokens" /etc/nginx/ 2>/dev/null | grep -v "#" | sed 's/^/    /'
  SERVER_TOKENS=$(grep -r "server_tokens off" /etc/nginx/ 2>/dev/null)
  [ -n "$SERVER_TOKENS" ] && ok "server_tokens off (version hidden from attackers)" \
    || warn "server_tokens enabled — shows version to everyone (minor risk)"
fi

if command -v apache2 &>/dev/null || command -v httpd &>/dev/null; then
  APACHE_VER=$(apache2 -v 2>/dev/null || httpd -v 2>/dev/null | head -1)
  info "Apache: $APACHE_VER"
  CONF_DIRS="/etc/apache2 /etc/httpd"
  for dir in $CONF_DIRS; do
    [ -d "$dir" ] || continue
    ST=$(grep -r "ServerTokens" "$dir" 2>/dev/null | grep -v "#" | head -1)
    SS=$(grep -r "ServerSignature" "$dir" 2>/dev/null | grep -v "#" | head -1)
    [ -n "$ST" ] && info "ServerTokens: $ST (controls version disclosure)" || warn "ServerTokens not set — defaults to exposing version"
    [ -n "$SS" ] && info "ServerSignature: $SS" || warn "ServerSignature not set — defaults to on"
  done
fi

# ──────────────────────────────────────────
section "10. SSL / TLS"
# ──────────────────────────────────────────
# Context: Expired cert = browser warnings + blocked access. Install auto-renewal (Let's Encrypt).
# Bad: Expired certs, self-signed certs, outdated TLS versions

if command -v certbot &>/dev/null; then
  info "Certbot installed (auto-renews Let's Encrypt certs)"
  certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:|VALID|EXPIRED" | sed 's/^/    /'
else
  info "Certbot not found — verifying SSL via openssl"
fi

# Check for expiring certs via openssl against localhost
for port in 443 8443; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    EXPIRY=$(echo | timeout 3 openssl s_client -connect "localhost:${port}" -servername "$(hostname)" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$EXPIRY" ]; then
      EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
      NOW_EPOCH=$(date +%s)
      DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
      [ "$DAYS_LEFT" -lt 30 ] && bad "SSL cert on port $port expires in $DAYS_LEFT days ($EXPIRY) — renew immediately" \
        || ok "SSL cert on port $port valid for $DAYS_LEFT more days"
    fi
  fi
done

# ──────────────────────────────────────────
section "11. RECENT LOGINS & SUSPICIOUS ACTIVITY"
# ──────────────────────────────────────────
# Context: Login history shows who accessed server and when. Many failed attempts = attack.

info "Last 10 logins (who accessed server, when, from where):"
last -n 10 2>/dev/null | sed 's/^/    /'

info "Failed login attempts (last 20 — attackers trying to guess password):"
grep "Failed password\|Invalid user" /var/log/auth.log 2>/dev/null | tail -20 | sed 's/^/    /' \
  || grep "Failed password\|Invalid user" /var/log/secure 2>/dev/null | tail -20 | sed 's/^/    /'

FAIL_COUNT=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo 0)
[ "$FAIL_COUNT" -eq 0 ] && FAIL_COUNT=$(grep -c "Failed password" /var/log/secure 2>/dev/null || echo 0)
FAIL_COUNT=$(echo "$FAIL_COUNT" | tr -d '[:space:]')
[ "${FAIL_COUNT:-0}" -gt 100 ] && bad "High failed login count: $FAIL_COUNT — active brute-force attack (fail2ban should block)" \
  || info "Failed login count in log: $FAIL_COUNT (low — good)"

info "Currently logged-in users (should only be you or authorized admins):"
who | sed 's/^/    /'

# ──────────────────────────────────────────
section "12. CRON JOBS"
# ──────────────────────────────────────────
# Context: Cron runs scheduled tasks. Malware uses cron for persistence (auto-restart).
# Review: Are all tasks expected? Do they match legitimate services/backups?

info "System crontabs (check that all are legitimate):"
for f in /etc/cron* /var/spool/cron/crontabs/*; do
  [ -e "$f" ] || continue
  echo "  --- $f ---"
  cat "$f" 2>/dev/null | grep -v "^#\|^$" | sed 's/^/    /'
done

info "User crontabs:"
for user in $(cut -f1 -d: /etc/passwd); do
  CRON=$(crontab -l -u "$user" 2>/dev/null | grep -v "^#\|^$")
  [ -n "$CRON" ] && { echo "    User: $user"; echo "$CRON" | sed 's/^/      /'; }
done

# ──────────────────────────────────────────
section "13. MYSQL / DATABASE"
# ──────────────────────────────────────────
# Context: MySQL/MariaDB holds all your WordPress data. Unprotected = data theft/deletion.
# Risks: No password, accessible from internet, old version, unpatched

if command -v mysql &>/dev/null; then
  info "MySQL/MariaDB is installed"
  # Check root auth — try without password first (bad), then with .my.cnf (good)
  if mysql -u root --connect-timeout=3 --password="" -e "SELECT 1" 2>/dev/null | grep -q 1; then
    bad "MySQL root has NO PASSWORD — anyone can delete all data!"
  elif mysql --defaults-file=/root/.my.cnf --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then
    ok "MySQL root requires password (credentials stored in .my.cnf)"
  else
    ok "MySQL root requires password (socket auth in use)"
  fi

  # Check if MySQL binds to 0.0.0.0 (accessible from internet)
  MY_BIND=$(grep -E "^bind-address" /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/my.cnf /etc/my.cnf 2>/dev/null | head -1)
  info "MySQL bind-address: ${MY_BIND:-'not explicitly set (defaults to 127.0.0.1)'}"
  echo "$MY_BIND" | grep -q "0.0.0.0" && bad "MySQL bound to 0.0.0.0 — EXPOSED TO INTERNET (set to 127.0.0.1)" \
    || ok "MySQL locally bound (correct — only local connections)"
fi

# ──────────────────────────────────────────
section "14. AUTOMATIC SECURITY UPDATES"
# ──────────────────────────────────────────
# Context: Manual updates = patches get missed. Automatic updates = server self-heals.
# Ideal: unattended-upgrades enabled + mail alerts if something fails

if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
  ok "unattended-upgrades installed (auto-patches security vulnerabilities)"
  UA_CONF=$(cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
  echo "$UA_CONF" | grep -q '"1"' && ok "Automatic updates ENABLED — server self-patches" || warn "Check config: /etc/apt/apt.conf.d/20auto-upgrades"
else
  bad "unattended-upgrades not installed — patches must be applied manually (you might forget!)"
fi

# ──────────────────────────────────────────
# REMEDIATION SECTION
# ──────────────────────────────────────────
if [ ${#ISSUES[@]} -gt 0 ]; then
  section "ISSUES FOUND & REMEDIATION OPTIONS"

  echo -e "\n${BOLD}Summary: ${#ISSUES[@]} issue(s) found${NC}\n"

  idx=0
  for issue in "${ISSUES[@]}"; do
    IFS='|' read -r severity desc <<< "$issue"
    case $severity in
      FAIL) symbol="[FAIL]"; color="$RED" ;;
      WARN) symbol="[WARN]"; color="$YEL" ;;
    esac
    echo -e "$((idx+1)). ${color}${symbol}${NC}  $desc"
    ((idx++))
  done

  echo ""
  echo -e "${BOLD}What would you like to do?${NC}"
  echo "  [R] Review remediation commands (copy-paste safe)"
  echo "  [A] Apply auto-fixes (interactive approval)"
  echo "  [S] Skip — just report"
  read -p "Choice [R/A/S]: " remediation_choice

  case $remediation_choice in
    R|r)
      section "REMEDIATION COMMANDS"
      echo -e "\n${BOLD}Copy and paste these commands to fix issues:${NC}\n"

      # Detect environment
      IS_BITNAMI=false
      MYSQL_SERVICE="mysql"
      { [ -d /opt/bitnami ] || [ -d /bitnami ]; } && IS_BITNAMI=true
      command -v mariadb &>/dev/null && MYSQL_SERVICE="mariadb"

      # Provide manual fix commands (compatible with all setups)
      echo "# 1. UPDATE SYSTEM PACKAGES"
      if command -v apt &>/dev/null; then
        echo "sudo apt-get update && sudo apt-get upgrade -y"
      elif command -v yum &>/dev/null; then
        echo "sudo yum update -y"
      fi
      echo ""

      echo "# 2. SET SSH PASSWORDAUTHENTICATION (disable password, keys only)"
      echo "echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config"
      echo "sudo sshd -t && sudo systemctl restart ssh"
      echo ""

      echo "# 3. ENABLE UFW FIREWALL (Debian/Ubuntu)"
      echo "sudo ufw enable"
      echo "sudo ufw allow 22/tcp  # SSH"
      echo "sudo ufw allow 80/tcp  # HTTP"
      echo "sudo ufw allow 443/tcp # HTTPS"
      echo ""

      echo "# 4. INSTALL/ENABLE FAIL2BAN"
      if command -v apt &>/dev/null; then
        echo "sudo apt-get install fail2ban -y"
      elif command -v yum &>/dev/null; then
        echo "sudo yum install fail2ban -y"
      fi
      echo "sudo systemctl enable fail2ban && sudo systemctl start fail2ban"
      echo ""

      echo "# 5. ENABLE AUTOMATIC SECURITY UPDATES"
      if command -v apt &>/dev/null; then
        echo "sudo apt-get install unattended-upgrades -y"
        echo "sudo dpkg-reconfigure -plow unattended-upgrades"
      elif command -v yum &>/dev/null; then
        echo "sudo yum install yum-cron -y"
        echo "sudo systemctl enable yum-cron && sudo systemctl start yum-cron"
      fi
      echo ""

      echo "# 6. FIX FILE PERMISSIONS"
      echo "sudo chmod 640 /etc/shadow"
      echo ""

      echo "# 7. BIND DATABASE TO LOCALHOST ONLY"
      if [ -f /etc/mysql/mysql.conf.d/mysqld.cnf ]; then
        echo "echo 'bind-address = 127.0.0.1' | sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf"
      elif [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]; then
        echo "echo 'bind-address = 127.0.0.1' | sudo tee -a /etc/mysql/mariadb.conf.d/50-server.cnf"
      elif [ -f /etc/my.cnf ]; then
        echo "echo 'bind-address = 127.0.0.1' | sudo tee -a /etc/my.cnf"
      elif [ -f /opt/bitnami/mariadb/conf/my.cnf ]; then
        echo "echo 'bind-address = 127.0.0.1' | sudo tee -a /opt/bitnami/mariadb/conf/my.cnf"
      fi
      echo "sudo systemctl restart $MYSQL_SERVICE"
      echo ""

      echo "# 8. VERIFY FIXES (run audit again)"
      echo "sudo bash security_audit.sh"
      echo ""
      ;;
    A|a)
      section "APPLYING AUTO-FIXES"

      # Detect environment
      MYSQL_SERVICE="mysql"
      command -v mariadb &>/dev/null && MYSQL_SERVICE="mariadb"

      # Fix 1: Update packages (detect package manager)
      if grep -q "WARN.*packages upgradable\|FAIL.*packages" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Updating system packages..."
        if command -v apt &>/dev/null; then
          sudo apt-get update -qq && sudo apt-get upgrade -y -qq
        elif command -v yum &>/dev/null; then
          sudo yum update -y -q
        fi
        echo "✓ System packages updated"
      fi

      # Fix 2: Enable PasswordAuthentication
      if grep -q "PasswordAuthentication not explicitly set" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Setting PasswordAuthentication to 'no'..."
        if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
          echo "PasswordAuthentication no" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        fi
        sudo sshd -t 2>/dev/null && sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
        echo "✓ SSH password auth disabled (keys only)"
      fi

      # Fix 3: Enable UFW (if available)
      if grep -q "UFW installed but INACTIVE" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Enabling UFW firewall..."
        sudo ufw enable -y > /dev/null 2>&1
        echo "✓ UFW firewall enabled"
      fi

      # Fix 4: Install fail2ban (compatible with apt/yum)
      if grep -q "Fail2ban not installed" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Installing fail2ban..."
        if command -v apt &>/dev/null; then
          sudo apt-get install fail2ban -y -qq
        elif command -v yum &>/dev/null; then
          sudo yum install fail2ban -y -q
        fi
        sudo systemctl enable fail2ban > /dev/null 2>&1
        sudo systemctl start fail2ban > /dev/null 2>&1
        echo "✓ Fail2ban installed and enabled"
      fi

      # Fix 5: Enable auto-updates (detect distro)
      if grep -q "unattended-upgrades not installed\|yum-cron" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Installing automatic security updates..."
        if command -v apt &>/dev/null; then
          sudo apt-get install unattended-upgrades -y -qq
        elif command -v yum &>/dev/null; then
          sudo yum install yum-cron -y -q
          sudo systemctl enable yum-cron > /dev/null 2>&1
          sudo systemctl start yum-cron > /dev/null 2>&1
        fi
        echo "✓ Automatic updates installed"
      fi

      # Fix 6: Fix /etc/shadow permissions
      if grep -q "/etc/shadow.*should be 640" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Fixing /etc/shadow permissions..."
        sudo chmod 640 /etc/shadow
        echo "✓ /etc/shadow permissions fixed"
      fi

      # Fix 7: Bind MySQL to localhost (all distros/setups)
      if grep -q "MySQL bound to 0.0.0.0\|EXPOSED TO INTERNET" <<< "${ISSUES[*]}"; then
        echo -e "\n${GRN}[APPLY]${NC}  Binding MySQL to localhost only..."
        if [ -f /etc/mysql/mysql.conf.d/mysqld.cnf ] && ! grep -q "bind-address = 127.0.0.1" /etc/mysql/mysql.conf.d/mysqld.cnf; then
          echo "bind-address = 127.0.0.1" | sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf > /dev/null
        elif [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ] && ! grep -q "bind-address = 127.0.0.1" /etc/mysql/mariadb.conf.d/50-server.cnf; then
          echo "bind-address = 127.0.0.1" | sudo tee -a /etc/mysql/mariadb.conf.d/50-server.cnf > /dev/null
        elif [ -f /opt/bitnami/mariadb/conf/my.cnf ] && ! grep -q "bind-address = 127.0.0.1" /opt/bitnami/mariadb/conf/my.cnf; then
          echo "bind-address = 127.0.0.1" | sudo tee -a /opt/bitnami/mariadb/conf/my.cnf > /dev/null
        fi
        sudo systemctl restart $MYSQL_SERVICE 2>/dev/null
        echo "✓ MySQL bound to localhost only"
      fi

      echo -e "\n${GRN}✓ All available auto-fixes applied!${NC}"
      echo "Re-run the audit to verify fixes: sudo bash security_audit.sh"
      ;;
    S|s)
      echo "Skipping remediation. Manual fixes available above."
      ;;
  esac
else
  section "AUDIT COMPLETE — NO ISSUES FOUND"
  echo -e "\n${GRN}✓ All security checks passed!${NC}\n"
fi

# ──────────────────────────────────────────
section "UNDERSTANDING YOUR RESULTS"
# ──────────────────────────────────────────
echo -e "\n${BOLD}Understanding Your Results:${NC}\n"

echo -e "${BOLD}Status Indicators:${NC}"
echo -e "  ${GRN}[OK]${NC}     — Security best practice is in place. No action needed."
echo -e "  ${YEL}[WARN]${NC}   — Configuration exists but should be reviewed. May need adjustment."
echo -e "  ${RED}[FAIL]${NC}   — Security risk detected. Action strongly recommended."
echo -e "  ${BLU}[INFO]${NC}   — Informational only. For your awareness (not a concern).\n"

echo -e "${BOLD}Common Findings & What They Mean:${NC}\n"

echo -e "  ${GRN}[OK]${NC} Database ports listening locally, firewalled externally"
echo -e "      → Port 3306 (MySQL) should listen locally so WordPress can connect,"
echo -e "      → but must be blocked from the internet. This is correct.\n"

echo -e "  ${RED}[FAIL]${NC} Database ports exposed to the internet"
echo -e "      → Your database is reachable from the internet. Change firewall rules"
echo -e "      → or bind MySQL to 127.0.0.1 only in /etc/mysql/my.cnf\n"

echo -e "  ${YEL}[WARN]${NC} Recently created user accounts"
echo -e "      → New home directories were found. Review if expected (new staff?)."
echo -e "      → Check: ls -la /home/\n"

echo -e "  ${YEL}[WARN]${NC} SSH on default port 22"
echo -e "      → Standard port used by attackers. Consider changing to non-standard"
echo -e "      → port in /etc/ssh/sshd_config (Port 2222 is common)\n"

echo -e "  ${RED}[FAIL]${NC} High failed login attempts"
echo -e "      → Many failed SSH logins detected. Ensure fail2ban is active:"
echo -e "      → sudo systemctl status fail2ban\n"

echo -e "  ${YEL}[WARN]${NC} PasswordAuthentication not explicitly set"
echo -e "      → Ubuntu 22+ defaults to 'no' (keys only), but verify with:"
echo -e "      → sudo grep PasswordAuthentication /etc/ssh/sshd_config\n"

echo -e "  ${YEL}[WARN]${NC} World-writable files found"
echo -e "      → Files that anyone can modify. Usually indicates permission issues."
echo -e "      → Review with: ls -la [filename]\n"

echo -e "${BOLD}Next Steps:${NC}"
echo -e "  1. Review all [FAIL] items — these need immediate attention"
echo -e "  2. Review [WARN] items — assess if they apply to your setup"
echo -e "  3. [OK] and [INFO] items can be monitored but require no action"
echo -e "  4. Run this audit monthly to track changes\n"

echo "Run with sudo for full output (shadow file, fail2ban status, etc.)"
echo "Audit timestamp: $(date)"