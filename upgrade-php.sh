#!/bin/bash
# ============================================================
#  Graywell Design — PHP Version Upgrade Script
#  Installs new PHP, migrates extensions, switches web server,
#  tests, and supports rollback to previous version
#
#  Usage:  sudo bash upgrade-php.sh [target-version]
#  Example: sudo bash upgrade-php.sh 8.3
#
#  Rollback: sudo bash upgrade-php.sh rollback
# ============================================================

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
LOG=/opt/php-upgrade.log
STATE_FILE=/opt/php-upgrade-state.conf

ok()      { echo -e "  ${GRN}[OK]${NC}      $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" >> "$LOG"; }
warn()    { echo -e "  ${YEL}[WARN]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >> "$LOG"; }
bad()     { echo -e "  ${RED}[FAIL]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [FAIL] $1" >> "$LOG"; }
info()    { echo -e "  ${BLU}[INFO]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$LOG"; }
fixed()   { echo -e "  ${GRN}[DONE]${NC}    $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') [DONE] $1" >> "$LOG"; }
section() { echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo "$(date '+%Y-%m-%d %H:%M:%S') === $1 ===" >> "$LOG"; }

[ "$EUID" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

# ── Detect environment ───────────────────────────────────────
IS_BITNAMI=false
{ [ -d /opt/bitnami ] || [ -d /bitnami ]; } && IS_BITNAMI=true

# Detect web server
WEB_SERVER="none"
for path in /bitnami/apache2/conf/httpd.conf /opt/bitnami/apache/conf/httpd.conf /etc/apache2/apache2.conf; do
  [ -f "$path" ] && { WEB_SERVER="apache"; break; }
done
for path in /bitnami/nginx/conf/nginx.conf /opt/bitnami/nginx/conf/nginx.conf /etc/nginx/nginx.conf; do
  [ -f "$path" ] && { WEB_SERVER="nginx"; break; }
done

# ── Restart helper ───────────────────────────────────────────
restart_services() {
  local php_ver="$1"
  if $IS_BITNAMI; then
    /opt/bitnami/ctlscript.sh restart php-fpm >> "$LOG" 2>&1 || true
    /opt/bitnami/ctlscript.sh restart apache  >> "$LOG" 2>&1 || true
  else
    systemctl restart "php${php_ver}-fpm" >> "$LOG" 2>&1 || true
    [ "$WEB_SERVER" = "apache" ] && systemctl restart apache2 >> "$LOG" 2>&1 || true
    [ "$WEB_SERVER" = "nginx" ]  && systemctl restart nginx   >> "$LOG" 2>&1 || true
  fi
}

# ── HTTP test ────────────────────────────────────────────────
test_http() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost/ 2>/dev/null)
  echo "$code"
}

# ──────────────────────────────────────────
# ROLLBACK MODE
# ──────────────────────────────────────────
if [ "${1:-}" = "rollback" ]; then
  section "Rolling Back PHP"

  if [ ! -f "$STATE_FILE" ]; then
    bad "No upgrade state file found at $STATE_FILE — nothing to roll back"
    exit 1
  fi

  source "$STATE_FILE"
  info "Rolling back from PHP ${NEW_VER} to PHP ${OLD_VER}"

  if $IS_BITNAMI; then
    bad "Bitnami PHP rollback must be done manually via the Bitnami dashboard or by reinstalling"
    info "You can switch back by editing /opt/bitnami/php/etc/php-fpm.conf to point to php${OLD_VER}"
    exit 1
  fi

  # Switch Apache back
  if [ "$WEB_SERVER" = "apache" ]; then
    a2dismod "php${NEW_VER}" >> "$LOG" 2>&1 || true
    a2enmod  "php${OLD_VER}" >> "$LOG" 2>&1 || true
    fixed "Apache switched back to PHP ${OLD_VER}"
  fi

  # Switch PHP-FPM back
  if [ "$WEB_SERVER" = "apache" ]; then
    a2disconf "php${NEW_VER}-fpm" >> "$LOG" 2>&1 || true
    a2enconf  "php${OLD_VER}-fpm" >> "$LOG" 2>&1 || true
  fi

  # Update CLI default
  update-alternatives --set php "/usr/bin/php${OLD_VER}" >> "$LOG" 2>&1 || true

  # Restart services
  restart_services "$OLD_VER"
  sleep 3

  # Verify
  CURRENT=$(php -v 2>/dev/null | head -1 | grep -oP 'PHP \K[\d.]+' | cut -d. -f1,2)
  if [ "$CURRENT" = "$OLD_VER" ]; then
    fixed "Rollback successful — now running PHP ${CURRENT}"
    HTTP=$(test_http)
    [ "$HTTP" != "000" ] && ok "Site responding (HTTP $HTTP)" || warn "Site not responding after rollback — check manually"
  else
    bad "Rollback may have failed — running PHP ${CURRENT:-unknown}, expected ${OLD_VER}"
  fi
  exit 0
fi

# ──────────────────────────────────────────
# DETERMINE TARGET VERSION
# ──────────────────────────────────────────
TARGET_VER="${1:-}"

# Get current version
CURRENT_VER=$(php -v 2>/dev/null | head -1 | grep -oP 'PHP \K[\d.]+' | cut -d. -f1,2)
CURRENT_VER=${CURRENT_VER:-"unknown"}

echo -e "\n${BOLD}Graywell PHP Upgrade Script${NC}"
echo -e "Current PHP: ${CURRENT_VER} | Host: $(hostname)\n"

# If no target specified, show available versions and prompt
if [ -z "$TARGET_VER" ]; then
  info "Available PHP versions from ondrej/php PPA:"
  echo ""
  echo "    7.4  8.0  8.1  8.2  8.3  8.4"
  echo ""
  read -rp "  Target PHP version (e.g. 8.3): " TARGET_VER
fi

# Validate input
if ! [[ "$TARGET_VER" =~ ^[78]\.[0-9]+$ ]]; then
  bad "Invalid version: $TARGET_VER — use format like 8.3"
  exit 1
fi

if [ "$TARGET_VER" = "$CURRENT_VER" ]; then
  info "PHP ${TARGET_VER} is already the active version"
  exit 0
fi

info "Upgrading PHP: ${CURRENT_VER} → ${TARGET_VER}"
info "Web server: $WEB_SERVER | Bitnami: $IS_BITNAMI"
echo ""
echo -e "${YEL}This will restart your web server. Continue? [y/N]${NC} "
read -r CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# Save state for rollback
cat > "$STATE_FILE" <<EOF
OLD_VER="${CURRENT_VER}"
NEW_VER="${TARGET_VER}"
UPGRADE_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
WEB_SERVER="${WEB_SERVER}"
IS_BITNAMI="${IS_BITNAMI}"
EOF

echo "$(date '+%Y-%m-%d %H:%M:%S') === PHP Upgrade ${CURRENT_VER} → ${TARGET_VER} ===" >> "$LOG"

# ──────────────────────────────────────────
# 1. GET INSTALLED EXTENSIONS
# ──────────────────────────────────────────
section "1. Detecting Current PHP Extensions"

# Get list of installed PHP packages for current version
CURRENT_PKGS=$(dpkg -l "php${CURRENT_VER}-*" 2>/dev/null \
  | grep "^ii" \
  | awk '{print $2}' \
  | grep -v "^php${CURRENT_VER}$" \
  | sed "s/php${CURRENT_VER}-//" \
  | sort)

info "Installed extensions on PHP ${CURRENT_VER}:"
echo "$CURRENT_PKGS" | sed 's/^/    /'

# Build target package list
TARGET_PKGS=""
for ext in $CURRENT_PKGS; do
  pkg="php${TARGET_VER}-${ext}"
  # Check if package exists in apt
  if apt-cache show "$pkg" &>/dev/null; then
    TARGET_PKGS="$TARGET_PKGS $pkg"
  else
    warn "Extension not available for PHP ${TARGET_VER}: php${TARGET_VER}-${ext} — skipping"
  fi
done

# Always include core packages
TARGET_PKGS="php${TARGET_VER} php${TARGET_VER}-fpm php${TARGET_VER}-cli $TARGET_PKGS"

# ──────────────────────────────────────────
# 2. ADD PHP PPA (if needed)
# ──────────────────────────────────────────
section "2. PHP Repository"

if $IS_BITNAMI; then
  warn "Bitnami manages PHP independently — PPA not used"
  warn "For Bitnami, PHP upgrades should be done via the Bitnami documentation"
  warn "See: https://docs.bitnami.com/general/infrastructure/lamp/administration/upgrade-php/"
  echo ""
  read -rp "  Continue anyway with system PHP? [y/N]: " BITNAMI_CONFIRM
  [[ "$BITNAMI_CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

if ! apt-cache show "php${TARGET_VER}" &>/dev/null; then
  info "Adding ondrej/php PPA..."
  apt-get install -y -qq software-properties-common
  add-apt-repository -y ppa:ondrej/php >> "$LOG" 2>&1
  apt-get update -qq
  fixed "PPA added and package list updated"
else
  ok "PHP ${TARGET_VER} already available in package sources"
fi

# ──────────────────────────────────────────
# 3. INSTALL NEW PHP VERSION
# ──────────────────────────────────────────
section "3. Installing PHP ${TARGET_VER}"

info "Installing: $(echo $TARGET_PKGS | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')"
apt-get install -y -qq $TARGET_PKGS >> "$LOG" 2>&1 \
  && fixed "PHP ${TARGET_VER} and extensions installed" \
  || { bad "Installation failed — check $LOG"; exit 1; }

# ──────────────────────────────────────────
# 4. COPY PHP SETTINGS
# ──────────────────────────────────────────
section "4. Migrating PHP Configuration"

OLD_INI="/etc/php/${CURRENT_VER}/fpm/php.ini"
NEW_INI="/etc/php/${TARGET_VER}/fpm/php.ini"

if [ -f "$OLD_INI" ] && [ -f "$NEW_INI" ]; then
  # Extract key settings from old config and apply to new
  for setting in \
    "memory_limit" \
    "upload_max_filesize" \
    "post_max_size" \
    "max_execution_time" \
    "max_input_time" \
    "max_input_vars" \
    "date.timezone"; do

    OLD_VAL=$(grep -E "^${setting}\s*=" "$OLD_INI" 2>/dev/null | tail -1 | awk -F= '{print $2}' | tr -d ' ')
    if [ -n "$OLD_VAL" ]; then
      sed -i "s|^;*\s*${setting}\s*=.*|${setting} = ${OLD_VAL}|" "$NEW_INI" 2>/dev/null || true
      fixed "Migrated: ${setting} = ${OLD_VAL}"
    fi
  done
else
  warn "Could not find php.ini to migrate settings — check manually"
fi

# Migrate FPM pool config
OLD_POOL="/etc/php/${CURRENT_VER}/fpm/pool.d/www.conf"
NEW_POOL="/etc/php/${TARGET_VER}/fpm/pool.d/www.conf"

if [ -f "$OLD_POOL" ] && [ -f "$NEW_POOL" ]; then
  for setting in \
    "pm.max_children" \
    "pm.start_servers" \
    "pm.min_spare_servers" \
    "pm.max_spare_servers" \
    "pm.max_requests"; do

    OLD_VAL=$(grep -E "^${setting}\s*=" "$OLD_POOL" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if [ -n "$OLD_VAL" ]; then
      sed -i "s|^${setting}\s*=.*|${setting} = ${OLD_VAL}|" "$NEW_POOL" 2>/dev/null || true
      fixed "Migrated pool: ${setting} = ${OLD_VAL}"
    fi
  done
  ok "PHP-FPM pool settings migrated"
fi

# ──────────────────────────────────────────
# 5. SWITCH WEB SERVER TO NEW PHP
# ──────────────────────────────────────────
section "5. Switching Web Server to PHP ${TARGET_VER}"

# Record HTTP status before switch
HTTP_BEFORE=$(test_http)
info "HTTP status before switch: ${HTTP_BEFORE:-no response}"

if $IS_BITNAMI; then
  warn "Bitnami PHP switch must be done manually"
  info "Edit your Bitnami PHP-FPM config to point to php${TARGET_VER}"
else
  if [ "$WEB_SERVER" = "apache" ]; then
    # Disable old PHP module, enable new one
    a2dismod "php${CURRENT_VER}" >> "$LOG" 2>&1 || true
    a2enmod  "php${TARGET_VER}"  >> "$LOG" 2>&1 || true

    # Switch PHP-FPM conf
    a2disconf "php${CURRENT_VER}-fpm" >> "$LOG" 2>&1 || true
    a2enconf  "php${TARGET_VER}-fpm"  >> "$LOG" 2>&1 || true

    fixed "Apache switched to PHP ${TARGET_VER}"

  elif [ "$WEB_SERVER" = "nginx" ]; then
    # Update PHP-FPM socket reference in nginx configs
    OLD_SOCK="php${CURRENT_VER}-fpm.sock"
    NEW_SOCK="php${TARGET_VER}-fpm.sock"
    find /etc/nginx -name "*.conf" -exec \
      sed -i "s/${OLD_SOCK}/${NEW_SOCK}/g" {} \; 2>/dev/null || true
    fixed "Nginx config updated to use PHP ${TARGET_VER} socket"
  fi

  # Update CLI default
  update-alternatives --set php "/usr/bin/php${TARGET_VER}" >> "$LOG" 2>&1 \
    && fixed "PHP CLI default set to ${TARGET_VER}" \
    || warn "Could not set PHP CLI default — run: update-alternatives --config php"
fi

# ──────────────────────────────────────────
# 6. RESTART & TEST
# ──────────────────────────────────────────
section "6. Restarting Services & Testing"

info "Starting PHP ${TARGET_VER} FPM..."
systemctl enable "php${TARGET_VER}-fpm" >> "$LOG" 2>&1 || true
systemctl start  "php${TARGET_VER}-fpm" >> "$LOG" 2>&1 || true

info "Stopping PHP ${CURRENT_VER} FPM..."
systemctl stop    "php${CURRENT_VER}-fpm" >> "$LOG" 2>&1 || true
systemctl disable "php${CURRENT_VER}-fpm" >> "$LOG" 2>&1 || true

info "Restarting web server..."
restart_services "$TARGET_VER"
sleep 5

# Verify PHP version
ACTIVE_VER=$(php -v 2>/dev/null | head -1 | grep -oP 'PHP \K[\d.]+' | cut -d. -f1,2)
if [ "$ACTIVE_VER" = "$TARGET_VER" ]; then
  ok "PHP CLI version confirmed: ${ACTIVE_VER}"
else
  warn "PHP CLI shows ${ACTIVE_VER:-unknown} — may need: update-alternatives --config php"
fi

# Verify FPM is running
if systemctl is-active --quiet "php${TARGET_VER}-fpm" 2>/dev/null; then
  ok "PHP ${TARGET_VER}-FPM is running"
else
  bad "PHP ${TARGET_VER}-FPM is not running — check: systemctl status php${TARGET_VER}-fpm"
fi

# HTTP test
sleep 3
HTTP_AFTER=$(test_http)
info "HTTP status after switch: ${HTTP_AFTER:-no response}"

if [ "${HTTP_AFTER:-000}" != "000" ] && [ "${HTTP_AFTER:-000}" != "500" ]; then
  ok "Site is responding (HTTP ${HTTP_AFTER}) ✓"
  echo ""
  echo -e "${GRN}${BOLD}PHP upgrade successful!${NC}"
  echo -e "  Old version: PHP ${CURRENT_VER}"
  echo -e "  New version: PHP ${TARGET_VER}"
  echo -e "  HTTP status: ${HTTP_AFTER}"
  echo ""
  echo -e "  To roll back if issues arise: ${BOLD}sudo bash upgrade-php.sh rollback${NC}"
else
  bad "Site is not responding after upgrade (HTTP ${HTTP_AFTER:-no response})"
  echo ""
  echo -e "${RED}${BOLD}Site may be down — rolling back automatically...${NC}"
  echo ""

  # Auto-rollback
  if ! $IS_BITNAMI; then
    if [ "$WEB_SERVER" = "apache" ]; then
      a2dismod "php${TARGET_VER}" >> "$LOG" 2>&1 || true
      a2enmod  "php${CURRENT_VER}" >> "$LOG" 2>&1 || true
      a2disconf "php${TARGET_VER}-fpm" >> "$LOG" 2>&1 || true
      a2enconf  "php${CURRENT_VER}-fpm" >> "$LOG" 2>&1 || true
    elif [ "$WEB_SERVER" = "nginx" ]; then
      find /etc/nginx -name "*.conf" -exec \
        sed -i "s/php${TARGET_VER}-fpm.sock/php${CURRENT_VER}-fpm.sock/g" {} \; 2>/dev/null || true
    fi

    update-alternatives --set php "/usr/bin/php${CURRENT_VER}" >> "$LOG" 2>&1 || true
    systemctl start  "php${CURRENT_VER}-fpm" >> "$LOG" 2>&1 || true
    systemctl stop   "php${TARGET_VER}-fpm"  >> "$LOG" 2>&1 || true
    restart_services "$CURRENT_VER"
    sleep 5

    HTTP_ROLLBACK=$(test_http)
    if [ "${HTTP_ROLLBACK:-000}" != "000" ]; then
      fixed "Auto-rollback successful — site restored on PHP ${CURRENT_VER} (HTTP ${HTTP_ROLLBACK})"
    else
      bad "Auto-rollback failed — site still down. Check $LOG and restart services manually"
    fi
  else
    warn "Bitnami auto-rollback not supported — restore manually"
  fi

  exit 1
fi

# ──────────────────────────────────────────
# 7. CLEANUP (optional)
# ──────────────────────────────────────────
section "7. Cleanup"

echo ""
echo -e "${YEL}Remove old PHP ${CURRENT_VER} packages to free disk space? [y/N]${NC} "
read -r CLEANUP
if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
  apt-get purge -y "php${CURRENT_VER}*" >> "$LOG" 2>&1 \
    && fixed "PHP ${CURRENT_VER} removed" \
    || warn "Could not fully remove PHP ${CURRENT_VER} — remove manually with: apt purge php${CURRENT_VER}*"
  info "Note: rollback will no longer be possible after removing old PHP"
  rm -f "$STATE_FILE"
else
  ok "PHP ${CURRENT_VER} kept — rollback available with: sudo bash upgrade-php.sh rollback"
fi

echo ""
echo -e "Log: ${BOLD}$LOG${NC}"