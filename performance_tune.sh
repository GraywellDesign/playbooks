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
{ [ -d /opt/bitnami ] || [ -d /bitnami ]; } && IS_BITNAMI=true

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
for path in \
  /bitnami/apache2/conf/httpd.conf \
  /opt/bitnami/apache/conf/httpd.conf \
  /etc/apache2/apache2.conf \
  /etc/httpd/conf/httpd.conf; do
  [ -f "$path" ] && { APACHE_CONF="$path"; WEB_SERVER="apache"; break; }
done
for path in \
  /bitnami/nginx/conf/nginx.conf \
  /opt/bitnami/nginx/conf/nginx.conf \
  /etc/nginx/nginx.conf; do
  [ -f "$path" ] && { NGINX_CONF="$path"; WEB_SERVER="nginx"; break; }
done
[ -n "$APACHE_CONF" ] && [ -n "$NGINX_CONF" ] && WEB_SERVER="apache"

# ── Detect PHP-FPM config ────────────────────────────────────
PHP_FPM_POOL=""
for path in \
  /bitnami/php/etc/php-fpm.d/www.conf \
  /opt/bitnami/php/etc/php-fpm.d/www.conf \
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
  /bitnami/mariadb/conf/my.cnf \
  /opt/bitnami/mariadb/conf/my.cnf \
  /etc/mysql/mysql.conf.d/mysqld.cnf \
  /etc/mysql/mariadb.conf.d/50-server.cnf \
  /etc/my.cnf; do
  [ -f "$path" ] && { MYSQL_CONF="$path"; break; }
done

# ── Detect Apache MPM config (auto-finds correct location) ────
find_apache_mpm_conf() {
  local apache_root="" mpm_conf=""

  # Determine Apache root
  if [ -d /opt/bitnami/apache ]; then
    apache_root="/opt/bitnami/apache"
  elif [ -d /bitnami/apache2 ]; then
    apache_root="/bitnami/apache2"
  else
    apache_root="/etc/apache2"
  fi

  # Priority 1: mods-enabled (modern Debian/Ubuntu - most likely to be active)
  if [ -d "$apache_root/mods-enabled" ]; then
    for mpm in "$apache_root/mods-enabled"/mpm_*.conf; do
      [ -f "$mpm" ] && { mpm_conf="$mpm"; break; }
    done
  fi

  # Priority 2: mods-available (fallback for Debian/Ubuntu)
  if [ -z "$mpm_conf" ] && [ -d "$apache_root/mods-available" ]; then
    for mpm in "$apache_root/mods-available"/mpm_*.conf; do
      [ -f "$mpm" ] && { mpm_conf="$mpm"; break; }
    done
  fi

  # Priority 3: RHEL/CentOS style
  if [ -z "$mpm_conf" ] && [ -d "/etc/httpd/conf.modules.d" ]; then
    for mpm in /etc/httpd/conf.modules.d/*mpm*.conf; do
      [ -f "$mpm" ] && { mpm_conf="$mpm"; break; }
    done
  fi

  # Priority 4: Bitnami main config
  if [ -z "$mpm_conf" ] && [ -f "$apache_root/conf/httpd.conf" ]; then
    mpm_conf="$apache_root/conf/httpd.conf"
  fi

  # Priority 5: Create new in appropriate directory
  if [ -z "$mpm_conf" ]; then
    if [ -d "$apache_root/mods-available" ]; then
      mpm_conf="$apache_root/mods-available/graywell-mpm.conf"
    elif [ -d "$apache_root/conf.d" ]; then
      mpm_conf="$apache_root/conf.d/graywell-mpm.conf"
    elif [ -d "/etc/apache2/conf.d" ]; then
      mpm_conf="/etc/apache2/conf.d/graywell-mpm.conf"
    else
      mpm_conf="$apache_root/graywell-mpm.conf"
    fi
  fi

  echo "$mpm_conf"
}

APACHE_MPM_CONF=$(find_apache_mpm_conf)

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
section "8. Calculating Recommended Settings"

# Base formulas (industry standard)
if [ "$TOTAL_RAM_MB" -le 1024 ]; then
  OPTIMAL_BUFFER_MB=128;  OPTIMAL_MAX_CONN=50;  OPTIMAL_FPM_CHILDREN=5;  OPTIMAL_FPM_MIN=2; OPTIMAL_FPM_MAX_REQ=200
elif [ "$TOTAL_RAM_MB" -le 2048 ]; then
  OPTIMAL_BUFFER_MB=384;  OPTIMAL_MAX_CONN=100; OPTIMAL_FPM_CHILDREN=10; OPTIMAL_FPM_MIN=3; OPTIMAL_FPM_MAX_REQ=500
elif [ "$TOTAL_RAM_MB" -le 4096 ]; then
  OPTIMAL_BUFFER_MB=768;  OPTIMAL_MAX_CONN=150; OPTIMAL_FPM_CHILDREN=20; OPTIMAL_FPM_MIN=5; OPTIMAL_FPM_MAX_REQ=500
else
  OPTIMAL_BUFFER_MB=2048; OPTIMAL_MAX_CONN=200; OPTIMAL_FPM_CHILDREN=40; OPTIMAL_FPM_MIN=10; OPTIMAL_FPM_MAX_REQ=1000
fi

OPTIMAL_MRW=$(( TOTAL_RAM_MB / 50 ))
[ "$OPTIMAL_MRW" -lt 10 ]  && OPTIMAL_MRW=10
[ "$OPTIMAL_MRW" -gt 150 ] && OPTIMAL_MRW=150

# ── Smart Safety Guards ──────────────────────
info "Applying safety guards and context-aware adjustments..."

# Guard 1: Buffer pool should never exceed 50% of total RAM
BUFFER_POOL_MAX=$(( TOTAL_RAM_MB / 2 ))
if [ "$OPTIMAL_BUFFER_MB" -gt "$BUFFER_POOL_MAX" ]; then
  warn "Buffer pool would exceed 50% of RAM — capping at ${BUFFER_POOL_MAX}MB"
  OPTIMAL_BUFFER_MB=$BUFFER_POOL_MAX
fi

# Guard 2: Check if swap is being actively used (sign of memory pressure)
SWAP_USED=$(free -m 2>/dev/null | grep Swap | awk '{print $3}')
if [ "${SWAP_USED:-0}" -gt 100 ]; then
  warn "Swap usage detected (${SWAP_USED}MB) — reducing worker processes to prevent thrashing"
  OPTIMAL_MRW=$(( OPTIMAL_MRW / 2 ))
  [ "$OPTIMAL_MRW" -lt 5 ] && OPTIMAL_MRW=5
  OPTIMAL_FPM_CHILDREN=$(( OPTIMAL_FPM_CHILDREN / 2 ))
  [ "$OPTIMAL_FPM_CHILDREN" -lt 2 ] && OPTIMAL_FPM_CHILDREN=2
  info "Adjusted for swap pressure: MRW=${OPTIMAL_MRW}, FPM=${OPTIMAL_FPM_CHILDREN}"
fi

# Guard 3: Check for high slow queries (sign of undersized buffer pool)
if command -v mysql &>/dev/null && [ -n "$MYSQL_CONF" ]; then
  SLOW_QUERY_COUNT=$(mysql --defaults-file=/root/.my.cnf --connect-timeout=3 \
    -e "SHOW STATUS LIKE 'Slow_queries';" 2>/dev/null | grep Slow_queries | awk '{print $2}' || echo "0")

  if [ "${SLOW_QUERY_COUNT:-0}" -gt 10 ]; then
    warn "High slow query count (${SLOW_QUERY_COUNT}) — increasing buffer pool"
    OPTIMAL_BUFFER_MB=$(( OPTIMAL_BUFFER_MB * 3 / 2 ))  # Increase by 50%
    # Still respect 50% RAM ceiling
    if [ "$OPTIMAL_BUFFER_MB" -gt "$BUFFER_POOL_MAX" ]; then
      OPTIMAL_BUFFER_MB=$BUFFER_POOL_MAX
    fi
    info "Adjusted buffer pool to ${OPTIMAL_BUFFER_MB}MB for slow query optimization"
  fi
fi

# Guard 4: If server is under 1GB, be more conservative
if [ "$TOTAL_RAM_MB" -lt 1024 ]; then
  warn "Low RAM server (<1GB) — using conservative settings to prevent OOM"
  OPTIMAL_MRW=$(( OPTIMAL_MRW / 2 ))
  [ "$OPTIMAL_MRW" -lt 3 ] && OPTIMAL_MRW=3
  OPTIMAL_FPM_CHILDREN=$(( OPTIMAL_FPM_CHILDREN / 2 ))
  [ "$OPTIMAL_FPM_CHILDREN" -lt 1 ] && OPTIMAL_FPM_CHILDREN=1
fi

# Guard 5: Warn if available RAM is significantly less than total (bloat)
RAM_USED=$(( TOTAL_RAM_MB - AVAIL_RAM_MB ))
RAM_USAGE_PCT=$(( RAM_USED * 100 / TOTAL_RAM_MB ))
if [ "$RAM_USAGE_PCT" -gt 80 ]; then
  warn "Memory usage is high (${RAM_USAGE_PCT}%) — current bloat may limit optimization gains"
  info "Consider: killing unused processes, upgrading RAM, or running on smaller server"
fi

# Gather current values for comparison
CUR_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
CUR_SOMAXCONN=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "?")
CUR_FILEMAX=$(sysctl -n fs.file-max 2>/dev/null || echo "?")

# MySQL: Get actual running values (from SHOW VARIABLES, not config file)
# This is more reliable since MySQL might have defaults applied
CUR_BUFFER_MB=$(mysql --defaults-file=/root/.my.cnf -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" --skip-column-names 2>/dev/null | awk '{printf "%dMB", $2/1024/1024}' || echo "?")
CUR_MAX_CONN=$(mysql --defaults-file=/root/.my.cnf -e "SHOW VARIABLES LIKE 'max_connections';" --skip-column-names 2>/dev/null | awk '{print $2}' || echo "?")

# Convert to numbers for comparison (remove "MB" suffix)
CUR_BUFFER_NUM=$(echo "$CUR_BUFFER_MB" | sed 's/MB//')
CUR_MAX_CONN_NUM="$CUR_MAX_CONN"

# PHP-FPM
CUR_FPM_CHILDREN=$(grep -E "^pm\.max_children" "$PHP_FPM_POOL" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "?")

# Apache: Check in the actual MPM config file where it was written, not the main config
# Search with flexible whitespace handling
CUR_MRW=$(grep -iE "MaxRequestWorkers|MaxClients" "$APACHE_MPM_CONF" 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "")
[ -z "$CUR_MRW" ] && CUR_MRW="not set"

CUR_OPCACHE=$(php -r 'echo ini_get("opcache.enable");' 2>/dev/null || echo "?")
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

# PHP INI dir for opcache
PHP_INI_DIR=$(php --ini 2>/dev/null | grep "Scan for" | awk '{print $NF}')
OPCACHE_INI=""
[ -n "$PHP_INI_DIR" ] && OPCACHE_INI="$PHP_INI_DIR/99-graywell-opcache.ini"

# ──────────────────────────────────────────
# 9. SHOW CHANGES SUMMARY & GET APPROVAL
# ──────────────────────────────────────────
section "9. Recommended Changes"

echo ""
printf "  %-35s %-15s %-15s %s\n" "Setting" "Current" "Recommended" "Impact"
printf "  %-35s %-15s %-15s %s\n" "-------" "-------" "-----------" "------"

# Build change list
declare -a CHANGE_KEYS CHANGE_DESCS CHANGE_CURRENTS CHANGE_RECS CHANGE_IMPACTS CHANGE_APPLY

idx=0

# Kernel: swappiness
if [ "$CUR_SWAPPINESS" != "10" ]; then
  CHANGE_KEYS[$idx]="kernel_swappiness"
  CHANGE_DESCS[$idx]="vm.swappiness"
  CHANGE_CURRENTS[$idx]="$CUR_SWAPPINESS"
  CHANGE_RECS[$idx]="10"
  CHANGE_IMPACTS[$idx]="Less swap thrashing, better RAM use"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "vm.swappiness" "$CUR_SWAPPINESS" "10" "Less swap thrashing"
  idx=$((idx+1))
fi

# Kernel: somaxconn
if [ "$CUR_SOMAXCONN" != "65535" ]; then
  CHANGE_KEYS[$idx]="kernel_somaxconn"
  CHANGE_DESCS[$idx]="net.core.somaxconn"
  CHANGE_CURRENTS[$idx]="$CUR_SOMAXCONN"
  CHANGE_RECS[$idx]="65535"
  CHANGE_IMPACTS[$idx]="More concurrent connections"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "net.core.somaxconn" "$CUR_SOMAXCONN" "65535" "More concurrent connections"
  idx=$((idx+1))
fi

# Kernel: file-max
if [ "$CUR_FILEMAX" != "500000" ]; then
  CHANGE_KEYS[$idx]="kernel_filemax"
  CHANGE_DESCS[$idx]="fs.file-max"
  CHANGE_CURRENTS[$idx]="$CUR_FILEMAX"
  CHANGE_RECS[$idx]="500000"
  CHANGE_IMPACTS[$idx]="More open file handles"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "fs.file-max" "$CUR_FILEMAX" "500000" "More open file handles"
  idx=$((idx+1))
fi

# MySQL: buffer pool (only recommend if different)
if (command -v mysql &>/dev/null) && [ -n "$MYSQL_CONF" ]; then
  # Compare numeric values for buffer pool (strip MB suffix)
  if [ "$CUR_BUFFER_NUM" != "$OPTIMAL_BUFFER_MB" ]; then
    CHANGE_KEYS[$idx]="mysql_buffer"
    CHANGE_DESCS[$idx]="innodb_buffer_pool_size"
    CHANGE_CURRENTS[$idx]="${CUR_BUFFER_MB}"
    CHANGE_RECS[$idx]="${OPTIMAL_BUFFER_MB}MB"
    CHANGE_IMPACTS[$idx]="Faster DB queries, less disk I/O"
    CHANGE_APPLY[$idx]=true
    printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "innodb_buffer_pool_size" "$CUR_BUFFER_MB" "${OPTIMAL_BUFFER_MB}MB" "Faster DB queries"
    idx=$((idx+1))
  fi

  # Compare max_connections
  if [ "$CUR_MAX_CONN_NUM" != "$OPTIMAL_MAX_CONN" ]; then
    CHANGE_KEYS[$idx]="mysql_maxconn"
    CHANGE_DESCS[$idx]="max_connections"
    CHANGE_CURRENTS[$idx]="${CUR_MAX_CONN}"
    CHANGE_RECS[$idx]="${OPTIMAL_MAX_CONN}"
    CHANGE_IMPACTS[$idx]="Right-size connection pool"
    CHANGE_APPLY[$idx]=true
    printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "max_connections" "$CUR_MAX_CONN" "$OPTIMAL_MAX_CONN" "Right-size connection pool"
    idx=$((idx+1))
  fi
fi

# PHP-FPM: max_children
if [ -n "$PHP_FPM_POOL" ]; then
  CHANGE_KEYS[$idx]="fpm_children"
  CHANGE_DESCS[$idx]="pm.max_children"
  CHANGE_CURRENTS[$idx]="${CUR_FPM_CHILDREN}"
  CHANGE_RECS[$idx]="${OPTIMAL_FPM_CHILDREN}"
  CHANGE_IMPACTS[$idx]="Optimal PHP worker count for RAM"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "pm.max_children (PHP-FPM)" "$CUR_FPM_CHILDREN" "$OPTIMAL_FPM_CHILDREN" "Optimal for ${TOTAL_RAM_MB}MB RAM"
  idx=$((idx+1))
fi

# PHP OPcache
if command -v php &>/dev/null && [ -n "$OPCACHE_INI" ] && [ ! -f "$OPCACHE_INI" ]; then
  CHANGE_KEYS[$idx]="opcache"
  CHANGE_DESCS[$idx]="OPcache tuning"
  CHANGE_CURRENTS[$idx]="default"
  CHANGE_RECS[$idx]="optimized"
  CHANGE_IMPACTS[$idx]="Faster PHP execution"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "OPcache settings" "default" "optimized" "Faster PHP execution"
  idx=$((idx+1))
fi

# Apache MaxRequestWorkers (only recommend if different)
if [ "$WEB_SERVER" = "apache" ] && [ -n "$APACHE_CONF" ] && [ "$CUR_MRW" != "$OPTIMAL_MRW" ]; then
  CHANGE_KEYS[$idx]="apache_mrw"
  CHANGE_DESCS[$idx]="MaxRequestWorkers"
  CHANGE_CURRENTS[$idx]="${CUR_MRW}"
  CHANGE_RECS[$idx]="${OPTIMAL_MRW}"
  CHANGE_IMPACTS[$idx]="Reduce Apache memory usage"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "Apache MaxRequestWorkers" "$CUR_MRW" "$OPTIMAL_MRW" "Reduce memory usage"
  idx=$((idx+1))
fi

# Swap
if [ "${SWAP_TOTAL:-0}" -eq 0 ] && [ "$TOTAL_RAM_MB" -le 2048 ]; then
  CHANGE_KEYS[$idx]="swap"
  CHANGE_DESCS[$idx]="Swap space"
  CHANGE_CURRENTS[$idx]="none"
  CHANGE_RECS[$idx]="1GB"
  CHANGE_IMPACTS[$idx]="Prevent OOM crashes on low RAM"
  CHANGE_APPLY[$idx]=true
  printf "  ${YEL}%-35s${NC} %-15s %-15s %s\n" "Swap space" "none" "1GB" "Prevent OOM crashes"
  idx=$((idx+1))
fi

TOTAL_CHANGES=$idx

if [ "$TOTAL_CHANGES" -eq 0 ]; then
  echo ""
  ok "All settings are already optimal — nothing to change!"
  echo ""
  echo -e "Full report saved to: ${BOLD}$REPORT${NC}"
  report "Completed: $(date)"
  exit 0
fi

echo ""
echo -e "${BOLD}${TOTAL_CHANGES} changes recommended for this ${TOTAL_RAM_MB}MB server.${NC}"
echo ""
echo -e "  ${GRN}[A]${NC} Apply all recommended changes"
echo -e "  ${YEL}[P]${NC} Pick individually"
echo -e "  ${RED}[S]${NC} Skip all — report only"
echo ""
read -rp "  Choice [A/P/S]: " APPROVAL_MODE
APPROVAL_MODE=$(echo "$APPROVAL_MODE" | tr '[:lower:]' '[:upper:]')

if [ "$APPROVAL_MODE" = "P" ]; then
  echo ""
  for i in $(seq 0 $((TOTAL_CHANGES-1))); do
    printf "  Apply ${YEL}%-30s${NC} %s → %s ? [y/N]: " \
      "${CHANGE_DESCS[$i]}" "${CHANGE_CURRENTS[$i]}" "${CHANGE_RECS[$i]}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || CHANGE_APPLY[$i]=false
  done
elif [ "$APPROVAL_MODE" = "S" ]; then
  for i in $(seq 0 $((TOTAL_CHANGES-1))); do
    CHANGE_APPLY[$i]=false
  done
fi

# ──────────────────────────────────────────
# 10. APPLY APPROVED CHANGES
# ──────────────────────────────────────────
section "10. Applying Changes"

SYSCTL_CONF=/etc/sysctl.d/99-graywell-tuning.conf
SYSCTL_CHANGED=false
NEED_MYSQL_RESTART=false
NEED_FPM_RESTART=false
NEED_APACHE_RESTART=false

# Helper to check if a change is approved
is_approved() {
  local key="$1"
  for i in $(seq 0 $((TOTAL_CHANGES-1))); do
    if [ "${CHANGE_KEYS[$i]}" = "$key" ] && [ "${CHANGE_APPLY[$i]}" = "true" ]; then
      return 0
    fi
  done
  return 1
}

# Kernel settings
grep -q "# Graywell server tuning" "$SYSCTL_CONF" 2>/dev/null || echo "# Graywell server tuning" > "$SYSCTL_CONF"

if is_approved "kernel_swappiness"; then
  sed -i '/vm.swappiness/d' "$SYSCTL_CONF" 2>/dev/null || true
  echo "vm.swappiness = 10" >> "$SYSCTL_CONF"
  tuned "vm.swappiness set to 10"
  SYSCTL_CHANGED=true
fi

if is_approved "kernel_somaxconn"; then
  sed -i '/net.core.somaxconn/d' "$SYSCTL_CONF" 2>/dev/null || true
  echo "net.core.somaxconn = 65535" >> "$SYSCTL_CONF"
  echo "net.ipv4.tcp_max_syn_backlog = 65535" >> "$SYSCTL_CONF"
  tuned "net.core.somaxconn set to 65535"
  SYSCTL_CHANGED=true
fi

if is_approved "kernel_filemax"; then
  sed -i '/fs.file-max/d' "$SYSCTL_CONF" 2>/dev/null || true
  echo "fs.file-max = 500000" >> "$SYSCTL_CONF"
  tuned "fs.file-max set to 500000"
  SYSCTL_CHANGED=true
fi

if $SYSCTL_CHANGED; then
  sysctl -p "$SYSCTL_CONF" &>/dev/null \
    && tuned "Kernel parameters applied immediately" \
    || warn "Kernel params saved — will apply on next reboot"
fi

# File descriptor limits
LIMITS_CONF=/etc/security/limits.d/99-graywell.conf
if [ ! -f "$LIMITS_CONF" ] && $SYSCTL_CHANGED; then
  cat > "$LIMITS_CONF" <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
  tuned "File descriptor limits set to 65535"
fi

# MySQL
if is_approved "mysql_buffer" || is_approved "mysql_maxconn"; then
  # Always try to update existing values first (case-insensitive, with or without spaces)
  MYSQL_UPDATED=false

  if is_approved "mysql_buffer"; then
    # Try to update existing setting (case-insensitive, handle various spacing)
    if grep -iq "innodb_buffer_pool_size" "$MYSQL_CONF" 2>/dev/null; then
      sed -i "s/^\s*innodb_buffer_pool_size\s*=.*/innodb_buffer_pool_size         = ${OPTIMAL_BUFFER_MB}M/" "$MYSQL_CONF"
      MYSQL_UPDATED=true
    fi
  fi

  if is_approved "mysql_maxconn"; then
    # Try to update existing setting (case-insensitive, handle various spacing)
    if grep -iq "max_connections" "$MYSQL_CONF" 2>/dev/null; then
      sed -i "s/^\s*max_connections\s*=.*/max_connections                 = ${OPTIMAL_MAX_CONN}/" "$MYSQL_CONF"
      MYSQL_UPDATED=true
    fi
  fi

  # If no existing Graywell section found, append one
  if ! grep -q "# Graywell" "$MYSQL_CONF" 2>/dev/null; then
    {
      echo ""
      echo "# Graywell tuning — $(date '+%Y-%m-%d')"
      echo "[mysqld]"
      is_approved "mysql_buffer"  && echo "innodb_buffer_pool_size         = ${OPTIMAL_BUFFER_MB}M"
      is_approved "mysql_maxconn" && echo "max_connections                 = ${OPTIMAL_MAX_CONN}"
      echo "innodb_log_file_size            = 64M"
      echo "innodb_flush_log_at_trx_commit  = 2"
      echo "innodb_flush_method             = O_DIRECT"
      echo "thread_cache_size               = 8"
      echo "table_open_cache                = 400"
      echo "tmp_table_size                  = 32M"
      echo "max_heap_table_size             = 32M"
      echo "slow_query_log                  = 1"
      echo "slow_query_log_file             = /var/log/mysql/slow.log"
      echo "long_query_time                 = 2"
    } >> "$MYSQL_CONF"
    mkdir -p /var/log/mysql; chown mysql:mysql /var/log/mysql 2>/dev/null || true
    tuned "MySQL tuning block added to $MYSQL_CONF"
  else
    # Graywell section already exists — make sure all settings are there
    if is_approved "mysql_buffer" && ! grep -q "innodb_buffer_pool_size" "$MYSQL_CONF"; then
      sed -i "/# Graywell tuning/a innodb_buffer_pool_size         = ${OPTIMAL_BUFFER_MB}M" "$MYSQL_CONF"
    fi
    if is_approved "mysql_maxconn" && ! grep -q "max_connections" "$MYSQL_CONF"; then
      sed -i "/# Graywell tuning/a max_connections                 = ${OPTIMAL_MAX_CONN}" "$MYSQL_CONF"
    fi
    $MYSQL_UPDATED && tuned "MySQL settings updated in $MYSQL_CONF" || tuned "MySQL tuning section verified"
  fi
  NEED_MYSQL_RESTART=true
fi

# PHP-FPM
if is_approved "fpm_children" && [ -n "$PHP_FPM_POOL" ]; then
  cp "$PHP_FPM_POOL" "${PHP_FPM_POOL}.bak.$(date +%Y%m%d)" 2>/dev/null || true
  sed -i "s/^pm\.max_children\s*=.*/pm.max_children = ${OPTIMAL_FPM_CHILDREN}/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.start_servers\s*=.*/pm.start_servers = ${OPTIMAL_FPM_MIN}/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.min_spare_servers\s*=.*/pm.min_spare_servers = ${OPTIMAL_FPM_MIN}/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.max_spare_servers\s*=.*/pm.max_spare_servers = $((OPTIMAL_FPM_CHILDREN / 2))/" "$PHP_FPM_POOL"
  sed -i "s/^pm\.max_requests\s*=.*/pm.max_requests = ${OPTIMAL_FPM_MAX_REQ}/" "$PHP_FPM_POOL"
  grep -q "^pm.status_path" "$PHP_FPM_POOL" || echo "pm.status_path = /fpm-status" >> "$PHP_FPM_POOL"
  tuned "PHP-FPM pool: max_children=${OPTIMAL_FPM_CHILDREN}, max_requests=${OPTIMAL_FPM_MAX_REQ}"
  NEED_FPM_RESTART=true
fi

# OPcache
if is_approved "opcache" && [ -n "$OPCACHE_INI" ]; then
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
  tuned "OPcache settings written to $OPCACHE_INI"
  NEED_FPM_RESTART=true
fi

# Apache MaxRequestWorkers
if is_approved "apache_mrw" && [ "$WEB_SERVER" = "apache" ] && [ -n "$APACHE_CONF" ]; then
  # Enable modules on bare Ubuntu
  ! $IS_BITNAMI && a2enmod expires deflate headers >> "$REPORT" 2>&1 || true

  # KeepAlive
  if grep -q "^KeepAlive Off" "$APACHE_CONF" 2>/dev/null; then
    sed -i 's/^KeepAlive Off/KeepAlive On/' "$APACHE_CONF"
  elif ! grep -q "^KeepAlive" "$APACHE_CONF" 2>/dev/null; then
    echo "KeepAlive On" >> "$APACHE_CONF"
  fi

  # MaxRequestWorkers — use auto-detected MPM config location
  # APACHE_MPM_CONF was already detected at the top of the script

  MRW_UPDATED=false

  # Ensure directory exists
  if [ ! -d "$(dirname "$APACHE_MPM_CONF")" ]; then
    mkdir -p "$(dirname "$APACHE_MPM_CONF")"
  fi

  # Try to update existing value
  if [ -f "$APACHE_MPM_CONF" ] && grep -qi "MaxRequestWorkers\|MaxClients" "$APACHE_MPM_CONF" 2>/dev/null; then
    sed -i "s/\(MaxRequestWorkers\s*\)[0-9]\+/\1${OPTIMAL_MRW}/" "$APACHE_MPM_CONF"
    sed -i "s/\(MaxClients\s*\)[0-9]\+/\1${OPTIMAL_MRW}/" "$APACHE_MPM_CONF"
    MRW_UPDATED=true
  fi

  # If no existing value, append new MPM block
  if [ "$MRW_UPDATED" = "false" ]; then
    cat >> "$APACHE_MPM_CONF" <<EOF
# Graywell tuning — $(date '+%Y-%m-%d')
<IfModule mpm_prefork_module>
    StartServers             3
    MinSpareServers          3
    MaxSpareServers          8
    MaxRequestWorkers        ${OPTIMAL_MRW}
    MaxConnectionsPerChild   500
</IfModule>
EOF
    MRW_UPDATED=true
  fi

  if [ "$MRW_UPDATED" = "true" ]; then
    tuned "Apache MaxRequestWorkers set to ${OPTIMAL_MRW} in $APACHE_MPM_CONF"
  else
    warn "Could not update Apache MPM config"
  fi

  NEED_APACHE_RESTART=true
fi

# Nginx
if [ "$WEB_SERVER" = "nginx" ] && [ -n "$NGINX_CONF" ]; then
  grep -q "worker_processes" "$NGINX_CONF" && \
    sed -i 's/^worker_processes.*/worker_processes auto;/' "$NGINX_CONF" && \
    tuned "Nginx worker_processes set to auto"
  grep -q "worker_connections" "$NGINX_CONF" && \
    sed -i 's/worker_connections.*/worker_connections 1024;/' "$NGINX_CONF" && \
    tuned "Nginx worker_connections set to 1024"
  NEED_APACHE_RESTART=true
fi

# Swap
if is_approved "swap"; then
  if command -v fallocate &>/dev/null; then
    fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    tuned "1GB swap file created and enabled"
  else
    warn "Could not create swap — run: sudo fallocate -l 1G /swapfile"
  fi
fi

# ──────────────────────────────────────────
# 11. RESTART SERVICES
# ──────────────────────────────────────────
section "11. Restarting Services"

restart_service() {
  local name="$1" cmd="$2"
  eval "$cmd" >> "$REPORT" 2>&1 \
    && ok "$name restarted" \
    || warn "$name restart failed — restart manually"
}

if $NEED_MYSQL_RESTART; then
  if $IS_BITNAMI; then
    restart_service "MariaDB" "/opt/bitnami/ctlscript.sh restart mariadb"
  else
    restart_service "MySQL" "systemctl restart mysql || systemctl restart mariadb"
  fi
fi

if $NEED_FPM_RESTART; then
  PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
  if $IS_BITNAMI; then
    restart_service "PHP-FPM" "/opt/bitnami/ctlscript.sh restart php-fpm"
  else
    restart_service "PHP-FPM" "systemctl restart php${PHP_VER}-fpm 2>/dev/null || systemctl restart php-fpm"
  fi
fi

if $NEED_APACHE_RESTART; then
  if $IS_BITNAMI; then
    restart_service "Apache" "/opt/bitnami/ctlscript.sh restart apache"
  elif [ "$WEB_SERVER" = "nginx" ]; then
    restart_service "Nginx" "systemctl restart nginx"
  else
    restart_service "Apache" "systemctl restart apache2"
  fi
fi

# ──────────────────────────────────────────
# 12. SWAP CHECK
# ──────────────────────────────────────────
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')
[ "${SWAP_TOTAL:-0}" -gt 0 ] \
  && ok "Swap: ${SWAP_TOTAL}MB configured" \
  || warn "No swap — consider adding for stability"

# ──────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────
section "Summary"

APPLIED=0
SKIPPED=0
for i in $(seq 0 $((TOTAL_CHANGES-1))); do
  [ "${CHANGE_APPLY[$i]}" = "true" ] && APPLIED=$((APPLIED+1)) || SKIPPED=$((SKIPPED+1))
done

echo -e "\n  ${GRN}Changes applied:${NC}   $APPLIED"
echo -e "  ${YEL}Changes skipped:${NC}   $SKIPPED"
echo ""

if [ "$APPLIED" -gt 0 ]; then
  echo -e "${BOLD}Applied:${NC}"
  grep "\[TUNED\]" "$REPORT" | tail -"$APPLIED" | sed 's/.*\[TUNED\] /  ✓ /'
  echo ""
fi

echo -e "Full report saved to: ${BOLD}$REPORT${NC}"
report ""
report "Completed: $(date)"