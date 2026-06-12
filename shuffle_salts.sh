#!/bin/bash
# shuffle-salts.sh — Regenerate WordPress secret keys on all sites in public_html

WEBROOT="${1:-$HOME/public_html}"
FAILED=0
SUCCESS=0

echo "=== Shuffling WordPress salts under: $WEBROOT ==="
echo ""

for config in $(find "$WEBROOT" -name "wp-config.php" -not -path "*/wp-admin/*" 2>/dev/null); do
  site=$(dirname "$config")
  name=$(echo "$site" | sed "s|$WEBROOT/||")

  echo -n "[$name] ... "

  if wp --path="$site" config shuffle-salts 2>/dev/null; then
    SUCCESS=$((SUCCESS + 1))
  else
    echo "FAILED (wp-cli error or not a valid WP install)"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Done: $SUCCESS succeeded, $FAILED failed ==="