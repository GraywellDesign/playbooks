#!/bin/bash
# ============================================================
#  Graywell Design — Server Setup & Security Hardening
#  Supports: Bitnami WordPress | Bare Ubuntu
#            AWS (Lightsail/EC2) | DigitalOcean
#
#  Usage: sudo bash server_setup.sh
#  Log:   /opt/setup.log
# ============================================================

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colors & Logging ────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
LOG=/opt/setup.log

log()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
ok()     { echo -e "  ${GRN}[OK]${NC}     $1"; log "[OK] $1"; }
warn()   { echo -e "  ${YEL}[WARN]${NC}   $1"; log "[WARN] $1"; }
bad()    { echo -e "  ${RED}[FAIL]${NC}   $1"; log "[FAIL] $1"; }
info()   { echo -e "  ${BLU}[INFO]${NC}   $1"; log "[INFO] $1"; }
fixed()  { echo -e "  ${GRN}[FIXED]${NC}  $1"; log "[FIXED] $1"; }
section(){ echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; log "=== $1 ==="; }

# Must run as root
[ "$EUID" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

echo -e "\n${BOLD}Graywell Server Setup & Security Hardening${NC}"
echo -e "Started: $(date) | Host: $(hostname)\n"
RUN_START_LINE=$(wc -l < "$LOG" 2>/dev/null || echo 0)
log "=== Setup started on $(hostname) at $(date) ==="

# ──────────────────────────────────────────
# CREDENTIALS (prompted once at start)
# ──────────────────────────────────────────
echo -e "${BOLD}Brevo SMTP credentials needed for SSH login alerts.${NC}"
echo -e "Get these from: Brevo → SMTP & API → SMTP tab\n"
read -rp "  Brevo SMTP username (usually your email): " BREVO_USER
read -rsp "  Brevo SMTP password (your SMTP key):      " BREVO_PASS
echo ""
ALERT_EMAIL="security@graywelldesign.com"
echo ""

# ──────────────────────────────────────────
# DETECT ENVIRONMENT
# ──────────────────────────────────────────
section "Detecting Environment"

# Bitnami or bare?
IS_BITNAMI=false
BITNAMI_WP_DIR=""
if [ -d "/opt/bitnami" ]; then
  IS_BITNAMI=true
  BITNAMI_WP_DIR=$(find /opt/bitnami -name "wp-config.php" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
  info "Bitnami stack detected"
  [ -n "$BITNAMI_WP_DIR" ] && info "WordPress found at: $BITNAMI_WP_DIR" || warn "WordPress not found in Bitnami path"
else
  info "Bare Ubuntu server detected"
fi

# AWS or DigitalOcean?
PLATFORM="unknown"
if curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/instance-id &>/dev/null; then
  PLATFORM="aws"
  info "Platform: AWS (EC2/Lightsail)"
elif curl -sf --max-time 2 http://169.254.169.254/metadata/v1/id &>/dev/null; then
  PLATFORM="digitalocean"
  info "Platform: DigitalOcean"
else
  warn "Platform: Unknown (skipping cloud agent install)"
fi

# Ubuntu version
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
info "Ubuntu version: $UBUNTU_VER"

# Web server detection — Apache or Nginx?
WEB_SERVER="none"
APACHE_CONF=""
NGINX_CONF=""

# Check Apache
for path in /opt/bitnami/apache/conf/httpd.conf /etc/apache2/apache2.conf /etc/httpd/conf/httpd.conf; do
  [ -f "$path" ] && { APACHE_CONF="$path"; WEB_SERVER="apache"; break; }
done

# Check Nginx (may coexist or replace Apache)
for path in /opt/bitnami/nginx/conf/nginx.conf /etc/nginx/nginx.conf; do
  [ -f "$path" ] && { NGINX_CONF="$path"; WEB_SERVER="nginx"; break; }
done

# If both present, Apache takes priority (Bitnami default)
[ -n "$APACHE_CONF" ] && [ -n "$NGINX_CONF" ] && WEB_SERVER="apache"

case "$WEB_SERVER" in
  apache) info "Web server: Apache ($APACHE_CONF)" ;;
  nginx)  info "Web server: Nginx ($NGINX_CONF)" ;;
  none)   warn "No web server config found" ;;
esac

# SSL tool detection
SSL_TOOL="none"
if [ -f /opt/bitnami/bncert-tool ] || command -v bncert-tool &>/dev/null; then
  SSL_TOOL="bncert"
  info "SSL tool: Bitnami bncert"
elif [ -f /opt/bitnami/letsencrypt/lego ]; then
  SSL_TOOL="lego"
  info "SSL tool: Bitnami lego"
elif command -v certbot &>/dev/null; then
  SSL_TOOL="certbot"
  info "SSL tool: certbot"
else
  SSL_TOOL="none"
  warn "No SSL management tool found — will check cert directly"
fi

# ──────────────────────────────────────────
# 1. SYSTEM UPDATES
# ──────────────────────────────────────────
section "1. System Updates"

apt-get update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
if [ "$UPGRADABLE" -gt 0 ]; then
  info "$UPGRADABLE packages to upgrade — upgrading now..."
  apt-get upgrade -y -qq
  fixed "System packages upgraded"
else
  ok "System already up to date"
fi

# unattended-upgrades
if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
  ok "unattended-upgrades already installed"
else
  apt-get install -y -qq unattended-upgrades
  fixed "Installed unattended-upgrades"
fi

UA_CONF=/etc/apt/apt.conf.d/20auto-upgrades
if [ ! -f "$UA_CONF" ] || ! grep -q '"1"' "$UA_CONF" 2>/dev/null; then
  cat > "$UA_CONF" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  fixed "Enabled automatic security updates"
else
  ok "Automatic security updates already configured"
fi

# ──────────────────────────────────────────
# 2. BASE PACKAGES
# ──────────────────────────────────────────
section "2. Base Packages"

PKGS=(python3-pip vim git curl software-properties-common imagemagick)
MISSING=()
for pkg in "${PKGS[@]}"; do
  dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  info "Installing: ${MISSING[*]}"
  apt-get install -y -qq "${MISSING[@]}"
  fixed "Installed missing base packages"
else
  ok "All base packages already installed"
fi

# PHP Imagick
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "")
if [ -n "$PHP_VERSION" ]; then
  if dpkg -l "php${PHP_VERSION}-imagick" 2>/dev/null | grep -q "^ii"; then
    ok "php${PHP_VERSION}-imagick already installed"
  else
    apt-get install -y -qq "php${PHP_VERSION}-imagick"
    phpenmod imagick 2>/dev/null || true
    fixed "Installed and enabled php${PHP_VERSION}-imagick"
  fi
else
  warn "PHP not found — skipping imagick install"
fi

# ──────────────────────────────────────────
# 3. SSH HARDENING
# ──────────────────────────────────────────
section "3. SSH Hardening"

SSHD=/etc/ssh/sshd_config
SSHD_CHANGED=false

apply_ssh_setting() {
  local key=$1 value=$2 desc=$3
  current=$(grep -iE "^${key}\s" "$SSHD" 2>/dev/null | awk '{print $2}')
  if [ "$current" = "$value" ]; then
    ok "$desc already set to: $value"
  else
    # Comment out any existing line and append correct setting
    sed -i "s/^[#[:space:]]*${key}\b.*/#&/" "$SSHD" 2>/dev/null || true
    echo "${key} ${value}" >> "$SSHD"
    fixed "$desc: set to $value (was: ${current:-unset})"
    SSHD_CHANGED=true
  fi
}

apply_ssh_setting "PermitRootLogin"        "prohibit-password" "Root login (key-only)"
apply_ssh_setting "PermitEmptyPasswords"   "no"                "Empty passwords"
apply_ssh_setting "X11Forwarding"          "no"                "X11 forwarding"
apply_ssh_setting "MaxAuthTries"           "3"                 "MaxAuthTries"

# AllowUsers — only add if not already set; include esalas, bitnami (if present), and root
if ! grep -qiE "^AllowUsers\s" "$SSHD"; then
  ALLOW_LIST="esalas root"
  id bitnami &>/dev/null && ALLOW_LIST="esalas bitnami root"
  echo "AllowUsers $ALLOW_LIST" >> "$SSHD"
  fixed "AllowUsers set to: $ALLOW_LIST"
  SSHD_CHANGED=true
else
  ok "AllowUsers already configured: $(grep -iE "^AllowUsers" "$SSHD")"
fi

# Port — warn if still 22, don't change automatically (too risky)
SSH_PORT=$(grep -iE "^Port\s" "$SSHD" | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}
[ "$SSH_PORT" = "22" ] && warn "SSH still on port 22 — consider changing manually after setup" \
  || ok "SSH on non-default port $SSH_PORT"

if $SSHD_CHANGED; then
  # Validate config — try both common paths
  SSHD_BIN=$(command -v sshd || echo "/usr/sbin/sshd")
  if $SSHD_BIN -t 2>/dev/null; then
    # Debian/Ubuntu uses 'ssh', RHEL uses 'sshd'
    SSH_SERVICE="ssh"
    systemctl is-active --quiet sshd 2>/dev/null && SSH_SERVICE="sshd"
    systemctl restart "$SSH_SERVICE" 2>/dev/null \
      && fixed "sshd restarted with new config" \
      || warn "sshd restart failed — config saved but not active yet. Run: systemctl restart $SSH_SERVICE"
  else
    bad "sshd config has errors — NOT restarting. Check $SSHD manually"
  fi
else
  ok "SSH config already hardened — no restart needed"
fi

# ──────────────────────────────────────────
# 4. FAIL2BAN
# ──────────────────────────────────────────
section "4. Fail2Ban"

if ! dpkg -l fail2ban 2>/dev/null | grep -q "^ii"; then
  apt-get install -y -qq fail2ban
  fixed "Installed fail2ban"
else
  ok "fail2ban already installed"
fi

# Configure sshd jail for systemd backend (Debian/Bitnami compatible)
F2B_JAIL=/etc/fail2ban/jail.d/sshd.conf
if [ ! -f "$F2B_JAIL" ]; then
  cat > "$F2B_JAIL" <<'EOF'
[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service
maxretry = 3
bantime = 1h
findtime = 10m
EOF
  fixed "Created fail2ban sshd jail config (systemd backend)"
else
  ok "fail2ban sshd jail already configured"
fi

systemctl enable fail2ban &>/dev/null
systemctl restart fail2ban

# Wait for socket
sleep 3
if fail2ban-client status sshd &>/dev/null; then
  ok "fail2ban running and sshd jail active"
else
  warn "fail2ban started but sshd jail not responding — check: sudo fail2ban-client status"
fi

# ──────────────────────────────────────────
# 5. FIREWALL
# ──────────────────────────────────────────
section "5. Firewall"

if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1)
  if echo "$UFW_STATUS" | grep -qi "active"; then
    ok "UFW already active"
  else
    info "Configuring UFW..."
    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow ssh &>/dev/null
    ufw allow 80/tcp &>/dev/null
    ufw allow 443/tcp &>/dev/null
    ufw --force enable &>/dev/null
    fixed "UFW enabled (SSH, HTTP, HTTPS allowed)"
  fi
else
  apt-get install -y -qq ufw
  ufw --force reset &>/dev/null
  ufw default deny incoming &>/dev/null
  ufw default allow outgoing &>/dev/null
  ufw allow ssh &>/dev/null
  ufw allow 80/tcp &>/dev/null
  ufw allow 443/tcp &>/dev/null
  ufw --force enable &>/dev/null
  fixed "Installed and configured UFW"
fi

# ──────────────────────────────────────────
# 6. MYSQL SECURITY
# ──────────────────────────────────────────
section "6. MySQL / MariaDB Security"

if command -v mysql &>/dev/null || command -v mysqld &>/dev/null; then
  # Check bind address
  MY_BIND=$(grep -E "^bind-address" \
    /etc/mysql/mysql.conf.d/mysqld.cnf \
    /etc/mysql/my.cnf \
    /etc/my.cnf \
    /opt/bitnami/mariadb/conf/my.cnf \
    2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')

  if ss -tlnp 2>/dev/null | grep -E "0\.0\.0\.0:3306|\*:3306" | grep -q .; then
    bad "MySQL/MariaDB is bound to 0.0.0.0 — externally accessible!"
    warn "Manually add 'bind-address = 127.0.0.1' to your MySQL config and restart"
  else
    ok "MySQL/MariaDB is locally bound only"
  fi

  # Check anonymous root access
  if mysql -u root --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then
    bad "MySQL root accessible without password — run mysql_secure_installation"
  else
    ok "MySQL root requires authentication"
  fi
else
  info "MySQL/MariaDB not installed — skipping"
fi

# ──────────────────────────────────────────
# 7. WEB SERVER HARDENING
# ──────────────────────────────────────────
section "7. Web Server Hardening"

restart_webserver() {
  if $IS_BITNAMI; then
    /opt/bitnami/ctlscript.sh restart "$1" &>/dev/null \
      && fixed "$1 restarted (Bitnami)" \
      || warn "$1 restart failed — check manually"
  else
    systemctl restart "$1" 2>/dev/null \
      && fixed "$1 restarted" \
      || warn "$1 restart failed — check manually"
  fi
}

if [ "$WEB_SERVER" = "apache" ] && [ -n "$APACHE_CONF" ]; then
  # ServerTokens
  if grep -q "^ServerTokens Prod" "$APACHE_CONF" 2>/dev/null; then
    ok "ServerTokens already set to Prod"
  else
    sed -i 's/^ServerTokens.*/ServerTokens Prod/' "$APACHE_CONF" 2>/dev/null || true
    grep -q "^ServerTokens" "$APACHE_CONF" || echo "ServerTokens Prod" >> "$APACHE_CONF"
    fixed "ServerTokens set to Prod"
  fi

  # ServerSignature
  if grep -q "^ServerSignature Off" "$APACHE_CONF" 2>/dev/null; then
    ok "ServerSignature already Off"
  else
    sed -i 's/^ServerSignature.*/ServerSignature Off/' "$APACHE_CONF" 2>/dev/null || true
    grep -q "^ServerSignature" "$APACHE_CONF" || echo "ServerSignature Off" >> "$APACHE_CONF"
    fixed "ServerSignature set to Off"
  fi

  restart_webserver "apache"

elif [ "$WEB_SERVER" = "nginx" ] && [ -n "$NGINX_CONF" ]; then
  # Nginx: server_tokens off (hides version number)
  # Check in main config and conf.d/snippets
  NGINX_CONF_DIR=$(dirname "$NGINX_CONF")
  TOKEN_SET=$(grep -r "server_tokens off" "$NGINX_CONF_DIR" 2>/dev/null | grep -v "#" | head -1)

  if [ -n "$TOKEN_SET" ]; then
    ok "server_tokens already off in Nginx"
  else
    # Add to http block in nginx.conf
    if grep -q "http {" "$NGINX_CONF" 2>/dev/null; then
      sed -i '/http {/a\\tserver_tokens off;' "$NGINX_CONF"
      fixed "server_tokens off added to Nginx http block"
    else
      # Add to a separate security snippet
      SNIPPET_DIR="$NGINX_CONF_DIR/conf.d"
      mkdir -p "$SNIPPET_DIR"
      echo "server_tokens off;" > "$SNIPPET_DIR/security.conf"
      fixed "server_tokens off added to $SNIPPET_DIR/security.conf"
    fi
  fi

  # Validate and restart
  if nginx -t &>/dev/null; then
    restart_webserver "nginx"
  else
    bad "Nginx config test failed — NOT restarting. Check: nginx -t"
  fi

else
  warn "No web server config found — skipping web server hardening"
fi

# ──────────────────────────────────────────
# 8. WORDPRESS HARDENING
# ──────────────────────────────────────────
section "8. WordPress Hardening"

# Find all wp-config.php files
WP_CONFIGS=$(find /var/www /srv /home /opt/bitnami -name "wp-config.php" 2>/dev/null || true)

if [ -z "$WP_CONFIGS" ]; then
  info "No WordPress installs found — skipping"
else
  for WP_CONFIG in $WP_CONFIGS; do
    WP_DIR=$(dirname "$WP_CONFIG")
    info "WordPress install: $WP_DIR"

    # wp-config.php permissions
    CONF_PERM=$(stat -c "%a" "$WP_CONFIG" 2>/dev/null)
    if [ "$CONF_PERM" -gt 640 ]; then
      chmod 640 "$WP_CONFIG"
      fixed "wp-config.php permissions: $CONF_PERM → 640"
    else
      ok "wp-config.php permissions: $CONF_PERM"
    fi

    # WP_DEBUG
    if grep -q "define.*WP_DEBUG.*true" "$WP_CONFIG" 2>/dev/null; then
      sed -i "s/define( 'WP_DEBUG', true )/define( 'WP_DEBUG', false )/" "$WP_CONFIG"
      fixed "WP_DEBUG disabled"
    else
      ok "WP_DEBUG already off"
    fi

    # PHP files in uploads (flag only — don't delete automatically)
    UPLOADS="$WP_DIR/wp-content/uploads"
    if [ -d "$UPLOADS" ]; then
      PHP_IN_UPLOADS=$(find "$UPLOADS" -name "*.php" 2>/dev/null | grep -v "index.php" || true)
      if [ -n "$PHP_IN_UPLOADS" ]; then
        bad "Non-index PHP files found in uploads — possible webshells:"
        echo "$PHP_IN_UPLOADS" | sed 's/^/    /'
        warn "Review these manually before deleting"
      else
        ok "No suspicious PHP files in uploads"
      fi
    fi

    # .htaccess exists
    [ -f "$WP_DIR/.htaccess" ] && ok ".htaccess present" || warn "No .htaccess in $WP_DIR"

  done
fi

# ──────────────────────────────────────────
# 9. FILE PERMISSIONS
# ──────────────────────────────────────────
section "9. File Permissions"

# /etc/passwd and /etc/shadow
PASSWD_PERMS=$(stat -c "%a" /etc/passwd 2>/dev/null)
SHADOW_PERMS=$(stat -c "%a" /etc/shadow 2>/dev/null)

[ "$PASSWD_PERMS" = "644" ] && ok "/etc/passwd: $PASSWD_PERMS" || { chmod 644 /etc/passwd; fixed "/etc/passwd set to 644"; }
[[ "$SHADOW_PERMS" =~ ^(640|600|000) ]] && ok "/etc/shadow: $SHADOW_PERMS" || { chmod 640 /etc/shadow; fixed "/etc/shadow set to 640"; }

# World-writable files (quick check, excluding /proc /sys /dev /tmp)
WW_COUNT=$(find / -xdev -type f -perm -0002 \
  ! -path "/proc/*" ! -path "/sys/*" ! -path "/dev/*" ! -path "/tmp/*" \
  2>/dev/null | wc -l)
[ "$WW_COUNT" -gt 0 ] && warn "$WW_COUNT world-writable files found — run security_audit.sh for details" \
  || ok "No world-writable files"

# ──────────────────────────────────────────
# 10. SSL CHECK
# ──────────────────────────────────────────
section "10. SSL Certificate"

case "$SSL_TOOL" in
  bncert)  ok "SSL managed by Bitnami bncert" ;;
  lego)    ok "SSL managed by Bitnami lego (auto-renew cron expected)" ;;
  certbot) ok "SSL managed by certbot"
           certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:|VALID|EXPIRED" | sed 's/^/    /' ;;
  none)    warn "No SSL management tool detected — ensure SSL is configured manually" ;;
esac

# Check actual cert expiry directly regardless of tool
if ss -tlnp 2>/dev/null | grep -q ":443 "; then
  EXPIRY=$(echo | timeout 5 openssl s_client -connect "localhost:443" -servername "$(hostname)" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$EXPIRY" ]; then
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [ "$DAYS_LEFT" -lt 14 ]; then
      bad "SSL cert expires in $DAYS_LEFT days — renew IMMEDIATELY"
    elif [ "$DAYS_LEFT" -lt 30 ]; then
      warn "SSL cert expires in $DAYS_LEFT days — renew soon"
    else
      ok "SSL cert valid for $DAYS_LEFT more days"
    fi
  else
    warn "Could not read SSL cert on port 443 — verify SSL is working"
  fi
else
  warn "Nothing listening on port 443 — SSL may not be configured yet"
fi

# ──────────────────────────────────────────
# 11. USER SETUP (eric / esalas)
# ──────────────────────────────────────────
section "11. User Setup"

ERIC_USER="esalas"
ERIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDsQarFzayxexMgMvDAWsChXZlN6RQBcjmpG7kxYuVxGT5zQ3XwSxybhbcHUTHGfzT0oWw+YprqKOGTpXyERLW3To6yRY1nN6V6MjIpImsdH3ooRbJVIH5RmIZNiIKKcowODraHQweHyfgGfoiX+aN4g5AR7e9BKyAF7Ur2w6YImF2V8YZC+hN6maqYTKHRh5V8XoWXYN+Gaok70Xjzn8nMJkUOIL/333+dvOjD4fGeVeLMB6Msmv118zxNMLLd9UAdw0XjqCRlEYZUXVKA9sd3SBf2eRp9EehmCJFTat2vzyuqqlmVD7Cr1AobwRb6CUXXAOQ91sxJW6xoAJWDaQvn ericsalas@Erics-MacBook-Pro.local"

# Create user if not exists
if id "$ERIC_USER" &>/dev/null; then
  ok "User $ERIC_USER already exists"
else
  useradd -m -s /bin/bash "$ERIC_USER"
  fixed "Created user: $ERIC_USER"
fi

# Passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/$ERIC_USER"
if [ -f "$SUDOERS_FILE" ] && grep -q "NOPASSWD" "$SUDOERS_FILE"; then
  ok "Passwordless sudo already configured for $ERIC_USER"
else
  echo "$ERIC_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
  # Remove any old entry from main sudoers if present
  sed -i "/^${ERIC_USER}\s/d" /etc/sudoers 2>/dev/null || true
  fixed "Passwordless sudo configured for $ERIC_USER"
fi

# SSH directory and authorized_keys
ERIC_SSH_DIR="/home/$ERIC_USER/.ssh"
ERIC_AUTH_KEYS="$ERIC_SSH_DIR/authorized_keys"

if [ ! -d "$ERIC_SSH_DIR" ]; then
  mkdir -p "$ERIC_SSH_DIR"
  fixed "Created $ERIC_SSH_DIR"
fi

if grep -qF "$ERIC_KEY" "$ERIC_AUTH_KEYS" 2>/dev/null; then
  ok "SSH key already in authorized_keys for $ERIC_USER"
else
  echo "$ERIC_KEY" >> "$ERIC_AUTH_KEYS"
  fixed "SSH key added for $ERIC_USER"
fi

# Fix ownership and permissions
chown -R "$ERIC_USER:$ERIC_USER" "/home/$ERIC_USER/.ssh"
chmod 700 "$ERIC_SSH_DIR"
chmod 600 "$ERIC_AUTH_KEYS"
ok "SSH directory permissions set correctly"

# Disable password aging
chage -I -1 -m 0 -M 99999 -E -1 "$ERIC_USER" 2>/dev/null && ok "Password aging disabled for $ERIC_USER" || true

# ──────────────────────────────────────────
# 12. SSH LOGIN EMAIL ALERTS
# ──────────────────────────────────────────
section "12. SSH Login Email Alerts"

# Install msmtp (lightweight SMTP client — no full mail server needed)
if dpkg -l msmtp 2>/dev/null | grep -q "^ii"; then
  ok "msmtp already installed"
else
  apt-get install -y -qq msmtp msmtp-mta
  fixed "Installed msmtp"
fi

# Configure msmtp for Brevo SMTP
MSMTP_CONF=/etc/msmtprc
cat > "$MSMTP_CONF" <<EOF
# msmtp system-wide config — Brevo SMTP
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        brevo
host           smtp-relay.brevo.com
port           587
from           alerts@graywelldesign.com
user           ${BREVO_USER}
password       ${BREVO_PASS}

account default : brevo
EOF
chmod 600 "$MSMTP_CONF"
fixed "msmtp configured with Brevo SMTP"

# Send a test email
echo -e "Subject: [$(hostname)] SSH Alert System Active\n\nSSH login alerts are now configured on $(hostname) ($(hostname -I | awk '{print $1}')).\nSetup completed: $(date)" \
  | msmtp "$ALERT_EMAIL" 2>/dev/null \
  && fixed "Test alert sent to $ALERT_EMAIL" \
  || warn "Test email failed — verify Brevo credentials in $MSMTP_CONF"

# Create the SSH alert script
ALERT_SCRIPT=/opt/scripts/ssh-alert.sh
mkdir -p /opt/scripts
cat > "$ALERT_SCRIPT" <<'SCRIPT'
#!/bin/bash
# Triggered by PAM on SSH login/logout
# Sends email via msmtp (Brevo SMTP)

ALERT_TO="security@graywelldesign.com"
HOST=$(hostname)
IP=$(hostname -I | awk '{print $1}')
DATE=$(date '+%Y-%m-%d %H:%M:%S UTC')

# PAM_TYPE is 'open_session' (login) or 'close_session' (logout)
if [ "$PAM_TYPE" = "open_session" ]; then
  EVENT="LOGIN"
  EMOJI="🔐"
else
  EVENT="LOGOUT"
  EMOJI="🔓"
fi

SUBJECT="[$HOST] SSH ${EVENT}: ${PAM_USER} from ${PAM_RHOST}"
BODY="${EMOJI} SSH ${EVENT} on ${HOST}

User:      ${PAM_USER}
From IP:   ${PAM_RHOST}
Service:   ${PAM_SERVICE}
Time:      ${DATE}
Server IP: ${IP}"

echo -e "Subject: ${SUBJECT}\n\n${BODY}" | /usr/bin/msmtp "$ALERT_TO" 2>/dev/null || true
SCRIPT

chmod 700 "$ALERT_SCRIPT"
fixed "SSH alert script created at $ALERT_SCRIPT"

# Hook into PAM so it fires on every SSH login/logout
PAM_SSHD=/etc/pam.d/sshd
if grep -q "ssh-alert" "$PAM_SSHD" 2>/dev/null; then
  ok "PAM SSH alert hook already in place"
else
  echo "" >> "$PAM_SSHD"
  echo "# SSH login/logout email alerts" >> "$PAM_SSHD"
  echo "session optional pam_exec.so /opt/scripts/ssh-alert.sh" >> "$PAM_SSHD"
  fixed "PAM hook added — alerts will fire on every SSH login and logout"
fi

# ──────────────────────────────────────────
# 13. CLOUD AGENT
# ──────────────────────────────────────────
section "14. Cloud Agent"

if [ "$PLATFORM" = "digitalocean" ]; then
  if systemctl is-active --quiet droplet-agent 2>/dev/null; then
    ok "DigitalOcean agent already running"
  else
    info "Installing DigitalOcean agent..."
    wget -qO- https://repos-droplet.digitalocean.com/install.sh | bash
    fixed "DigitalOcean agent installed"
  fi
elif [ "$PLATFORM" = "aws" ]; then
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    ok "AWS SSM agent already running"
  else
    info "AWS detected — SSM agent not running (install manually if needed)"
  fi
else
  info "Unknown platform — skipping cloud agent"
fi

# ──────────────────────────────────────────
# 12. ANSIBLE
# ──────────────────────────────────────────
section "15. Ansible & Playbooks"

# Install Ansible — use apt on Ubuntu 24.04+, pip3 on older versions
if command -v ansible &>/dev/null; then
  ok "Ansible already installed: $(ansible --version | head -1)"
else
  info "Installing Ansible..."
  UBUNTU_MAJOR=$(lsb_release -rs 2>/dev/null | cut -d. -f1)
  if [ "${UBUNTU_MAJOR:-0}" -ge 24 ]; then
    apt-get install -y -qq ansible \
      && fixed "Ansible installed via apt" \
      || warn "Ansible install failed — try manually: apt install ansible"
  else
    pip3 install ansible --quiet \
      && fixed "Ansible installed via pip3" \
      || warn "Ansible install failed — try manually: pip3 install ansible"
  fi
fi

# Configure Ansible
mkdir -p /etc/ansible
SERVER_IP=$(hostname -I | awk '{print $1}')

# Detect hostname for inventory
SERVER_NAME="server"
[ "$PLATFORM" = "digitalocean" ] && SERVER_NAME="graywelltech"
[ "$PLATFORM" = "aws" ] && SERVER_NAME=$(hostname -s)

cat > /etc/ansible/hosts <<EOF
[myservers]
${SERVER_NAME} ansible_host=${SERVER_IP}
EOF

cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
log_path = /opt/ansible-setup.log

[cache]
plugin = jsonfile
fact_caching_connection = /tmp/ansible-facts
EOF

fixed "Ansible inventory and config written"
ok "Ansible ready — run playbooks manually as needed"

# ──────────────────────────────────────────
# DONE
# ──────────────────────────────────────────
section "Setup Complete"

echo -e "\n${BOLD}Summary log: $LOG${NC}"
echo -e "Ansible log: /opt/ansible-setup.log\n"

# Only count and show entries from this run (lines added after RUN_START_LINE)
FIXED_COUNT=$(tail -n "+$RUN_START_LINE" "$LOG" 2>/dev/null | grep -c "\[FIXED\]" || echo 0)
WARN_COUNT=$(tail  -n "+$RUN_START_LINE" "$LOG" 2>/dev/null | grep -c "\[WARN\]"  || echo 0)
FAIL_COUNT=$(tail  -n "+$RUN_START_LINE" "$LOG" 2>/dev/null | grep -c "\[FAIL\]"  || echo 0)

echo -e "  ${GRN}Fixed:${NC}    $FIXED_COUNT items"
echo -e "  ${YEL}Warnings:${NC} $WARN_COUNT items"
echo -e "  ${RED}Failures:${NC} $FAIL_COUNT items"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${RED}Items needing manual attention:${NC}"
  tail -n "+$RUN_START_LINE" "$LOG" | grep "\[FAIL\]" | sed 's/^/  /'
  echo ""
fi

if [ "$WARN_COUNT" -gt 0 ]; then
  echo -e "${YEL}Warnings to review:${NC}"
  tail -n "+$RUN_START_LINE" "$LOG" | grep "\[WARN\]" | sed 's/^/  /'
  echo ""
fi

echo -e "Completed: $(date)"
log "=== Setup completed on $(hostname) at $(date) ==="