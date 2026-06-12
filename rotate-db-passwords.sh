#!/bin/bash
# =============================================================================
# rotate-db-passwords.sh
# Rotate MySQL passwords for all WordPress installs under public_html.
# Updates both MySQL and wp-config.php on each site.
#
# Usage:
#   bash rotate-db-passwords.sh [webroot]
#
# Example:
#   bash rotate-db-passwords.sh
#   bash rotate-db-passwords.sh /home/esalas/public_html
# =============================================================================

set -uo pipefail

WEBROOT="${1:-$HOME/public_html}"
MYSQL_ADMIN_USER="esalas"   # update to your cPanel/MySQL admin username
MYSQL_ADMIN_PASS=""         # leave blank to be prompted

# ── Prompt for password if not set ───────────────────────────────────────────
if [[ -z "$MYSQL_ADMIN_PASS" ]]; then
  read -rsp "MySQL admin password for '$MYSQL_ADMIN_USER': " MYSQL_ADMIN_PASS
  echo ""
fi

# ── Verify admin connection ───────────────────────────────────────────────────
if ! mysql -u "$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" -e "SELECT 1;" &>/dev/null; then
  echo "ERROR: Could not connect to MySQL with provided credentials. Aborting."
  exit 1
fi

echo ""
echo "=== Rotating DB passwords under: $WEBROOT ==="
echo ""

SUCCESS=0
FAILED=0
SKIPPED=0

# ── Process each wp-config.php ────────────────────────────────────────────────
while IFS= read -r config; do
  site_dir=$(dirname "$config")
  site_name=$(echo "$site_dir" | sed "s|$WEBROOT/?||")

  # Parse credentials — handles both define( ' and define(' formats
  db_user=$(grep "DB_USER"     "$config" | grep -oP "(?<=')[^']+(?='[^']*\)\s*;)" | head -1)
  db_name=$(grep "DB_NAME"     "$config" | grep -oP "(?<=')[^']+(?='[^']*\)\s*;)" | head -1)
  db_host=$(grep "DB_HOST"     "$config" | grep -oP "(?<=')[^']+(?='[^']*\)\s*;)" | head -1)
  db_host="${db_host:-localhost}"

  if [[ -z "$db_user" || -z "$db_name" ]]; then
    echo "[$site_name] SKIP — could not parse DB_USER or DB_NAME from wp-config.php"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Generate a strong random password (24 chars, no quotes or backslashes)
  new_pass=$(tr -dc 'A-Za-z0-9!@#%^&*()-_=+' </dev/urandom | head -c 24)

  echo -n "[$site_name] $db_user @ $db_name (host: $db_host) ... "

  # Try ALTER USER first (MySQL 5.7+), fall back to SET PASSWORD (older)
  if mysql -u "$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" \
      -e "ALTER USER '${db_user}'@'${db_host}' IDENTIFIED BY '${new_pass}';" 2>/dev/null; then
    :
  elif mysql -u "$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" \
      -e "SET PASSWORD FOR '${db_user}'@'${db_host}' = PASSWORD('${new_pass}');" 2>/dev/null; then
    :
  else
    echo "FAILED (MySQL error — user may not exist or host mismatch)"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Flush privileges to ensure change takes effect immediately
  mysql -u "$MYSQL_ADMIN_USER" -p"$MYSQL_ADMIN_PASS" -e "FLUSH PRIVILEGES;" &>/dev/null

  # Update wp-config.php — handles both define( ' and define(' formats
  sed -i \
    "s|define( 'DB_PASSWORD'[^)]*)|define( 'DB_PASSWORD', '${new_pass}' )|g;
     s|define('DB_PASSWORD'[^)]*)|define('DB_PASSWORD', '${new_pass}')|g" \
    "$config"

  echo "OK"
  SUCCESS=$((SUCCESS + 1))

done < <(find "$WEBROOT" -name "wp-config.php" \
  -not -path "*/wp-admin/*" \
  -not -path "*/wp-includes/*" \
  2>/dev/null | sort)

echo ""
echo "════════════════════════════════════════"
echo " DONE"
echo " Rotated:  $SUCCESS"
echo " Failed:   $FAILED"
echo " Skipped:  $SKIPPED"
echo "════════════════════════════════════════"

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "For failed sites, check that the DB user exists and the host value"
  echo "matches MySQL. Run this to see all user/host combos:"
  echo "  mysql -u $MYSQL_ADMIN_USER -p -e \"SELECT user, host FROM mysql.user WHERE user LIKE 'esalas_%';\""
fi