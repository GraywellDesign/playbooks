#!/bin/bash
# =============================================================================
# reset-wp-passwords.sh
# Force reset passwords for ALL WordPress users on every site in public_html.
# Also destroys all active sessions so users must log in again.
#
# Usage:
#   bash reset-wp-passwords.sh [webroot]
#
# Example:
#   bash reset-wp-passwords.sh
#   bash reset-wp-passwords.sh /home/esalas/public_html
# =============================================================================

set -uo pipefail

WEBROOT="${1:-$HOME/public_html}"

# Password length for generated passwords
PASS_LENGTH=20

SUCCESS=0
FAILED=0
SKIPPED=0
TOTAL_USERS=0

echo "=== Resetting WordPress user passwords under: $WEBROOT ==="
echo ""

while IFS= read -r config; do
  site_dir=$(dirname "$config")
  site_name=$(echo "$site_dir" | sed "s|$WEBROOT/?||")

  echo "[$site_name]"

  # Verify it's a valid WP install WP-CLI can work with
  if ! wp --path="$site_dir" core is-installed 2>/dev/null; then
    echo "  SKIP — not a valid WordPress install"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Get all user IDs
  user_ids=$(wp --path="$site_dir" user list --field=ID 2>/dev/null)

  if [[ -z "$user_ids" ]]; then
    echo "  SKIP — no users found"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  site_ok=true

  while IFS= read -r user_id; do
    user_login=$(wp --path="$site_dir" user get "$user_id" --field=user_login 2>/dev/null)
    user_email=$(wp --path="$site_dir" user get "$user_id" --field=user_email 2>/dev/null)

    # Generate a strong random password
    new_pass=$(tr -dc 'A-Za-z0-9!@#%^&*()-_=+' </dev/urandom | head -c "$PASS_LENGTH")

    if wp --path="$site_dir" user update "$user_id" \
        --user_pass="$new_pass" \
        --skip-email 2>/dev/null; then
      echo "  ✓ $user_login ($user_email) — password reset"
      TOTAL_USERS=$((TOTAL_USERS + 1))
    else
      echo "  ✗ $user_login ($user_email) — FAILED"
      site_ok=false
    fi

  done <<< "$user_ids"

  # Destroy all active sessions for this site
  if wp --path="$site_dir" session destroy --all 2>/dev/null; then
    echo "  ✓ All sessions destroyed"
  else
    # Fallback: delete session tokens from usermeta directly
    wp --path="$site_dir" eval \
      'global $wpdb; $wpdb->query("DELETE FROM {$wpdb->usermeta} WHERE meta_key = \"session_tokens\"");' \
      2>/dev/null && echo "  ✓ Sessions cleared via DB" || echo "  ⚠ Could not destroy sessions"
  fi

  if $site_ok; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  echo ""

done < <(find "$WEBROOT" -name "wp-config.php" \
  -not -path "*/wp-admin/*" \
  -not -path "*/wp-includes/*" \
  2>/dev/null | sort)

echo "════════════════════════════════════════"
echo " DONE"
echo " Sites succeeded: $SUCCESS"
echo " Sites failed:    $FAILED"
echo " Sites skipped:   $SKIPPED"
echo " Total users reset: $TOTAL_USERS"
echo "════════════════════════════════════════"
echo ""
echo "NOTE: All user passwords have been randomized. To set a known"
echo "password for a specific admin user, run:"
echo "  wp --path=/path/to/site user update USERNAME --user_pass='NewPassword123!'"