#!/bin/bash
# ============================================================
#  Graywell Design — Server Performance Benchmark & Tuning
#  Supports: WordPress/LAMP | Bare Ubuntu
#            Auto-detects RAM and scales recommendations
#
#  Usage: sudo bash performance_tune.sh
#  Report: /opt/performance-report.txt
# ============================================================

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colors & Output ─────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
REPORT=/opt/performance-report.txt
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

section() { echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLU}  $1${NC}"; echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; report ""; report "=== $1 ==="; }
ok()      { echo -e "  ${GRN}[OK]${NC}      $1"; }
info()    { echo -e "  ${BLU}[INFO]${NC}    $1"; }
tuned()   { echo -e "  ${GRN}[TUNED]${NC}   $1"; report "[TUNED] $1"; }
manual()  { echo -e "  ${YEL}[MANUAL]${NC}  $1"; report "[MANUAL REVIEW] $1"; }
warn()    { echo -e "  ${YEL}[WARN]${NC}    $1"; report "[WARN] $1"; }
result()  { echo -e "  ${BLU}[RESULT]${NC}  $1"; report "[RESULT] $1"; }
report()  { echo "$*" >> "$REPORT"; }

[ "$EUID" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

# ── Initialize report ────────────────────────────────────────
cat > "$REPORT" <<EOF
Graywell Server Performance Report
Host: $(hostname)
Date: $TIMESTAMP
Kernel: $(uname -r)
========================================
EOF

echo -e "\n${BOLD}Graywell Server Performance Benchmark & Tuning${NC}"
echo -e "Host: $(hostname) | $(date)\n"

# ── Detect environment ───────────────────────────────────────
IS_BITNAMI=false
[ -d /opt/bitnami ] && IS_BITNAMI=true

# RAM detection (in MB)
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
AVAIL_RAM_MB=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
TOTAL_RAM_GB=$(echo "scale=1; $TOTAL_RAM_MB/1024" | bc 2>/dev/null || echo "?")
CPU_CORES=$(nproc)
DISK_ROOT=$(df -P / | tail -1 | awk '{print $6}')

info "RAM: ${TOTAL_RAM_MB}MB total, ${AVAIL_RAM_MB}MB available"
info "CPU cores: $CPU_CORES"
info "Root disk: $DISK_ROOT"
$IS_BITNAMI && info "Stack: Bitnami" || info "Stack: Bare Ubuntu"
report "RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_CORES} cores | Available: ${AVAIL_RAM_MB}MB"

# ── Detect web server ────────────────────────────────────────
WEB_SERVER="none"
APACHE_CONF=""
NGINX_CONF=""
for path in /opt/bitnami/apache/conf/httpd.conf /etc/apache2/apache2.conf; do
  [ -f "$path" ] && { APACHE_CONF="$path"; WEB_SERVER="apache"; break; }
done
for path in /opt/bitnami/nginx/conf/nginx.conf /etc/nginx/nginx.conf; do
  [ -f "$path" ] && { NGINX_CONF="$path"; WEB_SERVER="nginx"; break; }
done
[ -n "$APACHE_CONF" ] && [ -n "$NGINX_CONF" ] && WEB_SERVER="apache"

# ── Detect PHP-FPM config ────────────────────────────────────
PHP_FPM_POOL=""
for path in \
  /opt/bitnami/php/etc/php-fpm.d/www.conf \
  /etc/php/*/fpm/pool.d/www.conf \
  /etc/php-fpm.d/www.conf; do
  [ -f "$path" ] && { PHP_FPM_POOL="$path"; break; }
done
# Glob expansion for versioned paths
if [ -z "$PHP_FPM_POOL" ]; then
  PHP_FPM_POOL=$(ls /etc/php/*/fpm/pool.d/www.conf 2>/dev/null | head -1 || echo "")
fi

# ── Detect MySQL config ──────────────────────────────────────
MYSQL_CONF=""
for path in \
  /opt/bitnami/mariadb/conf/my.cnf \
  /etc/mysql/mysql.conf.d/mysqld.cnf \
  /etc/mysql/mariadb.conf.d/50-server.cnf \
  /etc/my.cnf; do
  [ -f "$path" ] && { MYSQL_CONF="$path"; break; }
done

# ──────────────────────────────────────────
# 1. INSTALL BENCHMARK TOOLS
# ──────────────────────────────────────────
section "1. Installing Benchmark Tools"

if ! command -v sysbench &>/dev/null; then
  apt-get install -y -qq sysbench
  ok "sysbench installed"
else
  ok "sysbench already installed"
fi

if ! command -v bc &>/dev/null; then
  apt-get install -y -qq bc
fi

# ──────────────────────────────────────────
# 2. CPU BENCHMARK
# ──────────────────────────────────────────
section "2. CPU Benchmark"

info "Running CPU benchmark (single-thread)..."
CPU_SINGLE=$(sysbench cpu --cpu-max-prime=20000 --threads=1 run 2>/dev/null \
  | grep "events per second" | awk '{print $NF}')
result "Single-thread: ${CPU_SINGLE:-n/a} events/sec"

if [ "$CPU_CORES" -gt 1 ]; then
  info "Running CPU benchmark (multi-thread, $CPU_CORES cores)..."
  CPU_MULTI=$(sysbench cpu --cpu-max-prime=20000 --threads="$CPU_CORES" run 2>/dev/null \
    | grep "events per second" | awk '{print $NF}')
  result "Multi-thread ($CPU_CORES cores): ${CPU_MULTI:-n/a} events/sec"
fi

# Rating
CPU_SINGLE_INT=${CPU_SINGLE%.*}
if [ "${CPU_SINGLE_INT:-0}" -gt 2000 ]; then
  ok "CPU performance: Good"
elif [ "${CPU_SINGLE_INT:-0}" -gt 800 ]; then
  warn "CPU performance: Moderate — adequate for small WordPress sites"
else
  warn "CPU performance: Low — may struggle under load"
fi

# ──────────────────────────────────────────
# 3. MEMORY BENCHMARK
# ──────────────────────────────────────────
section "3. Memory Benchmark"

info "Running memory bandwidth test..."
MEM_RESULT=$(sysbench memory --memory-block-size=1K --memory-total-size=4G run 2>/dev/null \
  | grep "transferred" | grep -oP '[\d.]+ \w+/sec' | head -1)
result "Memory bandwidth: ${MEM_RESULT:-n/a}"

# ──────────────────────────────────────────
# 4. DISK I/O BENCHMARK
# ──────────────────────────────────────────
section "4. Disk I/O Benchmark"

BENCH_DIR=/tmp/graywell-bench
mkdir -p "$BENCH_DIR"

info "Running disk write test..."
DISK_WRITE=$(dd if=/dev/zero of="$BENCH_DIR/testfile" bs=1M count=256 conv=fdatasync 2>&1 \
  | grep -oP '[\d.]+ \w+/s' | tail -1)
result "Sequential write: ${DISK_WRITE:-n/a}"

info "Running disk read test..."
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
DISK_READ=$(dd if="$BENCH_DIR/testfile" of=/dev/null bs=1M 2>&1 \
  | grep -oP '[\d.]+ \w+/s' | tail -1)
result "Sequential read: ${DISK_READ:-n/a}"

rm -f "$BENCH_DIR/testfile"
rmdir "$BENCH_DIR" 2>/dev/null || true

# ──────────────────────────────────────────
# 5. MYSQL BENCHMARK
# ──────────────────────────────────────────
section "5. MySQL Benchmark"

if command -v mysql &>/dev/null || command -v mysqld &>/dev/null; then
  # Get current MySQL stats
  MYSQL_CONN=$(mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null \
    | grep Threads_connected | awk '{print $2}')
  MYSQL_MAX=$(mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null \
    | grep max_connections | awk '{print $2}')
  MYSQL_BUFFER=$(mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null \
    | grep innodb_buffer_pool_size | awk '{print $2}')
  MYSQL_BUFFER_MB=$(echo "scale=0; ${MYSQL_BUFFER:-0}/1024/1024" | bc 2>/dev/null || echo 0)
  SLOW_QUERIES=$(mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "SHOW STATUS LIKE 'Slow_queries';" 2>/dev/null \
    | grep Slow_queries | awk '{print $2}')

  result "Current connections: ${MYSQL_CONN:-n/a} / ${MYSQL_MAX:-n/a} max"
  result "InnoDB buffer pool: ${MYSQL_BUFFER_MB}MB"
  result "Slow queries: ${SLOW_QUERIES:-n/a}"

  # Quick sysbench MySQL test
  info "Running MySQL benchmark..."

  # Read password from .my.cnf for sysbench
  MYSQL_ROOT_PW=$(awk -F= '/^password/{print $2}' /root/.my.cnf 2>/dev/null | tr -d ' ')
  SYSBENCH_MYSQL_OPTS="--db-driver=mysql --mysql-user=root --mysql-db=sbtest"
  [ -n "$MYSQL_ROOT_PW" ] && SYSBENCH_MYSQL_OPTS="$SYSBENCH_MYSQL_OPTS --mysql-password=${MYSQL_ROOT_PW}"

  mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "CREATE DATABASE IF NOT EXISTS sbtest;" 2>/dev/null || true

  if sysbench oltp_read_only $SYSBENCH_MYSQL_OPTS \
    --tables=1 --table-size=10000 prepare &>/dev/null; then

    MYSQL_BENCH=$(sysbench oltp_read_only $SYSBENCH_MYSQL_OPTS \
      --tables=1 --table-size=10000 --threads=4 --time=30 \
      run 2>/dev/null | grep "queries:" | awk '{print $3}' | tr -d '(')

    sysbench oltp_read_only $SYSBENCH_MYSQL_OPTS \
      --tables=1 cleanup &>/dev/null || true

    result "MySQL queries/sec: ${MYSQL_BENCH:-n/a}"
  else
    warn "MySQL benchmark failed — check /root/.my.cnf credentials"
  fi

  mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "DROP DATABASE IF EXISTS sbtest;" 2>/dev/null || true
else
  info "MySQL not installed — skipping"
fi

# ──────────────────────────────────────────
# 6. PHP BENCHMARK
# ──────────────────────────────────────────
section "6. PHP Benchmark"

if command -v php &>/dev/null; then
  PHP_VER=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
  result "PHP version: $PHP_VER"

  # Simple PHP benchmark
  PHP_BENCH=$(php -r '
    $start = microtime(true);
    $x = 0;
    for ($i = 0; $i < 1000000; $i++) { $x += sqrt($i); }
    $end = microtime(true);
    printf("%.3f", $end - $start);
  ' 2>/dev/null)
  result "PHP 1M sqrt operations: ${PHP_BENCH:-n/a}s"

  # OPcache status
  OPCACHE=$(php -r 'echo ini_get("opcache.enable");' 2>/dev/null)
  [ "$OPCACHE" = "1" ] && ok "OPcache enabled" || warn "OPcache disabled — significant performance impact"

  # PHP memory limit
  PHP_MEM=$(php -r 'echo ini_get("memory_limit");' 2>/dev/null)
  result "PHP memory_limit: $PHP_MEM"
else
  info "PHP not installed — skipping"
fi

# ──────────────────────────────────────────
# 7. HTTP RESPONSE BENCHMARK
# ──────────────────────────────────────────
section "7. HTTP Response Benchmark"

if ss -tlnp 2>/dev/null | grep -q ":80 \|:443 "; then
  info "Testing HTTP response times (10 requests to localhost)..."

  TOTAL_MS=0
  COUNT=0
  for i in $(seq 1 10); do
    MS=$(curl -s -o /dev/null -w "%{time_total}" \
      --max-time 5 http://localhost/ 2>/dev/null)
    if [ -n "$MS" ]; then
      MS_INT=$(echo "$MS * 1000" | bc 2>/dev/null | cut -d. -f1)
      TOTAL_MS=$((TOTAL_MS + MS_INT))
      COUNT=$((COUNT + 1))
    fi
  done

  if [ "$COUNT" -gt 0 ]; then
    AVG_MS=$((TOTAL_MS / COUNT))
    result "Average HTTP response: ${AVG_MS}ms"
    [ "$AVG_MS" -lt 200 ]  && ok "Response time: Excellent (<200ms)"
    [ "$AVG_MS" -ge 200 ] && [ "$AVG_MS" -lt 500 ] && warn "Response time: Moderate (${AVG_MS}ms) — consider caching"
    [ "$AVG_MS" -ge 500 ] && warn "Response time: Slow (${AVG_MS}ms) — tuning recommended"
  fi
else
  info "No web server on port 80/443 — skipping HTTP benchmark"
fi

# ──────────────────────────────────────────
# 8. CALCULATE OPTIMAL SETTINGS
# ──────────────────────────────────────────
section "8. Calculating Optimal Settings"

# MySQL InnoDB buffer pool — 50-70% of RAM for dedicated DB servers
# Use 25% for shared WordPress servers to leave room for PHP/Apache
if [ "$TOTAL_RAM_MB" -le 1024 ]; then
  OPTIMAL_BUFFER_MB=128
  OPTIMAL_MAX_CONN=50
  OPTIMAL_FPM_CHILDREN=5
  OPTIMAL_FPM_MIN=2
  OPTIMAL_FPM_MAX_REQ=200
elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
  OPTIMAL_BUFFER_MB=384
  OPTIMAL_MAX_CONN=100
  OPTIMAL_FPM_CHILDREN=10
  OPTIMAL_FPM_MIN=3
  OPTIMAL_FPM_MAX_REQ=500
elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
  OPTIMAL_BUFFER_MB=768
  OPTIMAL_MAX_CONN=150
  OPTIMAL_FPM_CHILDREN=20
  OPTIMAL_FPM_MIN=5
  OPTIMAL_FPM_MAX_REQ=500
else
  OPTIMAL_BUFFER_MB=2048
  OPTIMAL_MAX_CONN=200
  OPTIMAL_FPM_CHILDREN=40
  OPTIMAL_FPM_MIN=10
  OPTIMAL_FPM_MAX_REQ=1000
fi

info "Target settings for ${TOTAL_RAM_MB}MB RAM server:"
info "  InnoDB buffer pool: ${OPTIMAL_BUFFER_MB}MB"
info "  MySQL max connections: ${OPTIMAL_MAX_CONN}"
info "  PHP-FPM max children: ${OPTIMAL_FPM_CHILDREN}"

# ──────────────────────────────────────────
# 9. AUTO-TUNE: KERNEL / OS
# ──────────────────────────────────────────
section "9. Auto-Tune: Kernel & OS"

SYSCTL_CONF=/etc/sysctl.d/99-graywell-tuning.conf
SYSCTL_CHANGED=false

apply_sysctl() {
  local key="$1" value="$2" desc="$3"
  current=$(sysctl -n "$key" 2>/dev/null || echo "unknown")
  if [ "$current" = "$value" ]; then
    ok "$desc already optimal ($key=$value)"
  else
    echo "$key = $value" >> "$SYSCTL_CONF"
    tuned "$desc: $key $current → $value"
    SYSCTL_CHANGED=true
  fi
}

# Start fresh sysctl config
cat > "$SYSCTL_CONF" <<'EOF'
# Graywell server tuning
EOF

apply_sysctl "vm.swappiness"             "10"      "Reduce swap usage (better RAM utilization)"
apply_sysctl "vm.dirty_ratio"            "15"      "Disk write buffering"
apply_sysctl "vm.dirty_background_ratio" "5"       "Background disk flush threshold"
apply_sysctl "net.core.somaxconn"        "65535"   "Max socket connections"
apply_sysctl "net.ipv4.tcp_max_syn_backlog" "65535" "TCP SYN backlog"
apply_sysctl "fs.file-max"              "500000"   "Max open file descriptors"

if $SYSCTL_CHANGED; then
  sysctl -p "$SYSCTL_CONF" &>/dev/null && tuned "Kernel parameters applied" \
    || warn "Some kernel parameters could not be applied"
else
  ok "Kernel parameters already optimal"
fi

# Increase system file descriptor limits
LIMITS_CONF=/etc/security/limits.d/99-graywell.conf
if [ ! -f "$LIMITS_CONF" ]; then
  cat > "$LIMITS_CONF" <<'EOF'
# Graywell — increase file descriptor limits
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
  tuned "File descriptor limits increased to 65535"
else
  ok "File descriptor limits already configured"
fi

# ──────────────────────────────────────────
# 10. AUTO-TUNE: MYSQL
# ──────────────────────────────────────────
section "10. Auto-Tune: MySQL"

if (command -v mysql &>/dev/null || command -v mysqld &>/dev/null) && [ -n "$MYSQL_CONF" ]; then
  info "MySQL config: $MYSQL_CONF"

  # Check if we've already added our tuning block
  if grep -q "# Graywell tuning" "$MYSQL_CONF" 2>/dev/null; then
    # Update existing values
    sed -i "s/^innodb_buffer_pool_size.*/innodb_buffer_pool_size = ${OPTIMAL_BUFFER_MB}M/" "$MYSQL_CONF"
    sed -i "s/^max_connections.*/max_connections = ${OPTIMAL_MAX_CONN}/" "$MYSQL_CONF"
    tuned "MySQL settings updated in existing tuning block"
  else
    # Append tuning block
    cat >> "$MYSQL_CONF" <<EOF

# Graywell tuning — auto-generated $(date '+%Y-%m-%d')
[mysqld]
innodb_buffer_pool_size         = ${OPTIMAL_BUFFER_MB}M
innodb_log_file_size            = 64M
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT
max_connections                 = ${OPTIMAL_MAX_CONN}
thread_cache_size               = 8
table_open_cache                = 400
tmp_table_size                  = 32M
max_heap_table_size             = 32M
slow_query_log                  = 1
slow_query_log_file             = /var/log/mysql/slow.log
long_query_time                 = 2
EOF
    tuned "MySQL tuning block added (buffer: ${OPTIMAL_BUFFER_MB}MB, max_conn: ${OPTIMAL_MAX_CONN})"
  fi

  # Enable slow query log directory
  mkdir -p /var/log/mysql
  chown mysql:mysql /var/log/mysql 2>/dev/null || true

  # Flag manual items
  manual "MySQL query_cache — deprecated in MySQL 8, skip if using MySQL 8+"
  manual "MySQL max_allowed_packet — increase to 64M if importing large databases"
  manual "Restart MySQL to apply buffer pool changes: systemctl restart mysql"

elif [ -n "$MYSQL_CONF" ]; then
  warn "MySQL config found but MySQL not running — skipping MySQL tuning"
else
  warn "MySQL config file not found — skipping MySQL tuning"
  manual "Find your MySQL config with: find /etc /opt -name 'my.cnf' -o -name 'mysqld.cnf' 2>/dev/null"
fi

# ──────────────────────────────────────────
# 11. AUTO-TUNE: PHP-FPM
# ──────────────────────────────────────────
section "11. Auto-Tune: PHP-FPM"

if [ -n "$PHP_FPM_POOL" ]; then
  info "PHP-FPM pool config: $PHP_FPM_POOL"

  # Backup original
  cp "$PHP_FPM_POOL" "${PHP_FPM_POOL}.bak.$(date +%Y%m%d)" 2>/dev/null || true

  # Update pm settings
  sed -i "s/^pm\.max_children\s*=.*/pm.max_children = ${OPTIMAL_FPM_CHILDREN}/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.start_servers\s*=.*/pm.start_servers = ${OPTIMAL_FPM_MIN}/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.min_spare_servers\s*=.*/pm.min_spare_servers = ${OPTIMAL_FPM_MIN}/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.max_spare_servers\s*=.*/pm.max_spare_servers = $((OPTIMAL_FPM_CHILDREN / 2))/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.max_requests\s*=.*/pm.max_requests = ${OPTIMAL_FPM_MAX_REQ}/" "$PHP_FPM_POOL"

  # Enable status page if not already (needed for watchdog)
  if ! grep -q "^pm.status_path" "$PHP_FPM_POOL" 2>/dev/null; then
    echo "pm.status_path = /fpm-status" >> "$PHP_FPM_POOL"
    tuned "PHP-FPM status page enabled at /fpm-status"
  fi

  tuned "PHP-FPM pool tuned (max_children: ${OPTIMAL_FPM_CHILDREN}, max_requests: ${OPTIMAL_FPM_MAX_REQ})"
  manual "Restart PHP-FPM to apply: systemctl restart php*-fpm"

else
  warn "PHP-FPM pool config not found — skipping PHP-FPM tuning"
  manual "Find PHP-FPM pool config: find /etc/php /opt/bitnami -name 'www.conf' 2>/dev/null"
fi

# ──────────────────────────────────────────
# 12. AUTO-TUNE: PHP OPCACHE
# ──────────────────────────────────────────
section "12. Auto-Tune: PHP OPcache"

PHP_INI_DIR=$(php --ini 2>/dev/null | grep "Scan for" | awk '{print $NF}')
OPCACHE_INI=""
[ -n "$PHP_INI_DIR" ] && OPCACHE_INI="$PHP_INI_DIR/99-graywell-opcache.ini"

if command -v php &>/dev/null && [ -n "$OPCACHE_INI" ]; then
  cat > "$OPCACHE_INI" <<EOF
; Graywell OPcache tuning — $(date '+%Y-%m-%d')
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.enable_cli=0
EOF
  tuned "OPcache tuning applied ($OPCACHE_INI)"
  manual "Restart PHP-FPM to activate OPcache changes: systemctl restart php*-fpm"
else
  warn "Could not detect PHP ini directory — skipping OPcache tuning"
  manual "Manually add OPcache settings to your php.ini"
fi

# ──────────────────────────────────────────
# 13. AUTO-TUNE: APACHE
# ──────────────────────────────────────────
section "13. Auto-Tune: Web Server"

if [ "$WEB_SERVER" = "apache" ] && [ -n "$APACHE_CONF" ]; then
  info "Apache config: $APACHE_CONF"

  # Enable mod_expires and mod_deflate if available (bare Ubuntu only)
  if ! $IS_BITNAMI; then
    a2enmod expires deflate headers 2>/dev/null && tuned "Apache modules enabled: expires, deflate, headers" || true
  fi

  # Check KeepAlive
  if grep -q "^KeepAlive Off" "$APACHE_CONF" 2>/dev/null; then
    sed -i 's/^KeepAlive Off/KeepAlive On/' "$APACHE_CONF"
    tuned "KeepAlive enabled"
  elif grep -q "^KeepAlive On" "$APACHE_CONF" 2>/dev/null; then
    ok "KeepAlive already enabled"
  else
    echo "KeepAlive On" >> "$APACHE_CONF"
    tuned "KeepAlive enabled"
  fi

  # MaxRequestWorkers — flag only, too risky to auto-change
  CURRENT_MRW=$(grep -iE "^MaxRequestWorkers|^MaxClients" "$APACHE_CONF" 2>/dev/null | awk '{print $2}' | head -1)
  OPTIMAL_MRW=$(( TOTAL_RAM_MB / 50 ))  # rough estimate: ~50MB per worker
  [ "$OPTIMAL_MRW" -lt 10 ] && OPTIMAL_MRW=10
  [ "$OPTIMAL_MRW" -gt 150 ] && OPTIMAL_MRW=150

  if [ -n "$CURRENT_MRW" ]; then
    result "Current MaxRequestWorkers: $CURRENT_MRW (suggested: $OPTIMAL_MRW)"
    manual "Consider setting MaxRequestWorkers to ~${OPTIMAL_MRW} based on ${TOTAL_RAM_MB}MB RAM"
  else
    manual "MaxRequestWorkers not set — consider adding: MaxRequestWorkers ${OPTIMAL_MRW}"
  fi

  manual "Restart Apache to apply changes: $($IS_BITNAMI && echo '/opt/bitnami/ctlscript.sh restart apache' || echo 'systemctl restart apache2')"

elif [ "$WEB_SERVER" = "nginx" ] && [ -n "$NGINX_CONF" ]; then
  info "Nginx config: $NGINX_CONF"

  # worker_processes — set to auto if not already
  if grep -q "worker_processes" "$NGINX_CONF" 2>/dev/null; then
    sed -i 's/^worker_processes.*/worker_processes auto;/' "$NGINX_CONF"
    tuned "Nginx worker_processes set to auto"
  fi

  # worker_connections
  if grep -q "worker_connections" "$NGINX_CONF" 2>/dev/null; then
    sed -i 's/worker_connections.*/worker_connections 1024;/' "$NGINX_CONF"
    tuned "Nginx worker_connections set to 1024"
  fi

  manual "Restart Nginx: $($IS_BITNAMI && echo '/opt/bitnami/ctlscript.sh restart nginx' || echo 'systemctl restart nginx')"
else
  info "No web server detected — skipping web server tuning"
fi

# ──────────────────────────────────────────
# 14. SWAP CHECK
# ──────────────────────────────────────────
section "14. Swap"

SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')
if [ "${SWAP_TOTAL:-0}" -eq 0 ]; then
  warn "No swap configured"
  if [ "$TOTAL_RAM_MB" -le 2048 ]; then
    manual "Add swap (recommended for <2GB RAM servers): bash add_swap.sh"
  else
    info "Swap not critical with ${TOTAL_RAM_MB}MB RAM but still recommended"
  fi
else
  ok "Swap configured: ${SWAP_TOTAL}MB"
  SWAP_USED=$(free -m | grep Swap | awk '{print $3}')
  result "Swap used: ${SWAP_USED}MB / ${SWAP_TOTAL}MB"
  [ "${SWAP_USED:-0}" -gt $((SWAP_TOTAL / 2)) ] && \
    warn "High swap usage — server may be memory-constrained"
fi

# ──────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────
section "Summary"

TUNED_COUNT=$(grep -c "\[TUNED\]" "$REPORT" 2>/dev/null || echo 0)
MANUAL_COUNT=$(grep -c "\[MANUAL REVIEW\]" "$REPORT" 2>/dev/null || echo 0)
WARN_COUNT=$(grep -c "\[WARN\]" "$REPORT" 2>/dev/null || echo 0)

echo -e "\n  ${GRN}Settings auto-tuned:${NC}      $TUNED_COUNT"
echo -e "  ${YEL}Manual review needed:${NC}     $MANUAL_COUNT"
echo -e "  ${YEL}Warnings:${NC}                 $WARN_COUNT"

echo ""
echo -e "${BOLD}Restart these services to apply all changes:${NC}"
command -v mysql &>/dev/null    && echo "  sudo systemctl restart mysql"
[ -n "$PHP_FPM_POOL" ]          && echo "  sudo systemctl restart php*-fpm"
[ "$WEB_SERVER" = "apache" ]    && { $IS_BITNAMI \
  && echo "  sudo /opt/bitnami/ctlscript.sh restart apache" \
  || echo "  sudo systemctl restart apache2"; }
[ "$WEB_SERVER" = "nginx" ]     && echo "  sudo systemctl restart nginx"

echo ""
echo -e "${BOLD}Manual review items:${NC}"
grep "\[MANUAL REVIEW\]" "$REPORT" | sed 's/\[MANUAL REVIEW\] /  - /'

echo ""
echo -e "Full report saved to: ${BOLD}$REPORT${NC}"
report ""
report "Completed: $(date)"