#!/bin/bash

# Christ Journey Church - Performance Diagnostic Script
# Run on: ssh -i /Users/ericsalas/esalas_rsa esalas@100.27.149.231
# Purpose: Comprehensive performance analysis without making changes

set -e

REPORT_FILE="/tmp/christjourney-diagnostics-$(date +%s).txt"
WEBSITE="https://christjourney.org"
WP_PATH="/var/www/html"

echo "=== CHRIST JOURNEY PERFORMANCE DIAGNOSTIC REPORT ===" | tee $REPORT_FILE
echo "Generated: $(date)" | tee -a $REPORT_FILE
echo "Server: 100.27.149.231" | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 1. SYSTEM HEALTH CHECK
# ============================================================================
echo "1. SYSTEM HEALTH & RESOURCES" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "CPU Info:" | tee -a $REPORT_FILE
nproc | xargs -I {} echo "  Cores: {}" | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Memory:" | tee -a $REPORT_FILE
free -h | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Load Average (last 1, 5, 15 min):" | tee -a $REPORT_FILE
uptime | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Disk Usage:" | tee -a $REPORT_FILE
df -h /var/www | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "I/O Usage (iostat snapshot):" | tee -a $REPORT_FILE
if command -v iostat &> /dev/null; then
  iostat -x 1 2 | tail -6 | tee -a $REPORT_FILE
else
  echo "  iostat not available" | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 2. WEB SERVER PERFORMANCE
# ============================================================================
echo "2. WEB SERVER & PHP PERFORMANCE" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "Apache Configuration:" | tee -a $REPORT_FILE
grep -E "MaxRequestWorkers|StartServers|MinSpareServers|MaxSpareServers" /etc/apache2/mods-available/mpm_prefork.conf | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Apache Worker Processes:" | tee -a $REPORT_FILE
ps aux | grep -c "[a]pache2" | xargs echo "  Active processes:" | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "PHP Configuration:" | tee -a $REPORT_FILE
php -i | grep -E "memory_limit|max_execution_time|upload_max_filesize|display_errors|error_reporting" | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "OPcache Status:" | tee -a $REPORT_FILE
php -r "if(function_exists('opcache_get_status')){ \$s=opcache_get_status(); echo 'Enabled: '.($s['opcache_enabled']?'YES':'NO').'\n'; if(\$s['opcache_enabled']){ echo 'Memory: '.\$s['memory_usage']['used_memory']/1024/1024 .'MB / '.\$s['memory_usage']['buffer_size']/1024/1024 .'MB\n'; echo 'Cached scripts: '.\$s['opcache_statistics']['num_cached_scripts'].'\n'; }} else { echo 'OPcache not available\n'; }" | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 3. PAGE LOAD PERFORMANCE TESTS
# ============================================================================
echo "3. PAGE LOAD TIME TESTS" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "Testing homepage load times (5 requests)..." | tee -a $REPORT_FILE
for i in {1..5}; do
  echo "  Request $i:" | tee -a $REPORT_FILE
  curl -s -w "    TTFB: %{time_starttransfer}s | Total: %{time_total}s | Size: %{size_download} bytes\n" -o /dev/null "$WEBSITE" 2>&1 | tee -a $REPORT_FILE
  sleep 1
done
echo "" | tee -a $REPORT_FILE

echo "Testing homepage with full timing breakdown:" | tee -a $REPORT_FILE
curl -s -w "@/tmp/curl-timing.txt" -o /dev/null "$WEBSITE" 2>&1 | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 4. WORDPRESS PLUGINS ANALYSIS
# ============================================================================
echo "4. WORDPRESS PLUGINS ANALYSIS" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

cd $WP_PATH

echo "Active Plugins:" | tee -a $REPORT_FILE
wp plugin list --status=active 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Plugin Sizes (largest plugins):" | tee -a $REPORT_FILE
find wp-content/plugins -maxdepth 2 -type d -not -path '*/\.*' | while read dir; do
  du -sh "$dir" 2>/dev/null
done | sort -rh | head -10 | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Plugins requiring attention:" | tee -a $REPORT_FILE
if wp plugin list --status=active 2>/dev/null | grep -i "amp\|autoptimize\|w3-total-cache\|broken-link-checker"; then
  echo "  See individual plugin status below" | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 5. DATABASE PERFORMANCE
# ============================================================================
echo "5. DATABASE PERFORMANCE" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "MariaDB Server Status:" | tee -a $REPORT_FILE
mysql -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | tee -a $REPORT_FILE
mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | tee -a $REPORT_FILE
mysql -e "SHOW VARIABLES LIKE 'query_cache%';" 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Database Tables (size and row count):" | tee -a $REPORT_FILE
mysql wordpress -e "SELECT TABLE_NAME, ROUND(((data_length + index_length) / 1024 / 1024), 2) AS size_mb, TABLE_ROWS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'wordpress' ORDER BY size_mb DESC LIMIT 10;" 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Checking for table optimization needed:" | tee -a $REPORT_FILE
mysql wordpress -e "CHECK TABLE wp_posts, wp_postmeta, wp_options;" 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 6. CACHING ANALYSIS
# ============================================================================
echo "6. CACHING ANALYSIS" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "W3 Total Cache Status:" | tee -a $REPORT_FILE
if [ -d "$WP_PATH/wp-content/plugins/w3-total-cache" ]; then
  echo "  Status: INSTALLED" | tee -a $REPORT_FILE
  if wp plugin is-active w3-total-cache 2>/dev/null; then
    echo "  Status: ACTIVE" | tee -a $REPORT_FILE
    mysql wordpress -e "SELECT option_name, option_value FROM wp_options WHERE option_name LIKE 'w3tc%' LIMIT 5;" 2>/dev/null | tee -a $REPORT_FILE
  else
    echo "  Status: INACTIVE" | tee -a $REPORT_FILE
  fi
else
  echo "  Status: NOT INSTALLED" | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

echo "Autoptimize Status:" | tee -a $REPORT_FILE
if [ -d "$WP_PATH/wp-content/plugins/autoptimize" ]; then
  echo "  Status: INSTALLED" | tee -a $REPORT_FILE
  if wp plugin is-active autoptimize 2>/dev/null; then
    echo "  Status: ACTIVE" | tee -a $REPORT_FILE
  fi
else
  echo "  Status: NOT INSTALLED" | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

echo "Cache directories:" | tee -a $REPORT_FILE
du -sh $WP_PATH/wp-content/cache 2>/dev/null | tee -a $REPORT_FILE
du -sh $WP_PATH/wp-content/w3tc-cache 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 7. ERROR LOGS
# ============================================================================
echo "7. ERROR LOG ANALYSIS (last 50 lines)" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "Apache Error Log (last 20 errors):" | tee -a $REPORT_FILE
tail -100 /var/log/apache2/error.log 2>/dev/null | grep -i "error\|warn" | tail -20 | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "PHP Error Log:" | tee -a $REPORT_FILE
if [ -f /var/log/php*.log ]; then
  tail -20 /var/log/php*.log 2>/dev/null | tee -a $REPORT_FILE
else
  echo "  No PHP error log found" | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

echo "WordPress Debug Log:" | tee -a $REPORT_FILE
if [ -f "$WP_PATH/wp-content/debug.log" ]; then
  tail -30 "$WP_PATH/wp-content/debug.log" | tee -a $REPORT_FILE
else
  echo "  No debug log found" | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 8. SLOW QUERY ANALYSIS
# ============================================================================
echo "8. SLOW QUERY ANALYSIS" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

if [ -f /var/log/mysql/slow.log ]; then
  echo "Slow Query Log Enabled" | tee -a $REPORT_FILE
  mysqldumpslow -s t -t 10 /var/log/mysql/slow.log 2>/dev/null | tee -a $REPORT_FILE
else
  echo "Slow Query Log not found - checking if enabled..." | tee -a $REPORT_FILE
  mysql -e "SHOW VARIABLES LIKE 'slow_query%';" 2>/dev/null | tee -a $REPORT_FILE
fi
echo "" | tee -a $REPORT_FILE

# ============================================================================
# 9. WordPress Configuration
# ============================================================================
echo "9. WORDPRESS CONFIGURATION" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE

echo "WordPress Version:" | tee -a $REPORT_FILE
wp --version 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

echo "Database Stats:" | tee -a $REPORT_FILE
mysql wordpress -e "SELECT COUNT(*) as total_posts FROM wp_posts WHERE post_type='post' AND post_status='publish';" 2>/dev/null | tee -a $REPORT_FILE
mysql wordpress -e "SELECT COUNT(*) as total_postmeta FROM wp_postmeta;" 2>/dev/null | tee -a $REPORT_FILE
mysql wordpress -e "SELECT COUNT(*) as total_options FROM wp_options;" 2>/dev/null | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE

# ============================================================================
# SUMMARY
# ============================================================================
echo "10. KEY FINDINGS SUMMARY" | tee -a $REPORT_FILE
echo "---" | tee -a $REPORT_FILE
echo "Report saved to: $REPORT_FILE" | tee -a $REPORT_FILE
echo "Copy this file to analyze results:" | tee -a $REPORT_FILE
echo "  scp -i /Users/ericsalas/esalas_rsa esalas@100.27.149.231:$REPORT_FILE ./" | tee -a $REPORT_FILE
echo "" | tee -a $REPORT_FILE
echo "=== END OF DIAGNOSTIC REPORT ===" | tee -a $REPORT_FILE

cat $REPORT_FILE
