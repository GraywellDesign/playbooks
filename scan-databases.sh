#!/bin/bash
# =============================================================================
# scan-databases.sh
# Scans WordPress databases for signs of malicious code across all sites.
# Automatically detects table prefix per site.
#
# Usage:
#   bash scan-databases.sh [webroot]
#
# Example:
#   bash scan-databases.sh
#   bash scan-databases.sh /home3/esalas/public_html
# =============================================================================

set -uo pipefail

WEBROOT="${1:-$HOME/public_html}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="$HOME/db_scan_logs"
SUMMARY_FILE="${LOG_DIR}/db_scan_summary_${TIMESTAMP}.txt"

mkdir -p "$LOG_DIR"

# ── Known malicious patterns ──────────────────────────────────────────────────
# C2 domains and IPs from this attack family
C2_PATTERN="zvo4\.xyz|zvo1\.xyz|icw7\.com|45\.11\.57\.159"

# PHP execution patterns that don't belong in DB content
EXEC_PATTERN="eval\\\(|base64_decode\\\(|system\\\(|exec\\\(|shell_exec\\\(|passthru\\\(|assert\\\("

# Injection patterns — iframes and scripts from unknown sources only
# Note: legitimate iframes (YouTube, Vimeo, Google Maps, WordPress oEmbed) are
# whitelisted below at query time to avoid false positives
INJECT_PATTERN="<script[^>]*src=|<iframe[^>]*src=|document\.write\\\(|\.onion|\.php\?cmd="

# Obfuscation patterns
OBFUS_PATTERN="str_rot13|gzinflate|gzuncompress|str_replace.*base64|preg_replace.*\/e"

# ── Whitelist patterns (legitimate content to exclude from results) ────────────
# oEmbed meta keys — WordPress caches embedded content in postmeta, all legitimate
OEMBED_META_KEY="_oembed_"

# Legitimate iframe sources — YouTube, Vimeo, Google Maps, WordPress embeds,
# SoundCloud, and standard oEmbed providers
SAFE_IFRAME_SOURCES="youtube\.com|youtu\.be|vimeo\.com|maps\.google\.com|google\.com/maps|wordpress\.org|soundcloud\.com|w\.soundcloud\.com|player\.vimeo\.com|spotify\.com|wistia\.com|loom\.com"

# oEmbed cache post type — WordPress stores embed previews as posts of this type
# These will always contain iframes and are 100% legitimate
OEMBED_POST_TYPE="oembed_cache"

TOTAL_SITES=0
CLEAN_SITES=0
FLAGGED_SITES=0
SKIPPED_SITES=0

# ── Helpers ───────────────────────────────────────────────────────────────────
pass()  { echo "   ✓ $*"; }
alert() { echo "   ⚠ ALERT: $*"; }
info()  { echo "   · $*"; }
skip()  { echo "   – $*"; }

# ── Main loop ─────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════"
echo " Graywell DB Malware Scanner"
echo " Webroot: $WEBROOT"
echo " Started: $(date)"
echo "════════════════════════════════════════════════"
echo ""

{
  echo "Graywell DB Scan — $TIMESTAMP"
  echo "Webroot: $WEBROOT"
  echo ""
} > "$SUMMARY_FILE"

while IFS= read -r config; do
  site_dir=$(dirname "$config")
  site_name=$(echo "$site_dir" | sed "s|$WEBROOT/?||")
  SITE_LOG="${LOG_DIR}/db_scan_${site_name//\//_}_${TIMESTAMP}.log"
  SITE_ALERTS=0
  TOTAL_SITES=$((TOTAL_SITES + 1))

  echo "[$site_name]"

  # Verify WP-CLI can connect
  if ! wp --path="$site_dir" db check &>/dev/null; then
    skip "Cannot connect to database — skipping"
    SKIPPED_SITES=$((SKIPPED_SITES + 1))
    echo "SKIP $site_name — DB connection failed" >> "$SUMMARY_FILE"
    echo ""
    continue
  fi

  # Get table prefix
  prefix=$(wp --path="$site_dir" config get table_prefix 2>/dev/null || echo "wp_")
  info "Table prefix: $prefix"

  # ── Check 1: siteurl and home ───────────────────────────────────────────────
  siteurl=$(wp --path="$site_dir" option get siteurl 2>/dev/null || echo "")
  home=$(wp --path="$site_dir" option get home 2>/dev/null || echo "")

  if echo "$siteurl $home" | grep -qiP "$C2_PATTERN"; then
    alert "Malicious redirect in siteurl/home: $siteurl / $home"
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "siteurl/home clean: $siteurl"
  fi

  # ── Check 2: Options table — injected scripts/code ─────────────────────────
  # Excludes: transient/feed caches, oEmbed caches, minified CSS/JS stored by
  # plugins (nfd_utilities, etc.), and legitimate iframe sources
  result=$(wp --path="$site_dir" db query \
    "SELECT option_name, LEFT(option_value,300) FROM ${prefix}options
     WHERE option_value REGEXP '${C2_PATTERN}|${INJECT_PATTERN}|${OBFUS_PATTERN}'
     AND option_name NOT REGEXP '^_transient_|^_site_transient_'
     AND option_value NOT REGEXP '${SAFE_IFRAME_SOURCES}'
     AND option_name NOT IN ('nfd_utilities_css','nfd_utilities_js')
     LIMIT 20;" 2>/dev/null || echo "")

  if [[ -n "$result" && "$result" != *"0 rows"* ]]; then
    alert "Suspicious content in options table:"
    echo "$result" | sed 's/^/      /'
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "Options table clean"
  fi

  # ── Check 3: Post content — injected scripts ────────────────────────────────
  # Excludes: oembed_cache post type (WP stores embed previews here, always has
  # iframes), and iframes from known-safe sources (YouTube, Vimeo, Maps, etc.)
  result=$(wp --path="$site_dir" db query \
    "SELECT ID, post_title, post_type, post_status, LEFT(post_content,200)
     FROM ${prefix}posts
     WHERE post_content REGEXP '${C2_PATTERN}|${INJECT_PATTERN}|${EXEC_PATTERN}'
     AND post_status != 'auto-draft'
     AND post_type != 'oembed_cache'
     AND post_content NOT REGEXP '${SAFE_IFRAME_SOURCES}'
     LIMIT 20;" 2>/dev/null || echo "")

  if [[ -n "$result" && "$result" != *"0 rows"* ]]; then
    alert "Suspicious content in posts:"
    echo "$result" | sed 's/^/      /'
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "Post content clean"
  fi

  # ── Check 4: Postmeta — injected payloads ──────────────────────────────────
  # Excludes: _oembed_* keys (WP caches oEmbed HTML here, always has iframes),
  # _elementor_element_cache (Elementor render cache, contains full HTML),
  # and postmeta values containing only safe iframe sources
  result=$(wp --path="$site_dir" db query \
    "SELECT post_id, meta_key, LEFT(meta_value,200)
     FROM ${prefix}postmeta
     WHERE meta_value REGEXP '${C2_PATTERN}|${INJECT_PATTERN}'
     AND meta_key NOT LIKE '_oembed_%'
     AND meta_key NOT IN ('_elementor_element_cache','_elementor_data')
     AND meta_value NOT REGEXP '${SAFE_IFRAME_SOURCES}'
     LIMIT 20;" 2>/dev/null || echo "")

  if [[ -n "$result" && "$result" != *"0 rows"* ]]; then
    alert "Suspicious content in postmeta:"
    echo "$result" | sed 's/^/      /'
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "Postmeta clean"
  fi

  # ── Check 5: Usermeta — injected session data ───────────────────────────────
  result=$(wp --path="$site_dir" db query \
    "SELECT user_id, meta_key, LEFT(meta_value,200)
     FROM ${prefix}usermeta
     WHERE meta_value REGEXP '${C2_PATTERN}|${INJECT_PATTERN}'
     AND meta_value NOT REGEXP '${SAFE_IFRAME_SOURCES}'
     LIMIT 20;" 2>/dev/null || echo "")

  if [[ -n "$result" && "$result" != *"0 rows"* ]]; then
    alert "Suspicious content in usermeta:"
    echo "$result" | sed 's/^/      /'
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "Usermeta clean"
  fi

  # ── Check 6: Rogue admin users ──────────────────────────────────────────────
  admin_count=$(wp --path="$site_dir" user list --role=administrator --format=count 2>/dev/null || echo "0")
  admins=$(wp --path="$site_dir" user list --role=administrator \
    --fields=ID,user_login,user_email,user_registered --format=table 2>/dev/null || echo "")

  if [[ "$admin_count" -gt 3 ]]; then
    alert "Unusually high admin count ($admin_count) — review:"
    echo "$admins" | sed 's/^/      /'
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "Admin users ($admin_count):"
    echo "$admins" | sed 's/^/      /'
  fi

  # ── Check 7: Suspicious cron jobs ──────────────────────────────────────────
  cron_result=$(wp --path="$site_dir" db query \
    "SELECT option_value FROM ${prefix}options
     WHERE option_name = 'cron';" 2>/dev/null || echo "")

  if echo "$cron_result" | grep -qiP "$C2_PATTERN|eval\(|base64_decode"; then
    alert "Suspicious cron job detected in wp_options"
    SITE_ALERTS=$((SITE_ALERTS + 1))
  else
    pass "Cron jobs clean"
  fi

  # ── Check 8: WooCommerce sessions — injected payloads ──────────────────────
  if wp --path="$site_dir" db query "SHOW TABLES LIKE '${prefix}woocommerce_sessions';" \
      2>/dev/null | grep -q "woocommerce_sessions"; then
    result=$(wp --path="$site_dir" db query \
      "SELECT session_id, LEFT(session_value,200)
       FROM ${prefix}woocommerce_sessions
       WHERE session_value REGEXP '${C2_PATTERN}|${INJECT_PATTERN}'
       LIMIT 10;" 2>/dev/null || echo "")

    if [[ -n "$result" && "$result" != *"0 rows"* ]]; then
      alert "Suspicious content in WooCommerce sessions:"
      echo "$result" | sed 's/^/      /'
      SITE_ALERTS=$((SITE_ALERTS + 1))
    else
      pass "WooCommerce sessions clean"
    fi
  fi

  # ── Site summary ─────────────────────────────────────────────────────────────
  echo ""
  if [[ $SITE_ALERTS -eq 0 ]]; then
    echo "   ✓ DATABASE CLEAN"
    CLEAN_SITES=$((CLEAN_SITES + 1))
    echo "CLEAN   $site_name" >> "$SUMMARY_FILE"
  else
    echo "   ⚠ $SITE_ALERTS ALERT(S) FOUND — see $SITE_LOG"
    FLAGGED_SITES=$((FLAGGED_SITES + 1))
    echo "ALERTS  $site_name — $SITE_ALERTS alert(s)" >> "$SUMMARY_FILE"
  fi
  echo ""

done < <(find "$WEBROOT" -name "wp-config.php" \
  -not -path "*/wp-admin/*" \
  -not -path "*/wp-includes/*" \
  2>/dev/null | sort)

# ── Final summary ─────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════"
echo " DB SCAN COMPLETE"
echo " Total sites:  $TOTAL_SITES"
echo " Clean:        $CLEAN_SITES"
echo " Flagged:      $FLAGGED_SITES"
echo " Skipped:      $SKIPPED_SITES"
echo " Summary:      $SUMMARY_FILE"
echo "════════════════════════════════════════════════"

{
  echo ""
  echo "────────────────────────────────"
  echo "TOTALS"
  echo "  Total:   $TOTAL_SITES"
  echo "  Clean:   $CLEAN_SITES"
  echo "  Flagged: $FLAGGED_SITES"
  echo "  Skipped: $SKIPPED_SITES"
} >> "$SUMMARY_FILE"

[[ $FLAGGED_SITES -gt 0 ]] && exit 2
exit 0