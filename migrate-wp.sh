#!/bin/bash
# ============================================================
#  Graywell Design — WordPress Migration Script
#  Pulls WordPress files + database from source server
#  Run on the DESTINATION (new) server
#
#  Prerequisites on destination:
#    - sudo bash setup.sh already run
#    - SSH key access to source server
#    - MySQL running with root credentials in /root/.my.cnf
#
#  Usage: sudo bash migrate-wp.sh
#  Log:   /opt/migrate-wp.log
# ============================================================

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
LOG=/opt/migrate-wp.log

ok()      { echo -e "  ${GRN}[OK]${NC}      $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" >> "$LOG"; }
warn()    { echo -e "  ${YEL}[WARN]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >> "$LOG"; }
bad()     { echo -e "  ${RED}[FAIL]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] $1" >> "$LOG"; }
info()    { echo -e "  ${BLU}[INFO]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$LOG"; }
fixed()   { echo -e "  ${GRN}[DONE]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [DONE] $1" >> "$LOG"; }
section() { echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo "$(date '+%Y-%m-%d %H:%M:%S') === $1 ===" >> "$LOG"; }

[ "$EUID" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

# ──────────────────────────────────────────
# INSTALL SSH KEY FOR MIGRATION
# ──────────────────────────────────────────
ERIC_MIGRATION_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA8e9ivGIdG7os4/5KB7IR0gwSZUfpgwqGImlhjyF1R3gID3VXRhM3KZYW1Rp6M0TzTGb98mkA4M8Uj7BWkp4yUKvVGbQpO+AWzGGsiTCTEH5E1Ne5QaAzxuv6ZuwnqY2ga6peia/OtdJiACUN5MXxem04eLnmLINr59FIPNB/KfLJ8Z9r8tSevn1Jd/emMMTXqaxEry4ltrdsSWcNaWO5ecVdqceIgoGovJxx0iivkqwKtrHF4gKO44y1O3oGE4fnEH6oicVCBXMB3eeqObvSIY7/haOWFJiqmKBOoUXPOumZJHNhuQumtO17mMscUe8sLoQuWswlJd5lg7Vs0bGl+Q== esalas-migration"

# Ensure root has a keypair for outbound SSH
if [ ! -f /root/.ssh/id_rsa ] && [ ! -f /root/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
  echo "Generated new SSH keypair at /root/.ssh/id_ed25519"
fi

# Install the migration public key into root's authorized_keys
# (allows the script to also be used in reverse if needed)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if ! grep -qF "esalas-migration" /root/.ssh/authorized_keys 2>/dev/null; then
  echo "$ERIC_MIGRATION_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# Determine which private key to use for outbound connections
SSH_KEY=""
for key in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /home/esalas/.ssh/id_ed25519 /home/esalas/.ssh/id_rsa; do
  [ -f "$key" ] && { SSH_KEY="$key"; break; }
done

echo -e "\n${BOLD}Graywell WordPress Migration Script${NC}"
echo -e "Destination: $(hostname) | $(date)\n"
echo "$(date '+%Y-%m-%d %H:%M:%S') === Migration started on $(hostname) ===" >> "$LOG"

# Verify MySQL is available on destination
if ! command -v mysql &>/dev/null; then
  bad "MySQL client not found on destination server"
  echo "  Install with: sudo apt install mysql-client -y"
  exit 1
fi

# Test MySQL connection
if ! mysql --defaults-file=/root/.my.cnf --connect-timeout=5 -e "SELECT 1;" &>/dev/null; then
  bad "Cannot connect to MySQL on destination — verify /root/.my.cnf exists and is configured"
  exit 1
fi
ok "MySQL is available and configured"

if [ -n "$SSH_KEY" ]; then
  echo -e "  ${BLU}[INFO]${NC}    Using SSH key: $SSH_KEY"
else
  echo -e "  ${YEL}[WARN]${NC}    No SSH private key found — you will need to specify one"
fi

# ──────────────────────────────────────────
# DETECT DESTINATION ENVIRONMENT
# ──────────────────────────────────────────
IS_BITNAMI_DEST=false
{ [ -d /opt/bitnami ] || [ -d /bitnami ]; } && IS_BITNAMI_DEST=true

DEST_WEB_ROOT=""
for path in \
  /bitnami/wordpress \
  /opt/bitnami/wordpress \
  /var/www/html \
  /var/www/wordpress; do
  [ -d "$path" ] && { DEST_WEB_ROOT="$path"; break; }
done

# Default to /var/www/html if nothing found
[ -z "$DEST_WEB_ROOT" ] && DEST_WEB_ROOT="/var/www/html"
info "Destination web root: $DEST_WEB_ROOT"

# ──────────────────────────────────────────
# COLLECT SOURCE SERVER DETAILS
# ──────────────────────────────────────────
section "Source Server Details"

echo ""
read -rp "  Source server IP or hostname: " SRC_HOST
read -rp "  SSH user on source server (e.g. bitnami, root, esalas): " SRC_USER
read -rp "  SSH port (default 22): " SRC_PORT
SRC_PORT=${SRC_PORT:-22}

# Get SSH key path from user, with auto-detection fallback
read -rp "  Path to SSH private key (on this server, default: ${SSH_KEY:-/root/.ssh/id_rsa}): " SRC_KEY_INPUT

if [ -n "$SRC_KEY_INPUT" ]; then
  # If user provided a path, verify it exists on destination
  if [ ! -f "$SRC_KEY_INPUT" ]; then
    bad "SSH key not found: $SRC_KEY_INPUT"
    echo "  Copy your key to the destination server first:"
    echo "    scp -P $SRC_PORT /Users/ericsalas/esalas_rsa ${SRC_USER}@${SRC_HOST}:/tmp/"
    exit 1
  fi
  SRC_KEY="$SRC_KEY_INPUT"
else
  # Fall back to auto-detected keys
  SRC_KEY=${SSH_KEY:-$(ls /root/.ssh/id_* 2>/dev/null | grep -v "\.pub" | head -1)}
  if [ -z "$SRC_KEY" ]; then
    bad "No SSH key found on destination server"
    echo "  Copy your SSH key first, then re-run this script"
    exit 1
  fi
fi

echo ""
read -rp "  Domain name for this site (e.g. example.com): " DOMAIN
read -rp "  New server IP (this server): " DEST_IP

# SSH command shorthand
SSH="ssh -i $SRC_KEY -p $SRC_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SCP="scp -i $SRC_KEY -P $SRC_PORT -o StrictHostKeyChecking=no"
RSYNC="rsync -avz -e \"ssh -i $SRC_KEY -p $SRC_PORT -o StrictHostKeyChecking=no\""

# ──────────────────────────────────────────
# 1. TEST SSH CONNECTION
# ──────────────────────────────────────────
section "1. Testing SSH Connection to Source"

if eval "$SSH '${SRC_USER}@${SRC_HOST}' 'echo connected'" 2>/dev/null | grep -q "connected"; then
  ok "SSH connection to ${SRC_USER}@${SRC_HOST} successful"
else
  bad "Cannot SSH to ${SRC_USER}@${SRC_HOST} — check credentials and try again"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Make sure your SSH key is added: ssh-copy-id -i $SRC_KEY ${SRC_USER}@${SRC_HOST}"
  echo "  2. Test manually: ssh -i $SRC_KEY -p $SRC_PORT ${SRC_USER}@${SRC_HOST}"
  exit 1
fi

# ──────────────────────────────────────────
# 2. DETECT SOURCE WORDPRESS INSTALL
# ──────────────────────────────────────────
section "2. Detecting WordPress on Source Server"

# Find wp-config.php on source — check all known paths
SRC_WP_DIR=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' '
  for path in /bitnami/wordpress /opt/bitnami/wordpress /var/www/html /var/www/wordpress /home/*/public_html /srv/www; do
    if [ -f \"\$path/wp-config.php\" ]; then
      echo \"\$path\"
      break
    fi
  done
  # Fallback: search
  find /var/www /opt/bitnami /bitnami /home /srv -name \"wp-config.php\" \
    -not -path \"*/wp-config-sample.php\" 2>/dev/null | head -1 | xargs dirname 2>/dev/null
'" 2>/dev/null | head -1)

if [ -z "$SRC_WP_DIR" ]; then
  bad "Could not find WordPress on source server"
  echo "  Try running manually on source: find / -name 'wp-config.php' 2>/dev/null"
  exit 1
fi

ok "Found WordPress at: $SRC_WP_DIR"

# Get database credentials from source wp-config.php using grep
SRC_DB_NAME=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' 'grep -oP \"define\s*\(\s*['\\\"]DB_NAME['\\\"]\s*,\s*['\\\"]\\K[^'\\\"]+\" ${SRC_WP_DIR}/wp-config.php | head -1'" 2>/dev/null)
SRC_DB_USER=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' 'grep -oP \"define\s*\(\s*['\\\"]DB_USER['\\\"]\s*,\s*['\\\"]\\K[^'\\\"]+\" ${SRC_WP_DIR}/wp-config.php | head -1'" 2>/dev/null)
SRC_DB_PASS=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' 'grep -oP \"define\s*\(\s*['\\\"]DB_PASSWORD['\\\"]\s*,\s*['\\\"]\\K[^'\\\"]+\" ${SRC_WP_DIR}/wp-config.php | head -1'" 2>/dev/null)
SRC_DB_HOST=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' 'grep -oP \"define\s*\(\s*['\\\"]DB_HOST['\\\"]\s*,\s*['\\\"]\\K[^'\\\"]+\" ${SRC_WP_DIR}/wp-config.php | head -1'" 2>/dev/null)
SRC_DB_HOST=${SRC_DB_HOST:-localhost}

# Try to get site URL from wp-config (if defined as constant)
SRC_SITE_URL=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' 'grep -oP \"define\s*\(\s*['\\\"]WP_HOME['\\\"]\s*,\s*['\\\"]\\K[^'\\\"]+|define\s*\(\s*['\\\"]WP_SITEURL['\\\"]\s*,\s*['\\\"]\\K[^'\\\"]+\" ${SRC_WP_DIR}/wp-config.php | head -1'" 2>/dev/null)

# If not found in wp-config, try to query database (may fail if user doesn't have access, which is OK)
if [ -z "$SRC_SITE_URL" ]; then
  SRC_SITE_URL=$(eval "$SSH '${SRC_USER}@${SRC_HOST}' '
    mysql -u${SRC_DB_USER} -p'\''${SRC_DB_PASS}'\'' ${SRC_DB_NAME} \
      -e \"SELECT option_value FROM wp_options WHERE option_name='\''siteurl'\'' LIMIT 1;\" \
      --skip-column-names 2>/dev/null || \
    sudo mysql --defaults-file=/root/.my.cnf ${SRC_DB_NAME} \
      -e \"SELECT option_value FROM wp_options WHERE option_name='\''siteurl'\'' LIMIT 1;\" \
      --skip-column-names 2>/dev/null
  '" 2>/dev/null | tr -d '\r')
fi

info "Source DB: ${SRC_DB_NAME} | User: ${SRC_DB_USER} | Host: ${SRC_DB_HOST}"
info "Source site URL: ${SRC_SITE_URL:-unknown}"

# ──────────────────────────────────────────
# 3. CONFIRM BEFORE PROCEEDING
# ──────────────────────────────────────────
section "3. Migration Plan"

echo ""
echo -e "  ${BOLD}Source:${NC}      ${SRC_USER}@${SRC_HOST}:${SRC_WP_DIR}"
echo -e "  ${BOLD}Destination:${NC} $(hostname):${DEST_WEB_ROOT}"
echo -e "  ${BOLD}Database:${NC}    ${SRC_DB_NAME}"
echo -e "  ${BOLD}Site URL:${NC}    ${SRC_SITE_URL:-unknown}"
echo -e "  ${BOLD}Domain:${NC}      ${DOMAIN}"
echo ""
echo -e "${YEL}Ready to migrate. This will overwrite files in ${DEST_WEB_ROOT}. Continue? [y/N]${NC} "
read -r CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ──────────────────────────────────────────
# 4. DUMP DATABASE ON SOURCE
# ──────────────────────────────────────────
section "4. Exporting Database from Source"

info "Dumping database ${SRC_DB_NAME} on source server..."

# Try with wp-config credentials first, fall back to root .my.cnf
eval "$SSH '${SRC_USER}@${SRC_HOST}' '
  if mysqldump -u${SRC_DB_USER} -p'\''${SRC_DB_PASS}'\'' \
    --single-transaction --quick --lock-tables=false \
    ${SRC_DB_NAME} > /tmp/wp-migration-db.sql 2>/dev/null; then
    echo \"dumped_with_wp_user\"
  elif sudo mysqldump --defaults-file=/root/.my.cnf \
    --single-transaction --quick --lock-tables=false \
    ${SRC_DB_NAME} > /tmp/wp-migration-db.sql 2>/dev/null; then
    echo \"dumped_with_root\"
  else
    echo \"dump_failed\"
  fi
'" 2>/dev/null | grep -q "dump_failed" && {
  bad "Database dump failed on source server"
  exit 1
}

# Transfer the dump to this server (use eval for SCP command expansion)
eval "$SCP '${SRC_USER}@${SRC_HOST}:/tmp/wp-migration-db.sql' '/tmp/wp-migration-db.sql'" 2>/dev/null \
  && fixed "Database exported and transferred" \
  || { bad "Failed to transfer database dump"; exit 1; }

# Clean up source temp file
eval "$SSH '${SRC_USER}@${SRC_HOST}' 'rm -f /tmp/wp-migration-db.sql'" 2>/dev/null || true

DB_SIZE=$(wc -c < /tmp/wp-migration-db.sql | awk '{printf "%.1fMB", $1/1024/1024}')
info "Database dump size: $DB_SIZE"

# ──────────────────────────────────────────
# 5. SYNC WORDPRESS FILES
# ──────────────────────────────────────────
section "5. Syncing WordPress Files"

# Create destination directory
mkdir -p "$DEST_WEB_ROOT"

info "Syncing files from ${SRC_HOST}:${SRC_WP_DIR}/ to ${DEST_WEB_ROOT}/"
info "This may take a while depending on site size..."

rsync -avz --progress \
  -e "ssh -i $SRC_KEY -p $SRC_PORT -o StrictHostKeyChecking=no" \
  --exclude="*.log" \
  --exclude=".git" \
  --exclude="wp-content/cache/*" \
  --exclude="wp-content/uploads/cache/*" \
  "${SRC_USER}@${SRC_HOST}:${SRC_WP_DIR}/" \
  "${DEST_WEB_ROOT}/" \
  2>&1 | tee -a "$LOG" | tail -5

fixed "WordPress files synced"

# ──────────────────────────────────────────
# 6. CREATE DATABASE ON DESTINATION
# ──────────────────────────────────────────
section "6. Setting Up Database on Destination"

# Read destination MySQL root password
DEST_DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#$%' | head -c 20)
DEST_DB_NAME="$SRC_DB_NAME"
DEST_DB_USER="$SRC_DB_USER"

# Create database and user
mysql --defaults-file=/root/.my.cnf --connect-timeout=5 <<EOF 2>/dev/null
CREATE DATABASE IF NOT EXISTS \`${DEST_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DEST_DB_USER}'@'localhost' IDENTIFIED BY '${DEST_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DEST_DB_NAME}\`.* TO '${DEST_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

fixed "Database ${DEST_DB_NAME} created with user ${DEST_DB_USER}"

# ──────────────────────────────────────────
# 7. IMPORT DATABASE
# ──────────────────────────────────────────
section "7. Importing Database"

info "Importing database..."
mysql --defaults-file=/root/.my.cnf "$DEST_DB_NAME" < /tmp/wp-migration-db.sql 2>/dev/null \
  && fixed "Database imported successfully" \
  || { bad "Database import failed — check /tmp/wp-migration-db.sql"; exit 1; }

rm -f /tmp/wp-migration-db.sql

# ──────────────────────────────────────────
# 8. UPDATE WP-CONFIG.PHP
# ──────────────────────────────────────────
section "8. Updating wp-config.php"

WP_CONFIG="${DEST_WEB_ROOT}/wp-config.php"

if [ -f "$WP_CONFIG" ]; then
  # Update database credentials using sed with proper escaping
  # Escape special characters in credentials for sed
  ESCAPED_DB_PASS=$(printf '%s\n' "$DEST_DB_PASS" | sed -e 's/[\/&]/\\&/g')

  sed -i.bak "s/define( 'DB_NAME',.*/define( 'DB_NAME', '${DEST_DB_NAME}' );/" "$WP_CONFIG"
  sed -i.bak "s/define( 'DB_USER',.*/define( 'DB_USER', '${DEST_DB_USER}' );/" "$WP_CONFIG"
  sed -i.bak "s/define( 'DB_PASSWORD',.*/define( 'DB_PASSWORD', '${ESCAPED_DB_PASS}' );/" "$WP_CONFIG"
  sed -i.bak "s/define( 'DB_HOST',.*/define( 'DB_HOST', 'localhost' );/" "$WP_CONFIG"

  # Remove backup file
  rm -f "${WP_CONFIG}.bak"

  # Set secure permissions
  chmod 640 "$WP_CONFIG"
  fixed "wp-config.php updated with new database credentials"
else
  bad "wp-config.php not found at $WP_CONFIG"
  exit 1
fi

# Save credentials for reference
cat > /root/wp-migration-credentials.txt <<EOF
WordPress Migration Credentials
Generated: $(date)
================================
Database Name:     ${DEST_DB_NAME}
Database User:     ${DEST_DB_USER}
Database Password: ${DEST_DB_PASS}
Domain:            ${DOMAIN}
Source Server:     ${SRC_HOST}
================================
KEEP THIS FILE SECURE — delete after confirming migration
EOF
chmod 600 /root/wp-migration-credentials.txt
info "Credentials saved to /root/wp-migration-credentials.txt"

# ──────────────────────────────────────────
# 9. SEARCH & REPLACE URLS IN DATABASE
# ──────────────────────────────────────────
section "9. Updating URLs in Database"

# Install wp-cli if not present
if ! command -v wp &>/dev/null; then
  info "Installing WP-CLI..."
  if curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>/dev/null; then
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    ok "WP-CLI installed"
  else
    warn "Could not download WP-CLI — will skip search-replace"
  fi
fi

# Detect web server user (check which user actually owns the destination)
WEB_USER="www-data"
if $IS_BITNAMI_DEST; then
  WEB_USER="daemon"
elif [ -d "$DEST_WEB_ROOT" ]; then
  WEB_USER=$(stat -c '%U' "$DEST_WEB_ROOT" 2>/dev/null || echo "www-data")
fi
id "$WEB_USER" &>/dev/null || WEB_USER="www-data"

# Determine old URL — use source site URL or IP
OLD_URL="${SRC_SITE_URL:-http://${SRC_HOST}}"
NEW_URL="https://${DOMAIN}"
NEW_URL_HTTP="http://${DOMAIN}"

if command -v wp &>/dev/null; then
  if [ -n "$SRC_SITE_URL" ] && [ "$SRC_SITE_URL" != "https://${DOMAIN}" ]; then
    info "Search-replacing: ${OLD_URL} → ${NEW_URL}"

    # Run wp search-replace as web user
    if sudo -u "$WEB_USER" wp search-replace \
      "$OLD_URL" "$NEW_URL" \
      --path="$DEST_WEB_ROOT" \
      --all-tables \
      --allow-root \
      2>/dev/null; then
      fixed "URLs updated: ${OLD_URL} → ${NEW_URL}"
    else
      warn "WP-CLI search-replace failed — update URLs manually in WP admin"
    fi

    # Also replace http source URL if different
    if [[ "$OLD_URL" != *"http://"* ]] && [ -n "$SRC_HOST" ]; then
      sudo -u "$WEB_USER" wp search-replace \
        "http://${SRC_HOST}" "$NEW_URL_HTTP" \
        --path="$DEST_WEB_ROOT" \
        --all-tables \
        --allow-root \
        2>/dev/null || true
    fi
  else
    info "URLs already match destination — skipping search-replace"
  fi
else
  warn "WP-CLI not installed — will skip URL updates. Install with: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"
fi

# ──────────────────────────────────────────
# 10. FIX FILE PERMISSIONS
# ──────────────────────────────────────────
section "10. Fixing File Permissions"

# Set ownership to web server user
chown -R "${WEB_USER}:${WEB_USER}" "$DEST_WEB_ROOT" 2>/dev/null
fixed "Ownership set to ${WEB_USER}"

# WordPress recommended permissions
find "$DEST_WEB_ROOT" -type d -exec chmod 755 {} \; 2>/dev/null
find "$DEST_WEB_ROOT" -type f -exec chmod 644 {} \; 2>/dev/null
chmod 640 "$WP_CONFIG"
fixed "File permissions set (dirs: 755, files: 644, wp-config: 640)"

# ──────────────────────────────────────────
# 11. RESTART SERVICES
# ──────────────────────────────────────────
section "11. Restarting Services"

if $IS_BITNAMI_DEST; then
  /opt/bitnami/ctlscript.sh restart apache  >> "$LOG" 2>&1 && ok "Apache restarted" || warn "Apache restart failed"
  /opt/bitnami/ctlscript.sh restart php-fpm >> "$LOG" 2>&1 && ok "PHP-FPM restarted" || warn "PHP-FPM restart failed"
else
  systemctl restart apache2 2>/dev/null && ok "Apache restarted" \
    || systemctl restart nginx 2>/dev/null && ok "Nginx restarted" \
    || warn "Web server restart failed — restart manually"
  PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
  [ -n "$PHP_VER" ] && systemctl restart "php${PHP_VER}-fpm" 2>/dev/null && ok "PHP-FPM restarted" || true
fi

# ──────────────────────────────────────────
# 12. VERIFY SITE IS WORKING
# ──────────────────────────────────────────
section "12. Verification"

sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Host: ${DOMAIN}" http://localhost/ 2>/dev/null)

if [ "${HTTP_CODE:-000}" != "000" ] && [ "${HTTP_CODE:-000}" != "500" ]; then
  ok "Site responding on new server (HTTP ${HTTP_CODE})"
else
  warn "Site not responding via localhost (HTTP ${HTTP_CODE:-no response})"
  warn "Check web server logs: sudo tail -50 /var/log/apache2/error.log"
fi

# Test database connection
DB_TEST=$(sudo -u "$WEB_USER" wp db check \
  --path="$DEST_WEB_ROOT" \
  --allow-root 2>/dev/null | head -1)
[ -n "$DB_TEST" ] && ok "Database connection: $DB_TEST" || warn "WP-CLI db check failed — verify manually"

# ──────────────────────────────────────────
# 13. SSL SETUP ON DESTINATION
# ──────────────────────────────────────────
section "13. SSL Certificate"

info "SSL needs to be configured on the new server after DNS cutover"
echo ""

if $IS_BITNAMI_DEST; then
  info "For Bitnami, run after DNS is pointed:"
  echo -e "  ${BOLD}sudo /opt/bitnami/bncert-tool${NC}"
  echo "  Enter domain: ${DOMAIN}"
elif command -v certbot &>/dev/null; then
  info "For bare Ubuntu with certbot, run after DNS is pointed:"
  echo -e "  ${BOLD}sudo certbot --apache -d ${DOMAIN} -d www.${DOMAIN}${NC}"
else
  info "Install certbot after DNS cutover:"
  echo -e "  ${BOLD}sudo apt install certbot python3-certbot-apache -y${NC}"
  echo -e "  ${BOLD}sudo certbot --apache -d ${DOMAIN} -d www.${DOMAIN}${NC}"
fi

# ──────────────────────────────────────────
# 14. PRE-CUTOVER CHECKLIST
# ──────────────────────────────────────────
section "14. Pre-Cutover Checklist"

echo ""
echo -e "${BOLD}Before switching DNS, verify on this server:${NC}"
echo ""
echo "  1. Test the site via hosts file — add this to your local /etc/hosts:"
echo -e "     ${BOLD}${DEST_IP}  ${DOMAIN} www.${DOMAIN}${NC}"
echo ""
echo "  2. Browse to https://${DOMAIN} and verify:"
echo "     - Site loads correctly"
echo "     - Images and media are present"
echo "     - Admin login works: https://${DOMAIN}/wp-admin"
echo "     - No mixed content warnings"
echo ""
echo "  3. When ready, update DNS:"
echo -e "     ${BOLD}A record: ${DOMAIN} → ${DEST_IP}${NC}"
echo -e "     ${BOLD}A record: www.${DOMAIN} → ${DEST_IP}${NC}"
echo ""
echo "  4. After DNS propagates, run SSL setup (see section 13 above)"
echo ""
echo "  5. Remove the hosts file entry from your local machine"
echo ""
echo -e "${BOLD}Keep source server running for at least 48 hours after DNS cutover${NC}"
echo -e "in case you need to roll back.\n"

echo ""
echo -e "${GRN}${BOLD}Migration complete!${NC}"
echo -e "Log: ${BOLD}$LOG${NC}"
echo -e "Credentials: ${BOLD}/root/wp-migration-credentials.txt${NC}"
echo "$(date '+%Y-%m-%d %H:%M:%S') === Migration completed on $(hostname) ===" >> "$LOG"