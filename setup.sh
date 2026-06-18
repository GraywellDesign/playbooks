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
# BULK INPUT MODE
# ──────────────────────────────────────────
# Usage: sudo bash server_setup.sh <<< "brevo_user;brevo_pass;mysql_root_pass"
# Example: sudo bash server_setup.sh <<< "alerts@example.com;smtp_key_xyz123;mypassword123"
# Or leave empty to use interactive prompts:
#          sudo bash server_setup.sh <<< ";;;"

BULK_INPUT=$(head -n1 2>/dev/null)
BULK_MODE=false

if [ -n "$BULK_INPUT" ] && [ "$BULK_INPUT" != ";;" ]; then
  # Parse bulk input (semicolon-delimited)
  IFS=';' read -r BREVO_USER BREVO_PASS MYSQL_ROOT_PASS <<< "$BULK_INPUT"

  # Trim whitespace
  BREVO_USER=$(echo "$BREVO_USER" | xargs)
  BREVO_PASS=$(echo "$BREVO_PASS" | xargs)
  MYSQL_ROOT_PASS=$(echo "$MYSQL_ROOT_PASS" | xargs)

  BULK_MODE=true
  info "Bulk input detected"
  info "Brevo SMTP user: ${BREVO_USER:-(not provided)}"
  info "MySQL root password: ${MYSQL_ROOT_PASS:-(not provided)}"
  echo ""
else
  # ──────────────────────────────────────────
  # INTERACTIVE CREDENTIALS (prompted once at start)
  # ──────────────────────────────────────────
  echo -e "${BOLD}A few credentials are needed before setup begins.${NC}\n"

  echo -e "${BOLD}Brevo SMTP${NC} (for SSH login + watchdog alerts)"
  echo -e "Get these from: Brevo → Transactional → SMTP & API → SMTP tab\n"
  read -rp  "  Brevo SMTP username (usually your email): " BREVO_USER
  read -rsp "  Brevo SMTP password (your SMTP key):      " BREVO_PASS
  echo ""
  ALERT_EMAIL="security@graywelldesign.com"

  echo ""
  echo -e "${BOLD}MySQL Root Password${NC}"
  echo -e "This will be set as the MySQL root password and stored in /root/.my.cnf\n"
  read -rsp "  MySQL root password (leave blank to skip): " MYSQL_ROOT_PASS
  echo ""
  echo ""
fi

# Set default alert email if not in bulk mode
ALERT_EMAIL="${ALERT_EMAIL:-security@graywelldesign.com}"

# ──────────────────────────────────────────
# DETECT ENVIRONMENT
# ──────────────────────────────────────────
section "Detecting Environment"

# Bitnami or bare?
IS_BITNAMI=false
BITNAMI_WP_DIR=""
if [ -d "/opt/bitnami" ] || [ -d "/bitnami" ]; then
  IS_BITNAMI=true
  # Search both Bitnami paths — Lightsail uses /bitnami/wordpress, standard uses /opt/bitnami
  BITNAMI_WP_DIR=$(find /opt/bitnami /bitnami -name "wp-config.php" 2>/dev/null \
    | grep -v "wp-config-sample.php" | head -1 | xargs dirname 2>/dev/null || echo "")
  info "Bitnami stack detected"
  [ -n "$BITNAMI_WP_DIR" ] && info "WordPress found at: $BITNAMI_WP_DIR" || warn "WordPress not found in Bitnami paths (/opt/bitnami, /bitnami)"
else
  info "Bare Ubuntu server detected"
fi

# AWS or DigitalOcean?
# Use IMDSv2 token for AWS (Lightsail supports it; IMDSv1 may be disabled)
PLATFORM="unknown"
AWS_TOKEN=$(curl -sf --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null || echo "")
if [ -n "$AWS_TOKEN" ]; then
  INSTANCE_ID=$(curl -sf --max-time 3 \
    -H "X-aws-ec2-metadata-token: $AWS_TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
fi
# Fall back to IMDSv1 if token request failed (some Lightsail configs still allow it)
if [ -z "${INSTANCE_ID:-}" ]; then
  INSTANCE_ID=$(curl -sf --max-time 3 \
    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
fi

if [ -n "${INSTANCE_ID:-}" ]; then
  PLATFORM="aws"
  info "Platform: AWS (EC2/Lightsail) — instance $INSTANCE_ID"
elif curl -sf --max-time 3 http://169.254.169.254/metadata/v1/id &>/dev/null; then
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

# Check Apache — Lightsail Bitnami, standard Bitnami, bare Ubuntu
for path in \
  /bitnami/apache2/conf/httpd.conf \
  /opt/bitnami/apache/conf/httpd.conf \
  /etc/apache2/apache2.conf \
  /etc/httpd/conf/httpd.conf; do
  [ -f "$path" ] && { APACHE_CONF="$path"; WEB_SERVER="apache"; break; }
done

# Check Nginx — Lightsail Bitnami, standard Bitnami, bare Ubuntu
for path in \
  /bitnami/nginx/conf/nginx.conf \
  /opt/bitnami/nginx/conf/nginx.conf \
  /etc/nginx/nginx.conf; do
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

# AllowUsers — build a comprehensive list that includes ALL existing shell users
# so we never accidentally lock anyone out
if ! grep -qiE "^AllowUsers\s" "$SSHD"; then
  # Start with known admin users
  ALLOW_LIST="esalas root"

  # Add any existing human shell users (UID >= 1000) that have SSH keys
  for user in $(awk -F: '($3>=1000) && ($7 !~ /nologin|false/) {print $1}' /etc/passwd 2>/dev/null); do
    if [ -f "/home/${user}/.ssh/authorized_keys" ] || [ -f "/home/${user}/.ssh/id_rsa" ] || [ -f "/home/${user}/.ssh/id_ed25519" ]; then
      echo "$ALLOW_LIST" | grep -qw "$user" || ALLOW_LIST="$ALLOW_LIST $user"
    fi
  done

  # Always include the cloud provider default user
  for cloud_user in ubuntu bitnami admin ec2-user debian; do
    id "$cloud_user" &>/dev/null && echo "$ALLOW_LIST" | grep -qw "$cloud_user" || {
      id "$cloud_user" &>/dev/null && ALLOW_LIST="$ALLOW_LIST $cloud_user"
    }
  done

  echo "AllowUsers $ALLOW_LIST" >> "$SSHD"
  fixed "AllowUsers set to: $ALLOW_LIST"
  SSHD_CHANGED=true
else
  # AllowUsers already set — make sure esalas and cloud users are included
  CURRENT_ALLOW=$(grep -iE "^AllowUsers\s" "$SSHD" | sed 's/AllowUsers\s*//')
  NEEDS_UPDATE=false
  ADD_USERS=""

  # Check esalas is included
  echo "$CURRENT_ALLOW" | grep -qw "esalas" || { ADD_USERS="$ADD_USERS esalas"; NEEDS_UPDATE=true; }

  # Check cloud default users
  for cloud_user in ubuntu bitnami; do
    id "$cloud_user" &>/dev/null && ! echo "$CURRENT_ALLOW" | grep -qw "$cloud_user" && {
      ADD_USERS="$ADD_USERS $cloud_user"
      NEEDS_UPDATE=true
    }
  done

  if $NEEDS_UPDATE; then
    NEW_ALLOW="$CURRENT_ALLOW $ADD_USERS"
    sed -i "s/^AllowUsers.*/AllowUsers $NEW_ALLOW/" "$SSHD"
    fixed "AllowUsers updated to include: $ADD_USERS"
    SSHD_CHANGED=true
  else
    ok "AllowUsers already configured: $(grep -iE "^AllowUsers" "$SSHD")"
  fi
fi

# Port — warn if still 22, don't change automatically (too risky)
SSH_PORT=$(grep -iE "^Port\s" "$SSHD" | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}
[ "$SSH_PORT" = "22" ] && warn "SSH still on port 22 — consider changing manually after setup" \
  || ok "SSH on non-default port $SSH_PORT"

if $SSHD_CHANGED; then
  # Safety check — make sure the current SSH session user is in AllowUsers
  CURRENT_SESSION_USER="${SUDO_USER:-$(whoami)}"
  ALLOW_LINE=$(grep -iE "^AllowUsers\s" "$SSHD" || echo "")
  if [ -n "$ALLOW_LINE" ] && ! echo "$ALLOW_LINE" | grep -qw "$CURRENT_SESSION_USER"; then
    bad "SAFETY CHECK FAILED: Current user '$CURRENT_SESSION_USER' is not in AllowUsers!"
    bad "Adding $CURRENT_SESSION_USER to AllowUsers to prevent lockout..."
    sed -i "s/^AllowUsers.*/& $CURRENT_SESSION_USER/" "$SSHD"
    warn "Added $CURRENT_SESSION_USER to AllowUsers — verify sshd_config before restarting"
  fi

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
  if ss -tlnp 2>/dev/null | grep -E "0\.0\.0\.0:3306|\*:3306" | grep -q .; then
    bad "MySQL/MariaDB is bound to 0.0.0.0 — externally accessible!"
    warn "Manually add 'bind-address = 127.0.0.1' to your MySQL config and restart"
  else
    ok "MySQL/MariaDB is locally bound only"
  fi

  # ── Detect how root currently authenticates ──────────────────
  # Lightsail/Bitnami MariaDB typically uses unix_socket auth for root —
  # connecting via sudo mysql (no password) is the expected pattern.
  MYSQL_ROOT_CMD=""
  if mysql -u root --connect-timeout=3 --password="" -e "SELECT 1" 2>/dev/null | grep -q 1; then
    MYSQL_ROOT_CMD="mysql -u root --password=''"
    info "MySQL root: no-password access (socket or empty password)"
  elif sudo mysql --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then
    MYSQL_ROOT_CMD="sudo mysql"
    info "MySQL root: unix_socket auth via sudo (Lightsail/Bitnami default)"
  elif [ -f /root/.my.cnf ] && mysql --defaults-file=/root/.my.cnf --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then
    MYSQL_ROOT_CMD="mysql --defaults-file=/root/.my.cnf"
    info "MySQL root: credentials from /root/.my.cnf"
  else
    bad "Cannot connect to MySQL as root — skipping DB steps"
  fi

  # ── Set root password if provided ────────────────────────────
  if [ -n "${MYSQL_ROOT_PASS:-}" ] && [ -n "$MYSQL_ROOT_CMD" ]; then
    # Check if root is currently passwordless / socket-auth
    if mysql -u root --connect-timeout=3 --password="" -e "SELECT 1" 2>/dev/null | grep -q 1 \
       || sudo mysql --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then

      # Try ALTER USER (MySQL 5.7+ / MariaDB 10.4+)
      SET_OK=false
      $MYSQL_ROOT_CMD -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;" 2>/dev/null \
        && SET_OK=true

      # Fallback: MariaDB older syntax
      if ! $SET_OK; then
        $MYSQL_ROOT_CMD -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASS}'); FLUSH PRIVILEGES;" 2>/dev/null \
          && SET_OK=true
      fi

      # Fallback: mysqladmin
      if ! $SET_OK; then
        mysqladmin -u root password "${MYSQL_ROOT_PASS}" 2>/dev/null && SET_OK=true
      fi

      $SET_OK && fixed "MySQL root password set" || bad "Could not set MySQL root password — set manually with: ALTER USER 'root'@'localhost' IDENTIFIED BY 'newpass';"

      # Update MYSQL_ROOT_CMD now that password is set
      MYSQL_ROOT_CMD="mysql -u root -p'${MYSQL_ROOT_PASS}'"
    else
      ok "MySQL root already has a password — skipping"
    fi
  fi

  # ── Write /root/.my.cnf ───────────────────────────────────────
  if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    cat > /root/.my.cnf <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASS}
EOF
    chmod 600 /root/.my.cnf
    MYSQL_ROOT_CMD="mysql --defaults-file=/root/.my.cnf"
    fixed "MySQL credentials saved to /root/.my.cnf"
  elif [ -f /root/.my.cnf ]; then
    ok "/root/.my.cnf already exists"
  else
    warn "No MySQL root password provided — watchdog MySQL check may fail if password is set"
  fi

  # ── Verify connectivity ───────────────────────────────────────
  if [ -n "$MYSQL_ROOT_CMD" ] && $MYSQL_ROOT_CMD --connect-timeout=3 -e "SELECT 1" 2>/dev/null | grep -q 1; then
    ok "MySQL root authentication working"
  else
    bad "MySQL root not accessible — run mysql_secure_installation manually"
  fi

  # ── Harden WordPress DB users ────────────────────────────────
  # Supports three wp-config.php password patterns:
  #
  #   A) Standard:   define( 'DB_PASSWORD', 'somepassword' );
  #   B) Lightsail:  $db_password = shell_exec('tail -n 1 /opt/aws/wordpress/credentials.log');
  #                  define( 'DB_PASSWORD', $db_password );
  #   C) Other external file/env patterns (falls through to manual warning)
  #
  # Strategy for all cases:
  #   1. Read DB_NAME and DB_USER from wp-config.php
  #   2. Detect which password pattern is in use
  #   3. Generate a new strong password
  #   4. ALTER USER in MySQL (source of truth)
  #   5. Write new password to the correct location (wp-config.php or credentials.log)
  #   6. Verify the connection works

  # Smart wp-config.php finder — searches all known locations including Lightsail's /var/www/html
  WP_CONFIGS_FOR_DB=$(find \
    /bitnami /opt/bitnami /var/www /srv /home \
    -name "wp-config.php" -not -path "*/wp-config-sample.php" \
    2>/dev/null || true)

  if [ -n "$WP_CONFIGS_FOR_DB" ] && [ -n "$MYSQL_ROOT_CMD" ]; then
    for WP_CFG in $WP_CONFIGS_FOR_DB; do
      WP_DB_NAME=$(grep "DB_NAME" "$WP_CFG" 2>/dev/null | grep -oP "(?<=')[^']+(?=')" | tail -1)
      WP_DB_USER=$(grep "DB_USER" "$WP_CFG" 2>/dev/null | grep -oP "(?<=')[^']+(?=')" | tail -1)

      if [ -z "$WP_DB_NAME" ] || [ -z "$WP_DB_USER" ]; then
        warn "Could not parse DB_NAME/DB_USER from $WP_CFG — skipping"
        continue
      fi

      info "WordPress install: $WP_CFG"
      info "  DB_NAME=$WP_DB_NAME  DB_USER=$WP_DB_USER"

      # ── Detect password storage pattern ──────────────────────
      PASS_PATTERN="unknown"
      CREDENTIALS_LOG=""

      if grep -q "shell_exec\|credentials" "$WP_CFG" 2>/dev/null; then
        # Lightsail pattern — password comes from an external file, referenced in one of two ways:
        #   Style A (older): shell_exec('tail -n 1 /opt/aws/wordpress/credentials.log')
        #   Style B (newer): $cmd = 'tail -n 1 /opt/aws/wordpress/credentials.log';
        #                    $db_password = shell_exec($cmd);
        # Grab the path from the line containing 'tail -n 1 /...'
        # Use tr -d to strip any trailing newline/whitespace that grep -oP can capture
        CREDENTIALS_LOG=$(grep -oP "(?<=tail -n 1 )[^\s'\"\\\\);]+" "$WP_CFG" 2>/dev/null \
          | head -1 | tr -d '[:space:]')

        # Fallback: any quoted absolute path ending in .log anywhere near shell_exec
        if [ -z "$CREDENTIALS_LOG" ]; then
          CREDENTIALS_LOG=$(grep -A2 -B2 "shell_exec\|DB_PASSWORD" "$WP_CFG" \
            | grep -oP "/[^\s'\"]+\.log" | head -1 | tr -d '[:space:]')
        fi

        # Debug: log exactly what we extracted so future failures are diagnosable
        info "  Extracted credentials path: '${CREDENTIALS_LOG}'"

        if [ -n "$CREDENTIALS_LOG" ] && [ -f "$CREDENTIALS_LOG" ]; then
          PASS_PATTERN="lightsail_credentials_log"
          info "  Password pattern: Lightsail credentials.log ($CREDENTIALS_LOG)"
        elif [ -n "$CREDENTIALS_LOG" ]; then
          warn "  Credentials file referenced but not found: '$CREDENTIALS_LOG' — creating it"
          mkdir -p "$(dirname "$CREDENTIALS_LOG")"
          PASS_PATTERN="lightsail_credentials_log"
        else
          warn "  shell_exec/credentials detected but could not extract file path from $WP_CFG"
          PASS_PATTERN="unknown"
        fi
      elif grep -q "DB_PASSWORD" "$WP_CFG" 2>/dev/null \
           && grep "DB_PASSWORD" "$WP_CFG" | grep -q "define"; then
        PASS_PATTERN="standard"
        info "  Password pattern: standard define('DB_PASSWORD', '...')"
      fi

      if [ "$PASS_PATTERN" = "unknown" ]; then
        warn "  Cannot determine password storage pattern for $WP_CFG — skipping DB password rotation"
        warn "  Manually set password in MySQL and update wp-config.php"
        continue
      fi

      # ── Generate new strong password ──────────────────────────
      # Alphanumeric only — safe in shell, PHP, and MySQL without escaping
      NEW_WP_DB_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)

      # ── Ensure database exists ────────────────────────────────
      $MYSQL_ROOT_CMD -e \
        "CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        2>/dev/null \
        && info "  Database '${WP_DB_NAME}' ensured" \
        || warn "  Could not create database '${WP_DB_NAME}'"

      # ── Rotate MySQL user password (ALTER USER is authoritative) ──
      $MYSQL_ROOT_CMD -e "
        DROP USER IF EXISTS '${WP_DB_USER}'@'localhost';
        CREATE USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${NEW_WP_DB_PASS}';
        GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
      " 2>/dev/null \
        && fixed "  MySQL: ALTER USER '${WP_DB_USER}'@'localhost' — password rotated, privileges granted" \
        || { bad "  Could not update MySQL user '${WP_DB_USER}' — check MySQL logs"; continue; }

      # ── Write new password to the correct location ────────────
      case "$PASS_PATTERN" in

        lightsail_credentials_log)
          # Lightsail reads only the LAST line of credentials.log via `tail -n 1`
          # Append the new password as a new last line — preserves history
          echo "${NEW_WP_DB_PASS}" >> "$CREDENTIALS_LOG" \
            && fixed "  New password appended to $CREDENTIALS_LOG (tail -n 1 will pick it up)" \
            || { bad "  Could not write to $CREDENTIALS_LOG — update manually"; info "  New password: ${NEW_WP_DB_PASS}"; }
          ;;

        standard)
          # Replace define( 'DB_PASSWORD', '...' ) — handles varied spacing
          if sed -i -E "s|define\s*\(\s*'DB_PASSWORD'\s*,\s*'[^']*'\s*\)|define( 'DB_PASSWORD', '${NEW_WP_DB_PASS}' )|g" \
               "$WP_CFG" 2>/dev/null; then
            fixed "  wp-config.php DB_PASSWORD updated ($WP_CFG)"
          else
            bad "  Could not update DB_PASSWORD in $WP_CFG — update manually"
            info "  New password: ${NEW_WP_DB_PASS}"
          fi
          ;;
      esac

      # ── Verify end-to-end connection ──────────────────────────
      if mysql -u "${WP_DB_USER}" -p"${NEW_WP_DB_PASS}" --connect-timeout=3 \
           -e "USE \`${WP_DB_NAME}\`; SELECT 1;" 2>/dev/null | grep -q 1; then
        ok "  WordPress DB connection verified: ${WP_DB_USER} → ${WP_DB_NAME}"
      else
        bad "  WordPress DB user '${WP_DB_USER}' still cannot connect after rotation"
        info "  Debug: mysql -u ${WP_DB_USER} -p'${NEW_WP_DB_PASS}' ${WP_DB_NAME}"
      fi

    done
  fi

else
  info "MySQL/MariaDB not installed — skipping"
fi

# ──────────────────────────────────────────
# 7. WEB SERVER HARDENING
# ──────────────────────────────────────────
section "7. Web Server Hardening"

restart_webserver() {
  local svc="$1"
  if $IS_BITNAMI; then
    /opt/bitnami/ctlscript.sh restart "$svc" &>/dev/null \
      && fixed "$svc restarted (Bitnami)" \
      || warn "$svc restart failed — check manually"
  else
    # Resolve the actual systemd service name — Debian/Ubuntu use apache2, RHEL uses httpd
    local resolved_svc="$svc"
    if [ "$svc" = "apache" ]; then
      if systemctl list-units --type=service 2>/dev/null | grep -q "apache2.service"; then
        resolved_svc="apache2"
      elif systemctl list-units --type=service 2>/dev/null | grep -q "httpd.service"; then
        resolved_svc="httpd"
      fi
    fi
    systemctl restart "$resolved_svc" 2>/dev/null \
      && fixed "$resolved_svc restarted" \
      || warn "$resolved_svc restart failed — check: systemctl status $resolved_svc"
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

  # Validate config before restart
  if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    restart_webserver "apache"
  else
    warn "Apache config has syntax errors — fix manually: sudo apache2ctl configtest"
  fi

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

# Find all wp-config.php files — covers Lightsail Bitnami (/bitnami), standard Bitnami (/opt/bitnami), bare Ubuntu (/var/www), cPanel
WP_CONFIGS=$(find \
  /bitnami \
  /opt/bitnami \
  /var/www \
  /srv \
  /home \
  -name "wp-config.php" \
  -not -path "*/wp-config-sample.php" \
  2>/dev/null || true)

# On Lightsail, wp-config.php is often at /var/www/html/wp-config.php symlinked from /bitnami
# Also check the actual /bitnami/wordpress path directly
if [ -z "$WP_CONFIGS" ]; then
  WP_CONFIGS=$(find /bitnami/wordpress /var/www/html -name "wp-config.php" \
    -not -path "*/wp-config-sample.php" 2>/dev/null || true)
fi

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

    # PHP files in uploads — flag suspicious ones, ignore known plugin data dirs
    UPLOADS="$WP_DIR/wp-content/uploads"
    if [ -d "$UPLOADS" ]; then
      PHP_IN_UPLOADS=$(find "$UPLOADS" -name "*.php" 2>/dev/null \
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
      if [ -n "$PHP_IN_UPLOADS" ]; then
        bad "Suspicious PHP files found in uploads — possible webshells:"
        echo "$PHP_IN_UPLOADS" | sed 's/^/    /'
        warn "Review these manually before deleting"
      else
        ok "No suspicious PHP files in uploads"
      fi
    fi

    # .htaccess — create standard WordPress one if missing
    if [ -f "$WP_DIR/.htaccess" ]; then
      ok ".htaccess present in $WP_DIR"
    else
      warn "No .htaccess in $WP_DIR — creating standard WordPress .htaccess"
      cat > "$WP_DIR/.htaccess" <<'HTACCESS'
# BEGIN WordPress
# The directives (lines) between "BEGIN WordPress" and "END WordPress" are
# dynamically generated, and should only be modified via WordPress filters.
# Any changes to the directives between these markers will be overwritten.
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTACCESS
      chown "$(stat -c '%U:%G' "$WP_DIR/wp-config.php" 2>/dev/null || echo 'www-data:www-data')" "$WP_DIR/.htaccess"
      chmod 644 "$WP_DIR/.htaccess"
      fixed ".htaccess created in $WP_DIR"
    fi

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

# If .ssh exists but is a file (failed previous run), remove it first
if [ -e "$ERIC_SSH_DIR" ] && [ ! -d "$ERIC_SSH_DIR" ]; then
  rm -f "$ERIC_SSH_DIR"
  warn ".ssh existed as a file — removed so it can be recreated as a directory"
fi

if [ ! -d "$ERIC_SSH_DIR" ]; then
  mkdir -p "$ERIC_SSH_DIR"
  fixed "Created $ERIC_SSH_DIR"
fi

# authorized_keys must be a file, not a directory
if [ -d "$ERIC_AUTH_KEYS" ]; then
  rm -rf "$ERIC_AUTH_KEYS"
  warn "authorized_keys existed as a directory — removed"
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

# Unlock account — useradd without a password creates a locked account (shows 'L' in passwd -S)
# Key-based SSH still works with a locked password, but unlock cleanly to avoid confusion
passwd -u "$ERIC_USER" 2>/dev/null || true

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
  EVENT_SYMBOL=">>>"
else
  EVENT="LOGOUT"
  EVENT_SYMBOL="<<<"
fi

SUBJECT="[$HOST] SSH ${EVENT}: ${PAM_USER} from ${PAM_RHOST}"
BODY="${EVENT_SYMBOL} SSH ${EVENT} on ${HOST}

User:      ${PAM_USER}
From IP:   ${PAM_RHOST}
Service:   ${PAM_SERVICE}
Time:      ${DATE}
Server IP: ${IP}"

printf "Subject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s" \
  "${SUBJECT}" "${BODY}" | /usr/bin/msmtp "$ALERT_TO" 2>/dev/null || true
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
    # Ubuntu 24.04+ — try apt first, fall back to pip
    apt-get install -y -qq ansible 2>/dev/null \
      && fixed "Ansible installed via apt" \
      || {
        info "apt install failed — trying pip3 with --break-system-packages..."
        pip3 install ansible --quiet --break-system-packages 2>/dev/null \
          && fixed "Ansible installed via pip3 (--break-system-packages)" \
          || warn "Ansible install failed — try manually: pip3 install ansible --break-system-packages"
      }
  else
    # Ubuntu 22.04 and older — use apt (no externally-managed restriction)
    apt-get install -y -qq ansible 2>/dev/null \
      && fixed "Ansible installed via apt" \
      || {
        info "apt install failed — trying pip3..."
        pip3 install ansible --quiet 2>/dev/null \
          && fixed "Ansible installed via pip3" \
          || warn "Ansible install failed — try manually: pip3 install ansible"
      }
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
# 16. WATCHDOG MONITORING
# ──────────────────────────────────────────
section "16. Watchdog Monitoring"

WATCHDOG_SCRIPT=/opt/scripts/watchdog.sh
WATCHDOG_URL="https://raw.githubusercontent.com/GraywellDesign/playbooks/main/watchdog.sh"

# Download/update watchdog script
if [ -f "$WATCHDOG_SCRIPT" ]; then
  # Update to latest version
  wget -qO "$WATCHDOG_SCRIPT" "$WATCHDOG_URL" 2>/dev/null \
    && ok "Watchdog script updated" \
    || warn "Could not update watchdog script — using existing version"
else
  mkdir -p /opt/scripts
  wget -qO "$WATCHDOG_SCRIPT" "$WATCHDOG_URL" 2>/dev/null \
    && fixed "Watchdog script downloaded" \
    || { warn "Could not download watchdog script — skipping watchdog install"; }
fi

if [ -f "$WATCHDOG_SCRIPT" ]; then
  chmod 700 "$WATCHDOG_SCRIPT"

  # Install systemd service
  cat > /etc/systemd/system/graywell-watchdog.service <<'EOF'
[Unit]
Description=Graywell Server Watchdog
After=network.target mysql.service mariadb.service apache2.service nginx.service

[Service]
Type=oneshot
ExecStart=/opt/scripts/watchdog.sh
Environment=HOME=/root
StandardOutput=null
StandardError=append:/var/log/graywell-watchdog.log
EOF

  # Install systemd timer (every 60 seconds)
  cat > /etc/systemd/system/graywell-watchdog.timer <<'EOF'
[Unit]
Description=Graywell Watchdog Timer — runs every 60 seconds
Requires=graywell-watchdog.service

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
EOF

  # Log rotation
  cat > /etc/logrotate.d/graywell-watchdog <<'EOF'
/var/log/graywell-watchdog.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 root root
}
EOF

  touch /var/log/graywell-watchdog.log
  chmod 640 /var/log/graywell-watchdog.log

  systemctl daemon-reload
  systemctl enable graywell-watchdog.timer &>/dev/null
  systemctl restart graywell-watchdog.timer 2>/dev/null \
    && fixed "Watchdog timer enabled (60s interval)" \
    || warn "Watchdog timer failed to start — check: systemctl status graywell-watchdog.timer"
fi

# ──────────────────────────────────────────
# DONE
# ──────────────────────────────────────────
section "Setup Complete"

echo -e "\n${BOLD}Summary log: $LOG${NC}"
echo -e "Ansible log: /opt/ansible-setup.log\n"

# Only count and show entries from this run (lines added after RUN_START_LINE)
RUN_LOG=$(tail -n "+${RUN_START_LINE}" "$LOG" 2>/dev/null || true)
FIXED_COUNT=$(echo "$RUN_LOG" | grep -c "\[FIXED\]" 2>/dev/null || echo 0)
WARN_COUNT=$(echo "$RUN_LOG"  | grep -c "\[WARN\]"  2>/dev/null || echo 0)
FAIL_COUNT=$(echo "$RUN_LOG"  | grep -c "\[FAIL\]"  2>/dev/null || echo 0)
FIXED_COUNT=$(echo "$FIXED_COUNT" | tr -d '[:space:]')
WARN_COUNT=$(echo "$WARN_COUNT"   | tr -d '[:space:]')
FAIL_COUNT=$(echo "$FAIL_COUNT"   | tr -d '[:space:]')

echo -e "  ${GRN}Fixed:${NC}    $FIXED_COUNT items"
echo -e "  ${YEL}Warnings:${NC} $WARN_COUNT items"
echo -e "  ${RED}Failures:${NC} $FAIL_COUNT items"
echo ""

if [ "${FAIL_COUNT}" -gt 0 ] 2>/dev/null; then
  echo -e "${RED}Items needing manual attention:${NC}"
  echo "$RUN_LOG" | grep "\[FAIL\]" | sed 's/^/  /'
  echo ""
fi

if [ "${WARN_COUNT}" -gt 0 ] 2>/dev/null; then
  echo -e "${YEL}Warnings to review:${NC}"
  echo "$RUN_LOG" | grep "\[WARN\]" | sed 's/^/  /'
  echo ""
fi

echo -e "Completed: $(date)"
log "=== Setup completed on $(hostname) at $(date) ==="

# ── SSH Access Safety Reminder ───────────────────────────────
ALLOW_LINE=$(grep -iE "^AllowUsers\s" /etc/ssh/sshd_config 2>/dev/null || echo "")
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${YEL}⚠  IMPORTANT — Verify SSH access before closing this session:${NC}"
echo ""
echo -e "  AllowUsers: ${BOLD}$(echo "$ALLOW_LINE" | sed 's/AllowUsers //')${NC}"
echo ""
echo "  Open a NEW terminal and test each user before closing this window:"
echo -e "  ${BOLD}ssh esalas@${SERVER_IP}${NC}"
[ -n "$(id ubuntu 2>/dev/null)" ]  && echo -e "  ${BOLD}ssh ubuntu@${SERVER_IP}${NC}"
[ -n "$(id bitnami 2>/dev/null)" ] && echo -e "  ${BOLD}ssh bitnami@${SERVER_IP}${NC}"
echo ""
echo -e "  If locked out: use your cloud provider's browser console to fix."
echo ""