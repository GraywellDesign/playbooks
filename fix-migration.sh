#!/bin/bash
# ============================================================
#  Fix WordPress Migration Issues
#  - Rename table prefixes
#  - Re-sync wp-content
#  - Update wp-config.php
# ============================================================

set -uo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()      { echo -e "  ${GRN}[OK]${NC}      $1"; }
warn()    { echo -e "  ${YEL}[WARN]${NC}    $1"; }
bad()     { echo -e "  ${RED}[FAIL]${NC}    $1"; }
info()    { echo -e "  ${BLU}[INFO]${NC}    $1"; }
fixed()   { echo -e "  ${GRN}[DONE]${NC}    $1"; }
section() { echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; }

SSH_KEY="/Users/ericsalas/esalas_rsa"
SRC_HOST="157.230.226.196"
SRC_USER="esalas"
DEST_HOST="13.216.20.121"
DEST_USER="esalas"
DEST_WP_PATH="/var/www/html"
DEST_DB="wordpress-db"

SSH_SRC="ssh -i $SSH_KEY -p 22 -o StrictHostKeyChecking=no $SRC_USER@$SRC_HOST"
SSH_DEST="ssh -i $SSH_KEY -p 22 -o StrictHostKeyChecking=no $DEST_USER@$DEST_HOST"
SCP_FROM="scp -i $SSH_KEY -P 22 -o StrictHostKeyChecking=no"
SCP_TO="scp -i $SSH_KEY -P 22 -o StrictHostKeyChecking=no"

echo -e "\n${BOLD}WordPress Migration Fix${NC}\n"

# ──────────────────────────────────────────
# 1. DETECT SOURCE TABLE PREFIX
# ──────────────────────────────────────────
section "1. Detecting Source Table Prefix"

SRC_PREFIX=$($SSH_SRC "sudo mysql -e \"SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='wordpress' LIMIT 1;\" --skip-column-names | grep -o '^[^_]*_wp_' | head -1" 2>/dev/null)

if [ -z "$SRC_PREFIX" ]; then
  SRC_PREFIX="wp_"
  info "Using default prefix: wp_"
else
  ok "Found source prefix: $SRC_PREFIX"
fi

# ──────────────────────────────────────────
# 2. RENAME TABLES ON DESTINATION
# ──────────────────────────────────────────
section "2. Renaming Database Tables"

if [ "$SRC_PREFIX" != "wp_" ]; then
  info "Source prefix differs from destination. Renaming tables..."

  # Get list of all tables with the source prefix
  TABLES=$($SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf -e \"SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DEST_DB' AND TABLE_NAME LIKE '${SRC_PREFIX}%';\" --skip-column-names" 2>/dev/null)

  if [ -n "$TABLES" ]; then
    # Create SQL to rename all tables
    RENAME_SQL=""
    while IFS= read -r table; do
      NEW_TABLE="${table//$SRC_PREFIX/wp_}"
      RENAME_SQL="$RENAME_SQL RENAME TABLE \`$table\` TO \`$NEW_TABLE\`;"
    done <<< "$TABLES"

    $SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf $DEST_DB -e \"$RENAME_SQL\"" 2>/dev/null && {
      fixed "All tables renamed from $SRC_PREFIX to wp_"
    } || {
      warn "Table rename had issues, continuing anyway"
    }
  fi
else
  ok "Prefixes match (wp_), no rename needed"
fi

# ──────────────────────────────────────────
# 3. TRANSFER WP-CONTENT DIRECTLY
# ──────────────────────────────────────────
section "3. Transferring wp-content"

info "Downloading wp-content from source..."
mkdir -p /tmp/wp-content-sync

# Use rsync through SSH for reliable transfer
$SSH_SRC "cd /var/www/html && tar czf - wp-content/" 2>/dev/null | tar xzf - -C /tmp/wp-content-sync/

if [ -d "/tmp/wp-content-sync/wp-content" ]; then
  WP_CONTENT_SIZE=$(du -sh /tmp/wp-content-sync/wp-content | awk '{print $1}')
  fixed "wp-content downloaded ($WP_CONTENT_SIZE)"

  info "Uploading wp-content to destination..."
  # Upload the directory
  $SCP_TO -r /tmp/wp-content-sync/wp-content/* "$DEST_USER@$DEST_HOST:/tmp/wp-content-upload/" 2>/dev/null

  # Move to proper location on destination
  $SSH_DEST "
    sudo rm -rf $DEST_WP_PATH/wp-content
    sudo cp -r /tmp/wp-content-upload $DEST_WP_PATH/wp-content
    sudo rm -rf /tmp/wp-content-upload
  " 2>/dev/null

  fixed "wp-content installed on destination"

  # Cleanup
  rm -rf /tmp/wp-content-sync
else
  bad "Failed to download wp-content from source"
fi

# ──────────────────────────────────────────
# 4. UPDATE WP-CONFIG PREFIX
# ──────────────────────────────────────────
section "4. Updating wp-config.php"

if [ "$SRC_PREFIX" != "wp_" ]; then
  info "Updating table prefix in wp-config.php..."
  $SSH_DEST "
    sudo sed -i \"s/'\\\$table_prefix = '[^']*'/'\\\$table_prefix = 'wp_'/\" $DEST_WP_PATH/wp-config.php
    sudo grep 'table_prefix' $DEST_WP_PATH/wp-config.php
  " 2>/dev/null

  fixed "wp-config.php updated with wp_ prefix"
else
  ok "Prefix already correct in wp-config.php"
fi

# ──────────────────────────────────────────
# 5. FIX FILE PERMISSIONS
# ──────────────────────────────────────────
section "5. Fixing File Permissions"

$SSH_DEST "
  sudo chown -R www-data:www-data $DEST_WP_PATH
  sudo find $DEST_WP_PATH -type d -exec chmod 755 {} \;
  sudo find $DEST_WP_PATH -type f -exec chmod 644 {} \;
  sudo chmod 640 $DEST_WP_PATH/wp-config.php
" 2>/dev/null

fixed "File permissions fixed"

# ──────────────────────────────────────────
# 6. RESTART SERVICES
# ──────────────────────────────────────────
section "6. Restarting Services"

$SSH_DEST "
  sudo systemctl restart apache2 2>/dev/null || sudo systemctl restart nginx 2>/dev/null || /opt/bitnami/ctlscript.sh restart apache 2>/dev/null
  PHP_VER=\$(php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;' 2>/dev/null)
  [ -n \"\$PHP_VER\" ] && sudo systemctl restart php\${PHP_VER}-fpm 2>/dev/null || true
" 2>/dev/null

fixed "Services restarted"

# ──────────────────────────────────────────
# 7. VERIFY
# ──────────────────────────────────────────
section "7. Verification"

TABLE_COUNT=$($SSH_DEST "sudo mysql --defaults-file=/root/.my.cnf -e \"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DEST_DB' AND TABLE_NAME LIKE 'wp_%';\" --skip-column-names" 2>/dev/null)

ok "Database tables: $TABLE_COUNT (should be 12+)"

WP_CONTENT_FILES=$($SSH_DEST "find $DEST_WP_PATH/wp-content -type f | wc -l" 2>/dev/null)

ok "wp-content files: $WP_CONTENT_FILES (should be more than 5)"

HTTP_CODE=$($SSH_DEST "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: catalyticministries.com' http://localhost/" 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
  fixed "Site responding (HTTP 200)"
else
  warn "Site response: HTTP $HTTP_CODE"
fi

echo ""
echo -e "${GRN}${BOLD}Migration fix complete!${NC}"
echo ""
