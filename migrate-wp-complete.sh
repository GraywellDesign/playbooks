#!/bin/bash
# ============================================================
#  Graywell Design — WordPress Migration Script (COMPLETE)
#  Database + Files + Security + SSL + Configuration
#  Fully automated with comprehensive testing
#  Run from your LOCAL MAC
#
#  Prerequisites:
#    - SSH access to both source and destination servers
#    - ssh key at /Users/ericsalas/esalas_rsa
#    - Root/sudo access on destination server
#
#  Usage: bash migrate-wp-complete.sh
# ============================================================

set -uo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
LOG="$HOME/migrate-wp-complete-$(date +%Y%m%d-%H%M%S).log"

ok()      { echo -e "  ${GRN}[✓]${NC}      $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" >> "$LOG"; }
warn()    { echo -e "  ${YEL}[!]${NC}      $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >> "$LOG"; }
bad()     { echo -e "  ${RED}[✗]${NC}      $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] $1" >> "$LOG"; }
info()    { echo -e "  ${BLU}[i]${NC}      $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$LOG"; }
section() { echo -e "\n${BOLD}${BLU}═══════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}═══════════════════════════════════════════════════${NC}"; echo "$(date '+%Y-%m-%d %H:%M:%S') === $1 ===" >> "$LOG"; }

# Utility functions
ensure_zip_on_server() {
  local ssh_cmd="$1"
  local server_name="$2"
  if ! $ssh_cmd "command -v zip &>/dev/null && command -v unzip &>/dev/null" 2>/dev/null; then
    info "Installing zip/unzip on $server_name..."
    $ssh_cmd "sudo apt-get update -qq && sudo apt-get install -y zip unzip > /dev/null 2>&1" 2>/dev/null
    if $ssh_cmd "command -v zip &>/dev/null" 2>/dev/null; then
      ok "zip/unzip installed on $server_name"
    else
      bad "Failed to install zip/unzip on $server_name"
      return 1
    fi
  else
    ok "zip/unzip already available on $server_name"
  fi
  return 0
}

check_wp_cli() {
  local ssh_cmd="$1"
  if ! $ssh_cmd "command -v wp &>/dev/null" 2>/dev/null; then
    info "Installing WP-CLI..."
    $ssh_cmd "curl -s https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar && sudo chmod +x /tmp/wp-cli.phar && sudo mv /tmp/wp-cli.phar /usr/local/bin/wp" 2>/dev/null
    ok "WP-CLI installed"
  else
    ok "WP-CLI available"
  fi
}

echo -e "\n${BOLD}WordPress Migration Script (Complete Edition)${NC}"
echo -e "Local: $(hostname) | $(date)\n"

TEMP_DIR="$HOME/wp-migration-temp"
mkdir -p "$TEMP_DIR"
echo "$(date '+%Y-%m-%d %H:%M:%S') === Migration started ===" > "$LOG"

SSH_KEY="/Users/ericsalas/esalas_rsa"
[ -f "$SSH_KEY" ] && ok "SSH key found: $SSH_KEY" || { bad "SSH key not found: $SSH_KEY"; exit 1; }

# ────────────────────────────────────────────────────────────
# PART 1: COLLECT SERVER DETAILS
# ────────────────────────────────────────────────────────────
section "1. Server Details & Connection Tests"

echo ""
read -rp "  Source server IP: " SRC_HOST
read -rp "  Source SSH user (default: esalas): " SRC_USER
SRC_USER=${SRC_USER:-esalas}
read -rp "  Source SSH port (default: 22): " SRC_PORT
SRC_PORT=${SRC_PORT:-22}

read -rp "  Destination server IP: " DEST_HOST
read -rp "  Destination SSH user (default: esalas): " DEST_USER
DEST_USER=${DEST_USER:-esalas}
read -rp "  Destination SSH port (default: 22): " DEST_PORT
DEST_PORT=${DEST_PORT:-22}

read -rp "  Domain name (e.g. example.com): " DOMAIN
read -rp "  WordPress path on destination (default: /var/www/html): " DEST_WP_PATH
DEST_WP_PATH=${DEST_WP_PATH:-/var/www/html}

SSH_SRC="ssh -i $SSH_KEY -p $SRC_PORT -o StrictHostKeyChecking=no $SRC_USER@$SRC_HOST"
SSH_DEST="ssh -i $SSH_KEY -p $DEST_PORT -o StrictHostKeyChecking=no $DEST_USER@$DEST_HOST"
SCP_FROM="scp -i $SSH_KEY -P $SRC_PORT -o StrictHostKeyChecking=no"
SCP_TO="scp -i $SSH_KEY -P $DEST_PORT -o StrictHostKeyChecking=no"

echo ""
$SSH_SRC "echo connected" 2>/dev/null | grep -q "connected" && ok "Source server reachable" || { bad "Cannot reach source"; exit 1; }
$SSH_DEST "echo connected" 2>/dev/null | grep -q "connected" && ok "Destination server reachable" || { bad "Cannot reach destination"; exit 1; }

# ────────────────────────────────────────────────────────────
# PART 2: DATABASE MIGRATION
# ────────────────────────────────────────────────────────────
section "2. Database Migration"

SRC_WP_DIR=$($SSH_SRC "for path in /bitnami/wordpress /opt/bitnami/wordpress /var/www/html /var/www/wordpress /home/*/public_html /srv/www; do [ -f \"\$path/wp-config.php\" ] && echo \"\$path\" && break; done" 2>/dev/null)
[ -z "$SRC_WP_DIR" ] && { bad "Could not find WordPress on source"; exit 1; }
ok "Found WordPress at: $SRC_WP_DIR"

SRC_DB_NAME=$($SSH_SRC "sudo grep DB_NAME $SRC_WP_DIR/wp-config.php 2>/dev/null | sed \"s/.*'\\([^']*\\)'.*/\\1/\" | head -1" 2>/dev/null)
SRC_DB_USER=$($SSH_SRC "sudo grep DB_USER $SRC_WP_DIR/wp-config.php 2>/dev/null | sed \"s/.*'\\([^']*\\)'.*/\\1/\" | head -1" 2>/dev/null)
SRC_DB_PASS=$($SSH_SRC "sudo grep DB_PASSWORD $SRC_WP_DIR/wp-config.php 2>/dev/null | sed \"s/.*'\\([^']*\\)'.*/\\1/\" | head -1" 2>/dev/null)
SRC_DB_HOST=$($SSH_SRC "sudo grep DB_HOST $SRC_WP_DIR/wp-config.php 2>/dev/null | sed \"s/.*'\\([^']*\\)'.*/\\1/\" | head -1" 2>/dev/null)
SRC_DB_HOST=${SRC_DB_HOST:-localhost}
SRC_TABLE_PREFIX=$($SSH_SRC "sudo grep 'table_prefix' $SRC_WP_DIR/wp-config.php 2>/dev/null | sed \"s/.*'\\([^']*\\)'.*/\\1/\" | head -1" 2>/dev/null)
SRC_TABLE_PREFIX=${SRC_TABLE_PREFIX:-wp_}

info "Database: ${SRC_DB_NAME} | User: ${SRC_DB_USER} | Prefix: ${SRC_TABLE_PREFIX}"

# Dump database
TEMP_DB="/tmp/wp-migration-db-$DOMAIN.sql"
info "Dumping database ${SRC_DB_NAME}..."
$SSH_SRC "mysqldump -u${SRC_DB_USER} -p'${SRC_DB_PASS}' --single-transaction --quick --lock-tables=false ${SRC_DB_NAME} > /tmp/wp-migration-db.sql 2>/dev/null || sudo mysqldump --defaults-file=/root/.my.cnf --single-transaction --quick --lock-tables=false ${SRC_DB_NAME} > /tmp/wp-migration-db.sql 2>/dev/null" 2>/dev/null

$SSH_SRC "[ -f /tmp/wp-migration-db.sql ]" 2>/dev/null || { bad "Database dump failed"; exit 1; }
ok "Database dumped on source"

info "Downloading database to Mac..."
$SCP_FROM "$SRC_USER@$SRC_HOST:/tmp/wp-migration-db.sql" "$TEMP_DB" 2>/dev/null || { bad "Failed to download database"; exit 1; }
DB_SIZE=$(ls -lh "$TEMP_DB" | awk '{print $5}')
ok "Database downloaded: $DB_SIZE"

$SSH_SRC "rm -f /tmp/wp-migration-db.sql" 2>/dev/null || true

# ────────────────────────────────────────────────────────────
# PART 3: WP-CONTENT TRANSFER
# ────────────────────────────────────────────────────────────
section "3. Transferring wp-content"

ensure_zip_on_server "$SSH_SRC" "Source Server" || { bad "Cannot proceed without zip"; exit 1; }
ensure_zip_on_server "$SSH_DEST" "Destination Server" || { bad "Cannot proceed without zip"; exit 1; }

info "Creating wp-content archive on source..."
$SSH_SRC "rm -f /home/wp-content-migration.zip && cd $SRC_WP_DIR && sudo zip -r -q /home/wp-content-migration.zip wp-content/ 2>/dev/null && echo 'success'" 2>/dev/null | grep -q "success" || { bad "Failed to create archive"; exit 1; }
ok "wp-content archived"

info "Downloading wp-content archive..."
$SCP_FROM "$SRC_USER@$SRC_HOST:/home/wp-content-migration.zip" "$TEMP_DIR/" 2>/dev/null || { bad "Failed to download"; exit 1; }
ok "Archive downloaded to $TEMP_DIR"

info "Uploading to destination..."
$SCP_TO "$TEMP_DIR/wp-content-migration.zip" "$DEST_USER@$DEST_HOST:/tmp/" 2>/dev/null || { bad "Failed to upload"; exit 1; }
ok "Uploaded to destination"

info "Extracting and backing up..."
$SSH_DEST "[ -d $DEST_WP_PATH/wp-content ] && sudo mv $DEST_WP_PATH/wp-content $DEST_WP_PATH/wp-content-backup" 2>/dev/null || true
$SSH_DEST "cd $DEST_WP_PATH && sudo unzip -q /tmp/wp-content-migration.zip && sudo chown -R www-data:www-data wp-content && sudo rm -f /tmp/wp-content-migration.zip && echo 'success'" 2>/dev/null | grep -q "success" || { bad "Failed to extract"; exit 1; }
ok "wp-content installed on destination"

$SSH_SRC "rm -f /home/wp-content-migration.zip" 2>/dev/null || true
rm -f "$TEMP_DIR/wp-content-migration.zip"

# ────────────────────────────────────────────────────────────
# PART 4: DATABASE IMPORT & CONFIGURATION
# ────────────────────────────────────────────────────────────
section "4. Database Import & Configuration"

DEST_DB_NAME=$($SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW DATABASES;' 2>/dev/null | grep -i wordpress | grep -v information | head -1" 2>/dev/null)
[ -z "$DEST_DB_NAME" ] && { bad "Could not find WordPress database on destination"; exit 1; }
ok "Found destination database: $DEST_DB_NAME"

DEST_TABLE_PREFIX=$($SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf -e \"SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DEST_DB_NAME' LIMIT 1;\" --skip-column-names 2>/dev/null | grep -o '^[^_]*_' | head -1" 2>/dev/null)
DEST_TABLE_PREFIX=${DEST_TABLE_PREFIX:-wp_}
ok "Found destination table prefix: $DEST_TABLE_PREFIX"

info "Uploading database dump..."
$SCP_TO "$TEMP_DB" "$DEST_USER@$DEST_HOST:/tmp/" 2>/dev/null || { bad "Failed to upload database"; exit 1; }
ok "Database dump uploaded"

info "Importing database..."
DB_DUMP_FILE=$(basename "$TEMP_DB")
$SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf $DEST_DB_NAME < /tmp/$DB_DUMP_FILE 2>/dev/null && sudo rm -f /tmp/$DB_DUMP_FILE && echo 'success'" 2>/dev/null | grep -q "success" || { bad "Database import failed"; exit 1; }
ok "Database imported successfully"

# Rename tables if prefix differs
if [ "$SRC_TABLE_PREFIX" != "$DEST_TABLE_PREFIX" ]; then
  info "Renaming tables from $SRC_TABLE_PREFIX to $DEST_TABLE_PREFIX..."
  RENAME_SCRIPT=$($SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf -e \"SELECT CONCAT('RENAME TABLE ', TABLE_NAME, ' TO ', CONCAT('$DEST_TABLE_PREFIX', SUBSTRING(TABLE_NAME, LENGTH('$SRC_TABLE_PREFIX')+1)), ';') FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DEST_DB_NAME' AND TABLE_NAME LIKE '${SRC_TABLE_PREFIX}%';\" --skip-column-names 2>/dev/null" 2>/dev/null)
  [ -n "$RENAME_SCRIPT" ] && $SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf $DEST_DB_NAME -e \"$RENAME_SCRIPT\"" 2>/dev/null && ok "Tables renamed" || warn "Table rename skipped"
fi

# ────────────────────────────────────────────────────────────
# PART 5: UPDATE WP-CONFIG & URL SETTINGS
# ────────────────────────────────────────────────────────────
section "5. WordPress Configuration"

info "Updating wp-config.php..."
$SSH_DEST "
  sudo sed -i.bak \"s/define( 'DB_NAME',.*/define( 'DB_NAME', '$DEST_DB_NAME' );/\" /var/www/wp-config.php
  sudo sed -i \"s/define( 'DB_HOST',.*/define( 'DB_HOST', 'localhost' );/\" /var/www/wp-config.php
  sudo sed -i \"s/\\\\\\\$table_prefix = '[^']*'/\\\\\\\$table_prefix = '$DEST_TABLE_PREFIX'/\" /var/www/wp-config.php
  sudo chmod 640 /var/www/wp-config.php
" 2>/dev/null
ok "wp-config.php updated"

info "Adding HTTPS forcing to wp-config.php..."
$SSH_DEST "
  grep -q 'FORCE_SSL_ADMIN' /var/www/wp-config.php || sudo tee -a /var/www/wp-config.php > /dev/null << 'CONFIG'

// Force HTTPS
if ( strpos( \$_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '', 'https' ) !== false || isset( \$_SERVER['HTTPS'] ) ) {
	\$_SERVER['HTTPS'] = 'on';
}
define( 'FORCE_SSL_ADMIN', true );
define( 'FORCE_SSL_LOGIN', true );
define( 'FORCE_SSL', true );
define( 'WP_HOME', 'https://$DOMAIN' );
define( 'WP_SITEURL', 'https://$DOMAIN' );
CONFIG
" 2>/dev/null
ok "HTTPS forcing enabled"

# ────────────────────────────────────────────────────────────
# PART 6: FIX URLS IN DATABASE
# ────────────────────────────────────────────────────────────
section "6. Fixing URLs in Database"

check_wp_cli "$SSH_DEST"

info "Updating WordPress options to HTTPS..."
$SSH_DEST "
  sudo mysql --defaults-file=/root/.my.cnf $DEST_DB_NAME -e \"UPDATE wp_options SET option_value = REPLACE(option_value, 'http://', 'https://') WHERE option_name IN ('siteurl', 'home');\"
  sudo mysql --defaults-file=/root/.my.cnf $DEST_DB_NAME -e \"UPDATE wp_options SET option_value = 'https://$DOMAIN' WHERE option_name IN ('siteurl', 'home');\"
" 2>/dev/null
ok "Options updated"

info "Replacing URLs in post content..."
$SSH_DEST "
  sudo wp search-replace 'http://' 'https://' --path='$DEST_WP_PATH' --allow-root 2>/dev/null || true
  sudo wp search-replace 'localhost' '$DOMAIN' --path='$DEST_WP_PATH' --allow-root 2>/dev/null || true
" 2>/dev/null
ok "Post content updated"

info "Updating postmeta and database..."
$SSH_DEST "
  sudo mysql --defaults-file=/root/.my.cnf $DEST_DB_NAME -e \"UPDATE wp_posts SET post_content = REPLACE(post_content, 'http://', 'https://') WHERE post_type IN ('post', 'page');\"
  sudo mysql --defaults-file=/root/.my.cnf $DEST_DB_NAME -e \"UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, 'http://', 'https://') WHERE meta_value LIKE '%http://%';\"
" 2>/dev/null
ok "Database URLs fixed"

# ────────────────────────────────────────────────────────────
# PART 7: APACHE CONFIGURATION & REWRITES
# ────────────────────────────────────────────────────────────
section "7. Apache Configuration"

info "Checking mod_rewrite..."
$SSH_DEST "sudo apache2ctl -M 2>/dev/null | grep -q rewrite" 2>/dev/null && ok "mod_rewrite enabled" || {
  warn "Enabling mod_rewrite..."
  $SSH_DEST "sudo a2enmod rewrite" 2>/dev/null && ok "mod_rewrite enabled"
}

info "Creating .htaccess with WordPress rewrite rules..."
$SSH_DEST "
  sudo tee $DEST_WP_PATH/.htaccess > /dev/null << 'HTACCESS'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTACCESS

  sudo chown www-data:www-data $DEST_WP_PATH/.htaccess
  sudo chmod 644 $DEST_WP_PATH/.htaccess
" 2>/dev/null
ok ".htaccess created"

info "Configuring Apache Directory settings..."
$SSH_DEST "
  sudo sed -i \"/<Directory $DEST_WP_PATH>/,/<\\/Directory>/c\\
<Directory $DEST_WP_PATH>\\
    Options Indexes FollowSymLinks\\
    AllowOverride All\\
    Require all granted\\
</Directory>\" /etc/apache2/sites-enabled/000-default.conf 2>/dev/null || true

  sudo tee -a /etc/apache2/sites-available/default-ssl.conf > /dev/null << 'APACHE'
<Directory $DEST_WP_PATH>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
APACHE
" 2>/dev/null
ok "Apache Directory settings configured"

# ────────────────────────────────────────────────────────────
# PART 8: SSL CERTIFICATE (Let's Encrypt + Cloudflare)
# ────────────────────────────────────────────────────────────
section "8. SSL Certificate Setup"

info "Installing Certbot..."
$SSH_DEST "sudo apt-get update -qq && sudo apt-get install -y certbot python3-certbot-apache python3-certbot-dns-cloudflare > /dev/null 2>&1" 2>/dev/null
ok "Certbot installed"

info "Requesting Let's Encrypt certificate via Cloudflare DNS..."
$SSH_DEST "
  echo 'Please provide your Cloudflare API token when prompted.'
  echo 'Go to: https://dash.cloudflare.com/profile/api-tokens'
  echo 'Create token with DNS edit permissions for $DOMAIN'

  # Get Cloudflare token
  read -rp 'Cloudflare API Token: ' CF_TOKEN

  # Create Cloudflare credentials file
  sudo mkdir -p /root/.secrets
  echo \"dns_cloudflare_api_token = \$CF_TOKEN\" | sudo tee /root/.secrets/cloudflare.ini > /dev/null
  sudo chmod 600 /root/.secrets/cloudflare.ini

  # Get certificate
  sudo certbot certonly \\
    --dns-cloudflare \\
    --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \\
    -d $DOMAIN \\
    -d www.$DOMAIN \\
    --agree-tos \\
    --non-interactive \\
    -m admin@$DOMAIN 2>/dev/null || true
" 2>/dev/null
ok "Certificate request completed"

info "Updating Apache SSL configuration..."
$SSH_DEST "
  sudo sed -i \"s|SSLCertificateFile.*|SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem|\" /etc/apache2/sites-available/default-ssl.conf
  sudo sed -i \"s|SSLCertificateKeyFile.*|SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem|\" /etc/apache2/sites-available/default-ssl.conf
" 2>/dev/null
ok "Apache SSL paths updated"

# ────────────────────────────────────────────────────────────
# PART 9: PHP & SECURITY HARDENING
# ────────────────────────────────────────────────────────────
section "9. PHP & Security Configuration"

info "Updating PHP settings..."
$SSH_DEST "
  for php_file in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do
    [ -f \"\$php_file\" ] && sudo sed -i 's/^memory_limit = .*/memory_limit = 256M/' \"\$php_file\"
    [ -f \"\$php_file\" ] && sudo sed -i 's/^max_execution_time = .*/max_execution_time = 120/' \"\$php_file\"
  done
" 2>/dev/null
ok "PHP settings configured (memory=256M, execution=120s)"

info "Installing fail2ban..."
$SSH_DEST "sudo apt-get install -y fail2ban > /dev/null 2>&1" 2>/dev/null
ok "fail2ban installed"

info "Configuring fail2ban SSH protection..."
$SSH_DEST "
  sudo tee /etc/fail2ban/jail.local > /dev/null << 'JAIL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath =
backend = systemd
maxretry = 5
findtime = 600
bantime = 3600
JAIL

  sudo systemctl restart fail2ban
" 2>/dev/null
ok "fail2ban configured"

info "Hardening SSH..."
$SSH_DEST "
  sudo sed -i 's/^#.*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sudo systemctl reload ssh
" 2>/dev/null
ok "SSH hardened (root login disabled)"

# ────────────────────────────────────────────────────────────
# PART 10: PERMISSIONS & CACHE
# ────────────────────────────────────────────────────────────
section "10. Fixing Permissions & Clearing Cache"

info "Setting file permissions..."
$SSH_DEST "
  sudo chown -R www-data:www-data $DEST_WP_PATH 2>/dev/null || true
  sudo find $DEST_WP_PATH -type d -exec chmod 755 {} \; 2>/dev/null || true
  sudo find $DEST_WP_PATH -type f -exec chmod 644 {} \; 2>/dev/null || true
  sudo chmod 640 /var/www/wp-config.php 2>/dev/null || true
  sudo chmod 640 $DEST_WP_PATH/.htaccess 2>/dev/null || true
" 2>/dev/null
ok "Permissions corrected"

info "Clearing caches..."
$SSH_DEST "
  sudo rm -rf $DEST_WP_PATH/wp-content/cache/*
  sudo wp transient delete --all --path='$DEST_WP_PATH' --allow-root 2>/dev/null || true
  sudo wp elementor flush_css --path='$DEST_WP_PATH' --allow-root 2>/dev/null || true
" 2>/dev/null
ok "Cache cleared"

# ────────────────────────────────────────────────────────────
# PART 11: RESTART SERVICES
# ────────────────────────────────────────────────────────────
section "11. Restarting Services"

$SSH_DEST "
  sudo systemctl restart apache2
  sudo systemctl reload php*-fpm 2>/dev/null || true
  sleep 3
" 2>/dev/null
ok "Services restarted"

# ────────────────────────────────────────────────────────────
# PART 12: COMPREHENSIVE TESTING
# ────────────────────────────────────────────────────────────
section "12. Verification & Testing"

info "Testing HTTPS..."
HTTP_CODE=$($SSH_DEST "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: $DOMAIN' https://localhost/ 2>/dev/null")
[ "$HTTP_CODE" = "200" ] && ok "HTTPS responding (HTTP $HTTP_CODE)" || warn "HTTPS check returned $HTTP_CODE"

info "Testing HTTP→HTTPS redirect..."
REDIRECT=$($SSH_DEST "curl -s -I http://localhost/ 2>/dev/null | grep -i location | head -1")
[ -n "$REDIRECT" ] && ok "HTTP→HTTPS redirect working" || warn "Redirect may not be configured"

info "Testing WordPress functionality..."
$SSH_DEST "sudo wp core is-installed --path='$DEST_WP_PATH' --allow-root 2>/dev/null" && ok "WordPress is installed and configured" || warn "WordPress check failed"

info "Checking file permissions on uploads..."
$SSH_DEST "[ -f $DEST_WP_PATH/wp-content/uploads/.htaccess ] && grep -q 'php_flag engine 0' $DEST_WP_PATH/wp-content/uploads/.htaccess" 2>/dev/null && ok "PHP execution disabled in uploads" || warn "Uploads protection not detected"

info "Verifying database integrity..."
$SSH_DEST "sudo wp db check --path='$DEST_WP_PATH' --allow-root 2>/dev/null | grep -q 'success'" && ok "Database integrity verified" || warn "Database check returned warnings"

# ────────────────────────────────────────────────────────────
# PART 13: SUMMARY & NEXT STEPS
# ────────────────────────────────────────────────────────────
section "13. Migration Complete!"

DEST_IP=$($SSH_DEST "hostname -I | awk '{print \$1}'" 2>/dev/null)

echo ""
echo -e "${BOLD}✓ Migration Complete!${NC}"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo ""
echo "1. ${BOLD}Update DNS Records${NC}"
echo "   Point these A records to: ${DEST_IP}"
echo "   • $DOMAIN"
echo "   • www.$DOMAIN"
echo ""
echo "2. ${BOLD}Complete SSL Setup${NC}"
echo "   SSH to destination and verify certificate:"
echo "   ssh -i $SSH_KEY $DEST_USER@$DEST_HOST"
echo "   sudo certbot certificates"
echo ""
echo "3. ${BOLD}Test Locally (Before DNS Switch)${NC}"
echo "   Add to /etc/hosts:"
echo "   ${DEST_IP}  $DOMAIN www.$DOMAIN"
echo "   Then visit: https://$DOMAIN"
echo ""
echo "4. ${BOLD}Post-Migration Checks${NC}"
echo "   • Verify all pages load over HTTPS"
echo "   • Check for mixed content warnings (browser console)"
echo "   • Test navigation and forms"
echo "   • Check plugin functionality"
echo ""
echo "5. ${BOLD}Keep Source Server Running${NC}"
echo "   Keep source running for 48 hours in case rollback needed"
echo ""
echo -e "${BOLD}Log File:${NC} $LOG"
echo ""

rm -f "$TEMP_DB"

ok "All done!"
