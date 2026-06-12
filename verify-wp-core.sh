#!/bin/bash
# =============================================================================
# verify-wp-core.sh
# Runs wp core verify-checksums on every WordPress install under public_html.
# Reports which sites have modified/missing core files and which are clean.
#
# Usage:
#   bash verify-wp-core.sh [webroot]
#
# Example:
#   bash verify-wp-core.sh
#   bash verify-wp-core.sh /home3/esalas/public_html
# =============================================================================

set -uo pipefail

WEBROOT="${1:-$HOME/public_html}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="$HOME/wp_verify_logs"
SUMMARY_FILE="${LOG_DIR}/verify_summary_${TIMESTAMP}.txt"

mkdir -p "$LOG_DIR"

TOTAL=0
CLEAN=0
FAILED=0
SKIPPED=0

echo "════════════════════════════════════════════════"
echo " Graywell WP Core Checksum Verifier"
echo " Webroot: $WEBROOT"
echo " Started: $(date)"
echo "════════════════════════════════════════════════"
echo ""

{
  echo "WP Core Verify — $TIMESTAMP"
  echo "Webroot: $WEBROOT"
  echo ""
} > "$SUMMARY_FILE"

while IFS= read -r config; do
  site_dir=$(dirname "$config")
  site_name=$(echo "$site_dir" | sed "s|$WEBROOT/?||")
  SITE_LOG="${LOG_DIR}/verify_${site_name//\//_}_${TIMESTAMP}.log"
  TOTAL=$((TOTAL + 1))

  echo -n "[$site_name] "

  # Check WP-CLI can work with this install
  if ! wp --path="$site_dir" core is-installed 2>/dev/null; then
    echo "SKIP — not a valid WP install"
    SKIPPED=$((SKIPPED + 1))
    echo "SKIP    $site_name — not a valid WP install" >> "$SUMMARY_FILE"
    continue
  fi

  # Get WP version for reference
  wp_version=$(wp --path="$site_dir" core version 2>/dev/null || echo "unknown")
  echo -n "v${wp_version} ... "

  # Run checksum verification
  # Exit 0 = all good, non-zero = modified/missing files
  checksum_output=$(wp --path="$site_dir" core verify-checksums 2>&1)
  checksum_exit=$?

  if [[ $checksum_exit -eq 0 ]]; then
    echo "✓ CLEAN"
    CLEAN=$((CLEAN + 1))
    echo "CLEAN   $site_name (WP $wp_version)" >> "$SUMMARY_FILE"
  else
    echo "⚠ FAILED"
    echo ""
    # Print each modified/missing file
    echo "$checksum_output" | grep -iE "modified|missing|checksum|error" | sed 's/^/   /'
    echo ""
    FAILED=$((FAILED + 1))
    {
      echo "FAILED  $site_name (WP $wp_version)"
      echo "$checksum_output" | grep -iE "modified|missing|checksum|error" | sed 's/^/        /'
      echo ""
    } >> "$SUMMARY_FILE"
    # Write full output to site log
    echo "$checksum_output" > "$SITE_LOG"
  fi

done < <(find "$WEBROOT" -name "wp-config.php" \
  -not -path "*/wp-admin/*" \
  -not -path "*/wp-includes/*" \
  2>/dev/null | sort)

echo "════════════════════════════════════════════════"
echo " DONE"
echo " Total:   $TOTAL"
echo " Clean:   $CLEAN"
echo " Failed:  $FAILED"
echo " Skipped: $SKIPPED"
echo " Summary: $SUMMARY_FILE"
echo "════════════════════════════════════════════════"

{
  echo "────────────────────────────────"
  echo "TOTALS"
  echo "  Total:   $TOTAL"
  echo "  Clean:   $CLEAN"
  echo "  Failed:  $FAILED"
  echo "  Skipped: $SKIPPED"
} >> "$SUMMARY_FILE"

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "To reinstall WP core on a failed site (preserves content):"
  echo "  wp core download --path=/path/to/site --version=VERSION --force --skip-content"
  echo ""
  echo "To reinstall all failed sites automatically, re-run with --fix:"
  echo "  bash verify-wp-core.sh --fix"
fi

# ── Optional --fix mode: reinstall core on any failed site ───────────────────
if [[ "${2:-}" == "--fix" ]]; then
  echo ""
  echo "════════════════════════════════════════════════"
  echo " FIX MODE — Reinstalling WP core on failed sites"
  echo "════════════════════════════════════════════════"
  echo ""

  grep "^FAILED" "$SUMMARY_FILE" | while IFS= read -r line; do
    site_name=$(echo "$line" | awk '{print $2}')
    site_dir="${WEBROOT}/${site_name}"
    wp_version=$(wp --path="$site_dir" core version 2>/dev/null || echo "")

    echo -n "[$site_name] Reinstalling WP $wp_version ... "
    if wp --path="$site_dir" core download \
        --version="$wp_version" \
        --force \
        --skip-content 2>/dev/null; then
      echo "✓ Done"
    else
      echo "✗ Failed"
    fi
  done
fi

[[ $FAILED -gt 0 ]] && exit 2
exit 0