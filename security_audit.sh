#!/bin/bash
# ============================================================
#  WordPress / Linux Server Security Audit
#  Read-only — no service-affecting changes
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
warn()    { echo -e "  ${YEL}[WARN]${NC}   $1"; }
bad()     { echo -e "  ${RED}[FAIL]${NC}   $1"; }
info()    { echo -e "  ${BLU}[INFO]${NC}   $1"; }

echo -e "\n${BOLD}WordPress / Linux Security Audit — $(date)${NC}"
echo -e "Host: $(hostname) | Kernel: $(uname -r)"

# ──────────────────────────────────────────
section "1. OS & UPDATES"
# ──────────────────────────────────────────
if command -v apt &>/dev/null; then
  UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
  SECURITY=$(apt list --upgradable 2>/dev/null | grep -c security)
  [ "$UPGRADABLE" -gt 0 ] && warn "$UPGRADABLE packages upgradable ($SECURITY security)" || ok "System up to date"
elif command -v yum &>/dev/null; then
  UPGRADABLE=$(yum check-update 2>/dev/null | grep -c "^[a-zA-Z]")
  [ "$UPGRADABLE" -gt 0 ] && warn "$UPGRADABLE packages upgradable" || ok "System up to date"
fi

LAST_REBOOT=$(last reboot 2>/dev/null | head -1)
info "Last reboot: $LAST_REBOOT"

UPTIME_DAYS=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null)
[ "$UPTIME_DAYS" -gt 90 ] && warn "Server uptime ${UPTIME_DAYS} days — consider rebooting after kernel updates" \
  || info "Uptime: ${UPTIME_DAYS} days"

# ──────────────────────────────────────────
section "2. USER ACCOUNTS"
# ──────────────────────────────────────────
ROOT_USERS=$(awk -F: '($3==0){print $1}' /etc/passwd)
for u in $ROOT_USERS; do
  [ "$u" = "root" ] && info "Root account: $u" || bad "Non-root user with UID 0: $u"
done

SHELL_USERS=$(awk -F: '($7 !~ /nologin|false|sync/) && ($3 >= 1000) {print $1}' /etc/passwd)
info "Human shell accounts: $(echo "$SHELL_USERS" | tr '\n' ' ')"

# Only flag real user accounts (UID >= 1000) with empty passwords — system accounts are locked by design
EMPTY_PASS=$(awk -F: '($2 == "") && ($3 >= 1000) {print $1}' /etc/shadow 2>/dev/null)
[ -n "$EMPTY_PASS" ] && bad "User accounts with empty passwords: $EMPTY_PASS" || ok "No user accounts with blank passwords"

SUDO_USERS=$(grep -Po '^[^#\s]+(?=.*ALL)' /etc/sudoers 2>/dev/null; grep -r 'ALL' /etc/sudoers.d/ 2>/dev/null | grep -v '^#' | awk -F: '{print $1}')
info "Sudo/wheel members:"
getent group sudo wheel 2>/dev/null | awk -F: '{print "    "$4}'

# Check for recently created accounts (last 30 days)
RECENT=$(find /home -maxdepth 1 -mindepth 1 -newer /proc/1 -type d 2>/dev/null)
[ -n "$RECENT" ] && warn "Recently created home dirs: $RECENT"

# ──────────────────────────────────────────
section "3. SSH CONFIGURATION"
# ──────────────────────────────────────────
SSHD=/etc/ssh/sshd_config

check_ssh() {
  local key=$1 desired=$2 desc=$3
  val=$(grep -iE "^${key}\s" "$SSHD" 2>/dev/null | awk '{print $2}')
  val=${val:-"(not set/default)"}
  if [[ "$val" == "$desired" ]]; then
    ok "$desc: $val"
  else
    bad "$desc: $val (should be $desired)"
  fi
}

[ -f "$SSHD" ] || { bad "sshd_config not found"; }

# PermitRootLogin — accept both "no" and "prohibit-password" (key-only root is acceptable)
ROOT_LOGIN=$(grep -iE "^PermitRootLogin\s" "$SSHD" 2>/dev/null | awk '{print $2}')
ROOT_LOGIN=${ROOT_LOGIN:-"(not set/default)"}
if [[ "$ROOT_LOGIN" == "no" || "$ROOT_LOGIN" == "prohibit-password" ]]; then
  ok "Root login secured: $ROOT_LOGIN"
else
  bad "Root login: $ROOT_LOGIN (should be 'no' or 'prohibit-password')"
fi

# PasswordAuthentication — check effective value (Ubuntu 22.04+ defaults to no)
PASS_AUTH=$(grep -iE "^PasswordAuthentication\s" "$SSHD" 2>/dev/null | awk '{print $2}')
if [ -z "$PASS_AUTH" ]; then
  # Not set explicitly — check sshd_config.d includes and Ubuntu version
  UBUNTU_VER=$(lsb_release -rs 2>/dev/null | cut -d. -f1)
  if [ "${UBUNTU_VER:-0}" -ge 22 ]; then
    ok "Password auth disabled (Ubuntu 22+ default is no)"
  else
    warn "PasswordAuthentication not set — verify default is 'no' for your OS version"
  fi
elif [ "$PASS_AUTH" = "no" ]; then
  ok "Password auth disabled (keys only): no"
else
  bad "Password auth enabled: $PASS_AUTH (should be no)"
fi

check_ssh "PermitEmptyPasswords"   "no"       "Empty passwords forbidden"
check_ssh "X11Forwarding"          "no"       "X11 forwarding disabled"
check_ssh "UsePAM"                 "yes"      "PAM enabled"
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
if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1)
  echo "$UFW_STATUS" | grep -qi "active" && ok "UFW active" || bad "UFW installed but INACTIVE"
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
info "Unexpected open ports to the internet (checking common risky ones):"
for port in 21 23 25 3306 5432 6379 27017 8080 8443 9200; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    warn "Port $port is listening — verify it is firewalled or needed"
  fi
done

# ──────────────────────────────────────────
section "6. FAIL2BAN / BRUTE-FORCE PROTECTION"
# ──────────────────────────────────────────
if command -v fail2ban-client &>/dev/null; then
  F2B=$(fail2ban-client status 2>/dev/null | head -5)
  ok "Fail2ban installed"
  echo "$F2B" | sed 's/^/    /'
  fail2ban-client status sshd 2>/dev/null | grep -E "Currently banned|Total banned" | sed 's/^/    /'
else
  bad "Fail2ban not installed — brute-force protection missing"
fi

# ──────────────────────────────────────────
section "7. FILE PERMISSIONS"
# ──────────────────────────────────────────
# World-writable files (excluding /proc, /sys, /dev, /tmp)
WW=$(find / -xdev -type f -perm -0002 \
  ! -path "/proc/*" ! -path "/sys/*" ! -path "/dev/*" ! -path "/tmp/*" \
  2>/dev/null | head -20)
[ -n "$WW" ] && { warn "World-writable files found (top 20):"; echo "$WW" | sed 's/^/    /'; } \
  || ok "No unexpected world-writable files"

# SUID/SGID binaries (unexpected ones)
info "SUID binaries (verify these are expected):"
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | grep -v "^/snap" | sed 's/^/    /'

# /etc/passwd and /etc/shadow permissions
PASSWD_PERMS=$(stat -c "%a %U %G" /etc/passwd 2>/dev/null)
SHADOW_PERMS=$(stat -c "%a %U %G" /etc/shadow 2>/dev/null)
[[ "$PASSWD_PERMS" == "644 root root" ]] && ok "/etc/passwd permissions: $PASSWD_PERMS" || warn "/etc/passwd: $PASSWD_PERMS"
[[ "$SHADOW_PERMS" =~ ^(640|000|600) ]] && ok "/etc/shadow permissions: $SHADOW_PERMS" || bad "/etc/shadow: $SHADOW_PERMS (should be 640 or stricter)"

# ──────────────────────────────────────────
section "8. WORDPRESS SECURITY"
# ──────────────────────────────────────────
WP_PATHS=$(find /var/www /srv /home -name "wp-config.php" 2>/dev/null)

if [ -z "$WP_PATHS" ]; then
  warn "No wp-config.php found under /var/www, /srv, /home"
else
  for WP_CONFIG in $WP_PATHS; do
    WP_DIR=$(dirname "$WP_CONFIG")
    info "WordPress install: $WP_DIR"

    # wp-config.php permissions
    CONF_PERM=$(stat -c "%a" "$WP_CONFIG" 2>/dev/null)
    [ "$CONF_PERM" -le 640 ] && ok "wp-config.php permissions: $CONF_PERM" \
      || bad "wp-config.php permissions: $CONF_PERM (should be 600 or 640)"

    # Debug mode
    grep -q "define.*WP_DEBUG.*true" "$WP_CONFIG" 2>/dev/null \
      && bad "WP_DEBUG is enabled — disable in production" \
      || ok "WP_DEBUG is off"

    # DB credentials location
    grep -q "DB_PASSWORD" "$WP_CONFIG" 2>/dev/null \
      && info "DB credentials found in wp-config.php (normal — just verify file perms above)"

    # WordPress version
    WP_VER_FILE="$WP_DIR/wp-includes/version.php"
    if [ -f "$WP_VER_FILE" ]; then
      WP_VER=$(grep "\$wp_version" "$WP_VER_FILE" | head -1 | grep -oP "[\d.]+")
      info "WordPress version: $WP_VER"
    fi

    # wp-login.php exposure
    WP_LOGIN="$WP_DIR/wp-login.php"
    [ -f "$WP_LOGIN" ] && warn "wp-login.php is present — consider IP-restricting or using a login protection plugin"

    # xmlrpc.php
    XMLRPC="$WP_DIR/xmlrpc.php"
    [ -f "$XMLRPC" ] && warn "xmlrpc.php exists — disable if not needed (common brute-force vector)"

    # .htaccess
    HTACCESS="$WP_DIR/.htaccess"
    [ -f "$HTACCESS" ] && ok ".htaccess exists" || warn "No .htaccess in $WP_DIR"

    # uploads directory — no PHP execution
    UPLOADS="$WP_DIR/wp-content/uploads"
    if [ -d "$UPLOADS" ]; then
      if find "$UPLOADS" -name "*.php" 2>/dev/null | grep -q .; then
        bad "PHP files found in uploads directory — potential webshell!"
        find "$UPLOADS" -name "*.php" 2>/dev/null | sed 's/^/    /'
      else
        ok "No PHP files in uploads directory"
      fi
    fi

    # Plugin/theme count
    PLUGIN_COUNT=$(find "$WP_DIR/wp-content/plugins" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    THEME_COUNT=$(find "$WP_DIR/wp-content/themes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    info "Plugins: $PLUGIN_COUNT | Themes: $THEME_COUNT"

    # File ownership — should be www-data or similar, not root
    WP_OWNER=$(stat -c "%U" "$WP_DIR" 2>/dev/null)
    info "WordPress directory owner: $WP_OWNER"
    [ "$WP_OWNER" = "root" ] && warn "WordPress owned by root — recommend www-data or dedicated user"

  done
fi

# ──────────────────────────────────────────
section "9. WEB SERVER (Apache/Nginx)"
# ──────────────────────────────────────────
if command -v nginx &>/dev/null; then
  info "Nginx version: $(nginx -v 2>&1)"
  # Check server_tokens
  grep -r "server_tokens" /etc/nginx/ 2>/dev/null | grep -v "#" | sed 's/^/    /'
  SERVER_TOKENS=$(grep -r "server_tokens off" /etc/nginx/ 2>/dev/null)
  [ -n "$SERVER_TOKENS" ] && ok "server_tokens off (version not exposed)" \
    || warn "server_tokens not set to off — consider hiding Nginx version"
fi

if command -v apache2 &>/dev/null || command -v httpd &>/dev/null; then
  APACHE_VER=$(apache2 -v 2>/dev/null || httpd -v 2>/dev/null | head -1)
  info "Apache: $APACHE_VER"
  # ServerTokens / ServerSignature
  CONF_DIRS="/etc/apache2 /etc/httpd"
  for dir in $CONF_DIRS; do
    [ -d "$dir" ] || continue
    ST=$(grep -r "ServerTokens" "$dir" 2>/dev/null | grep -v "#" | head -1)
    SS=$(grep -r "ServerSignature" "$dir" 2>/dev/null | grep -v "#" | head -1)
    [ -n "$ST" ] && info "ServerTokens: $ST" || warn "ServerTokens not configured — defaults to exposing full version"
    [ -n "$SS" ] && info "ServerSignature: $SS" || warn "ServerSignature not configured"
  done
fi

# ──────────────────────────────────────────
section "10. SSL / TLS"
# ──────────────────────────────────────────
if command -v certbot &>/dev/null; then
  info "Certbot installed"
  certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:|VALID|EXPIRED" | sed 's/^/    /'
else
  info "Certbot not found — verifying SSL manually if applicable"
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
      [ "$DAYS_LEFT" -lt 30 ] && bad "SSL cert on port $port expires in $DAYS_LEFT days ($EXPIRY)" \
        || ok "SSL cert on port $port valid for $DAYS_LEFT more days"
    fi
  fi
done

# ──────────────────────────────────────────
section "11. RECENT LOGINS & SUSPICIOUS ACTIVITY"
# ──────────────────────────────────────────
info "Last 10 logins:"
last -n 10 2>/dev/null | sed 's/^/    /'

info "Failed login attempts (last 20):"
grep "Failed password\|Invalid user" /var/log/auth.log 2>/dev/null | tail -20 | sed 's/^/    /' \
  || grep "Failed password\|Invalid user" /var/log/secure 2>/dev/null | tail -20 | sed 's/^/    /'

FAIL_COUNT=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo 0)
[ "$FAIL_COUNT" -eq 0 ] && FAIL_COUNT=$(grep -c "Failed password" /var/log/secure 2>/dev/null || echo 0)
FAIL_COUNT=$(echo "$FAIL_COUNT" | tr -d '[:space:]')
[ "${FAIL_COUNT:-0}" -gt 100 ] && bad "High failed login count: $FAIL_COUNT — ensure fail2ban is active" \
  || info "Failed login count in log: $FAIL_COUNT"

info "Currently logged-in users:"
who | sed 's/^/    /'

# ──────────────────────────────────────────
section "12. CRON JOBS (check for unexpected entries)"
# ──────────────────────────────────────────
info "System crontabs:"
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
if command -v mysql &>/dev/null; then
  info "MySQL/MariaDB is installed"
  # Check root auth — try without password first (bad), then with .my.cnf (good)
  if mysql -u root --connect-timeout=3 --password="" -e "SELECT 1" 2>/dev/null | grep -q 1; then
    bad "MySQL root accessible without password!"
  elif mysql --defaults-file=/root/.my.cnf --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then
    ok "MySQL root requires authentication (password set)"
  else
    ok "MySQL root requires authentication (or socket auth)"
  fi

  # Check if MySQL binds to 0.0.0.0
  MY_BIND=$(grep -E "^bind-address" /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/my.cnf /etc/my.cnf 2>/dev/null | head -1)
  info "MySQL bind-address: ${MY_BIND:-'not explicitly set (may default to 127.0.0.1)'}"
  echo "$MY_BIND" | grep -q "0.0.0.0" && bad "MySQL bound to 0.0.0.0 — accessible externally!" \
    || ok "MySQL appears locally bound"
fi

# ──────────────────────────────────────────
section "14. AUTOMATIC SECURITY UPDATES"
# ──────────────────────────────────────────
if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
  ok "unattended-upgrades installed"
  UA_CONF=$(cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
  echo "$UA_CONF" | grep -q '"1"' && ok "Automatic updates appear enabled" || warn "Check /etc/apt/apt.conf.d/20auto-upgrades config"
else
  warn "unattended-upgrades not installed — security patches require manual updates"
fi

# ──────────────────────────────────────────
section "AUDIT COMPLETE"
# ──────────────────────────────────────────
echo -e "\n${BOLD}Legend:${NC}"
echo -e "  ${GRN}[OK]${NC}   — Looks good"
echo -e "  ${YEL}[WARN]${NC} — Worth reviewing"
echo -e "  ${RED}[FAIL]${NC} — Action recommended"
echo -e "  ${BLU}[INFO]${NC} — Informational\n"
echo "Run with sudo for full output (shadow file, fail2ban status, etc.)"
echo "Audit timestamp: $(date)"