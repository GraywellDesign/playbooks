#!/bin/bash
# =============================================================================
# block-uploads-php.sh
# Adds PHP execution block to wp-content/uploads/.htaccess on every WordPress
# site under public_html. Creates the .htaccess if it doesn't exist.
# Safe to run multiple times — won't add duplicates.
#
# Usage:
#   bash block-uploads-php.sh [webroot]
# =============================================================================

set -uo pipefail

WEBROOT="${1:-$HOME/public_html}"

BLOCK='# Block PHP execution in uploads
<FilesMatch "\.(php|php5|php7|php8|phtml|phar)$">
  Order Allow,Deny
  Deny from all
</FilesMatch>'

MARKER="Block PHP execution in uploads"

SUCCESS=0
SKIPPED=0
CREATED=0
FAILED=0

echo "=== Blocking PHP execution in uploads under: $WEBROOT ==="
echo ""

while IFS= read -r uploads_dir; do
  site_dir=$(echo "$uploads_dir" | sed "s|/wp-content/uploads||")
  site_name=$(echo "$site_dir" | sed "s|$WEBROOT/?||")
  htaccess="${uploads_dir}/.htaccess"

  echo -n "[$site_name] ... "

  # Skip if block already present
  if [[ -f "$htaccess" ]] && grep -q "$MARKER" "$htaccess" 2>/dev/null; then
    echo "already protected — skip"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Append or create
  if echo "$BLOCK" >> "$htaccess" 2>/dev/null; then
    chmod 644 "$htaccess"
    if [[ -f "$htaccess" ]] && grep -c "." "$htaccess" | grep -q "^[1-9]"; then
      if grep -q "$MARKER" "$htaccess" 2>/dev/null; then
        [[ $(grep -c "." "$htaccess") -gt 6 ]] && echo "appended to existing .htaccess" || echo "created new .htaccess"
        SUCCESS=$((SUCCESS + 1))
      fi
    fi
  else
    echo "FAILED (could not write to $htaccess)"
    FAILED=$((FAILED + 1))
  fi

done < <(find "$WEBROOT" -type d -name "uploads" -path "*/wp-content/uploads" 2>/dev/null | sort)

echo ""
echo "════════════════════════════════════════"
echo " DONE"
echo " Protected: $SUCCESS"
echo " Skipped (already had block): $SKIPPED"
echo " Failed:    $FAILED"
echo "════════════════════════════════════════"
echo ""
echo "To verify, run:"
echo "  find $WEBROOT -path '*/wp-content/uploads/.htaccess' | xargs grep -l 'Deny from all'"