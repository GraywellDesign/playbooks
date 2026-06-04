#!/bin/bash
# ============================================================
#  Graywell Design — Server Watchdog
#  Monitors: MySQL, Apache/Nginx, PHP-FPM, Disk, Memory
#  Auto-restarts failed services and sends email alerts
#
#  Install: sudo bash install-watchdog.sh
#  Logs:    /var/log/graywell-watchdog.log
#  State:   /var/run/graywell-watchdog/
# ============================================================

# ── Config ──────────────────────────────────────────────────
ALERT_EMAIL="security@graywelldesign.com"
LOG=/var/log/graywell-watchdog.log
STATE_DIR=/var/run/graywell-watchdog
DISK_WARN=85       # % usage — warning
DISK_CRIT=95       # % usage — critical
MEM_WARN_MB=150    # available MB — warning
MEM_CRIT_MB=75     # available MB — critical
HTTP_TIMEOUT=10    # seconds for HTTP check
CHECK_URL="http://localhost"

# ── Colors & Logging ────────────────────────────────────────
mkdir -p "$STATE_DIR"

ts()     { date '+%Y-%m-%d %H:%M:%S'; }
log()    { echo "$(ts) $*" | tee -a "$LOG"; }
log_ok() { echo "$(ts) [OK]    $*" >> "$LOG"; }

# ── Email via msmtp ─────────────────────────────────────────
send_alert() {
  local subject="$1"
  local body="$2"
  local priority="${3:-normal}"  # normal or critical

  local host
  host=$(hostname)
  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')
  local full_subject="[$host] $subject"
  [ "$priority" = "critical" ] && full_subject="🚨 CRITICAL [$host] $subject"

  echo -e "Subject: ${full_subject}\n\n${body}\n\n--\nServer: ${host} (${server_ip})\nTime: $(ts)\nLog: ${LOG}" \
    | /usr/bin/msmtp "$ALERT_EMAIL" 2>/dev/null \
    || log "[WARN] Failed to send alert email: $subject"
}

# ── State tracking (prevent alert storms) ───────────────────
# Each service gets a state file: "ok", "warning", or "critical"
get_state() { cat "$STATE_DIR/$1" 2>/dev/null || echo "ok"; }
set_state()  { echo "$2" > "$STATE_DIR/$1"; }

# Only alert when state changes (ok→warning, warning→critical, critical→ok)
should_alert() {
  local service="$1" new_state="$2"
  local old_state
  old_state=$(get_state "$service")
  [ "$old_state" != "$new_state" ]
}

# ── Service restart ──────────────────────────────────────────
IS_BITNAMI=false
[ -d /opt/bitnami ] && IS_BITNAMI=true

restart_service() {
  local service="$1"   # mysql, apache, nginx, php-fpm
  local friendly="$2"

  log "[RESTART] Attempting restart of $friendly..."

  if $IS_BITNAMI; then
    case "$service" in
      mysql|mariadb) /opt/bitnami/ctlscript.sh restart mariadb 2>/dev/null & ;;
      apache)        /opt/bitnami/ctlscript.sh restart apache  2>/dev/null & ;;
      nginx)         /opt/bitnami/ctlscript.sh restart nginx   2>/dev/null & ;;
      php-fpm)       /opt/bitnami/ctlscript.sh restart php-fpm 2>/dev/null & ;;
    esac
  else
    systemctl restart "$service" 2>/dev/null &
  fi

  # Wait up to 15s for restart
  sleep 15

  # Return whether it's back up
  systemctl is-active --quiet "$service" 2>/dev/null \
    || pgrep -x "${service%%.*}" &>/dev/null
}

# ── Checks ──────────────────────────────────────────────────

check_mysql() {
  local service_name="mysql"
  $IS_BITNAMI && service_name="mariadb"

  # Check process exists
  if ! pgrep -x mysqld &>/dev/null && ! pgrep -x mariadbd &>/dev/null; then
    log "[FAIL] MySQL/MariaDB process not found"

    if should_alert "mysql" "warning"; then
      set_state "mysql" "warning"
      restart_service "$service_name" "MySQL/MariaDB"

      # Check if restart worked
      sleep 5
      if pgrep -x mysqld &>/dev/null || pgrep -x mariadbd &>/dev/null; then
        log "[RECOVER] MySQL restarted successfully"
        send_alert "MySQL restarted automatically" \
          "MySQL/MariaDB was down and has been automatically restarted.\n\nStatus: RECOVERED\nAction taken: systemctl restart $service_name"
        set_state "mysql" "ok"
      else
        log "[CRITICAL] MySQL failed to restart"
        set_state "mysql" "critical"
        send_alert "MySQL DOWN — restart failed" \
          "MySQL/MariaDB is DOWN and could not be automatically restarted.\n\nStatus: CRITICAL — manual intervention required\nAction taken: restart attempted, failed\n\nCheck: sudo systemctl status $service_name\nCheck: sudo journalctl -u $service_name -n 50" \
          "critical"
      fi
    elif [ "$(get_state mysql)" = "critical" ]; then
      # Still down after previous critical alert — resend every 10 cycles
      local count
      count=$(cat "$STATE_DIR/mysql_crit_count" 2>/dev/null || echo 0)
      count=$((count + 1))
      echo "$count" > "$STATE_DIR/mysql_crit_count"
      if [ $((count % 10)) -eq 0 ]; then
        send_alert "MySQL STILL DOWN — ${count} minutes" \
          "MySQL/MariaDB has been down for approximately ${count} minutes.\nManual intervention required." \
          "critical"
      fi
    fi
    return 1
  fi

  # Process exists — now test actual query response
  local query_result
  query_result=$(mysql -u root --connect-timeout=5 -e "SELECT 1" 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$query_result" ]; then
    log "[FAIL] MySQL process running but not responding to queries"

    if should_alert "mysql" "warning"; then
      set_state "mysql" "warning"
      send_alert "MySQL not responding to queries" \
        "MySQL/MariaDB process is running but not responding to queries.\n\nThis may indicate:\n- Too many connections\n- Deadlock or hung queries\n- Memory pressure\n\nCheck: sudo mysqladmin status\nCheck: sudo mysql -e 'SHOW PROCESSLIST'"
    fi
    return 1
  fi

  # All good
  if [ "$(get_state mysql)" != "ok" ]; then
    log "[OK] MySQL recovered"
    send_alert "MySQL recovered ✅" "MySQL/MariaDB is now responding normally."
    rm -f "$STATE_DIR/mysql_crit_count"
  fi
  set_state "mysql" "ok"
  log_ok "MySQL healthy"
}

check_webserver() {
  local ws_name=""
  local ws_process=""
  local ws_service=""

  # Detect which web server is running
  if pgrep -x httpd &>/dev/null || pgrep -x apache2 &>/dev/null; then
    ws_name="Apache"
    ws_process="apache2\|httpd"
    ws_service=$($IS_BITNAMI && echo "apache" || echo "apache2")
  elif pgrep -x nginx &>/dev/null; then
    ws_name="Nginx"
    ws_process="nginx"
    ws_service="nginx"
  else
    # Neither running — check if either is installed
    if command -v apache2 &>/dev/null || command -v httpd &>/dev/null || [ -f /opt/bitnami/apache/bin/httpd ]; then
      ws_name="Apache"
      ws_service=$($IS_BITNAMI && echo "apache" || echo "apache2")
    elif command -v nginx &>/dev/null || [ -f /opt/bitnami/nginx/sbin/nginx ]; then
      ws_name="Nginx"
      ws_service="nginx"
    else
      log_ok "No web server installed — skipping web server check"
      return 0
    fi

    log "[FAIL] $ws_name process not found"

    if should_alert "webserver" "warning"; then
      set_state "webserver" "warning"
      restart_service "$ws_service" "$ws_name"

      sleep 5
      if pgrep -x "apache2\|httpd\|nginx" &>/dev/null; then
        log "[RECOVER] $ws_name restarted successfully"
        send_alert "$ws_name restarted automatically" \
          "$ws_name was down and has been automatically restarted.\n\nStatus: RECOVERED"
        set_state "webserver" "ok"
      else
        log "[CRITICAL] $ws_name failed to restart"
        set_state "webserver" "critical"
        send_alert "$ws_name DOWN — restart failed" \
          "$ws_name is DOWN and could not be automatically restarted.\n\nManual intervention required.\nCheck: sudo systemctl status $ws_service" \
          "critical"
      fi
    fi
    return 1
  fi

  # Process running — now test HTTP response
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$HTTP_TIMEOUT" \
    --connect-timeout 5 \
    "$CHECK_URL" 2>/dev/null)

  if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
    log "[FAIL] $ws_name process running but not responding to HTTP requests"

    if should_alert "webserver" "warning"; then
      set_state "webserver" "warning"
      restart_service "$ws_service" "$ws_name"
      sleep 5

      http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$CHECK_URL" 2>/dev/null)
      if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
        log "[RECOVER] $ws_name responding after restart (HTTP $http_code)"
        send_alert "$ws_name recovered after restart" \
          "$ws_name was not responding to HTTP requests and has been restarted.\n\nStatus: RECOVERED\nHTTP response: $http_code"
        set_state "webserver" "ok"
      else
        log "[CRITICAL] $ws_name still not responding after restart"
        set_state "webserver" "critical"
        send_alert "$ws_name not responding — restart attempted" \
          "$ws_name process is running but not serving HTTP requests.\nA restart was attempted but the service is still not responding.\n\nHTTP response code: ${http_code:-none}\nURL tested: $CHECK_URL\n\nCheck: curl -v http://localhost\nCheck: sudo systemctl status $ws_service" \
          "critical"
      fi
    fi
    return 1
  elif [ "$http_code" -ge 500 ] 2>/dev/null; then
    log "[WARN] $ws_name returning HTTP $http_code"
    if should_alert "webserver" "warning"; then
      set_state "webserver" "warning"
      send_alert "$ws_name returning HTTP $http_code errors" \
        "$ws_name is running and responding, but returning server errors.\n\nHTTP response: $http_code\nURL: $CHECK_URL\n\nThis may indicate a PHP/WordPress error rather than a server issue.\nCheck: sudo tail -50 /var/log/apache2/error.log"
    fi
    return 1
  fi

  # All good
  if [ "$(get_state webserver)" != "ok" ]; then
    log "[OK] Web server recovered (HTTP $http_code)"
    send_alert "$ws_name recovered ✅" "$ws_name is now responding normally (HTTP $http_code)."
  fi
  set_state "webserver" "ok"
  log_ok "$ws_name healthy (HTTP $http_code)"
}

check_phpfpm() {
  # Check if PHP-FPM is installed
  if ! command -v php-fpm* &>/dev/null && ! pgrep -x "php-fpm[0-9.]*" &>/dev/null \
     && ! [ -f /opt/bitnami/php/sbin/php-fpm ]; then
    log_ok "PHP-FPM not installed — skipping"
    return 0
  fi

  # Detect FPM service name
  local fpm_service
  fpm_service=$(systemctl list-units --type=service 2>/dev/null \
    | grep -oE "php[0-9.]+-fpm" | head -1)
  [ -z "$fpm_service" ] && $IS_BITNAMI && fpm_service="php-fpm"
  [ -z "$fpm_service" ] && fpm_service="php-fpm"

  if ! pgrep -f "php-fpm" &>/dev/null; then
    log "[FAIL] PHP-FPM process not found"

    if should_alert "phpfpm" "warning"; then
      set_state "phpfpm" "warning"
      restart_service "$fpm_service" "PHP-FPM"
      sleep 5

      if pgrep -f "php-fpm" &>/dev/null; then
        log "[RECOVER] PHP-FPM restarted successfully"
        send_alert "PHP-FPM restarted automatically" \
          "PHP-FPM was down and has been automatically restarted.\n\nStatus: RECOVERED"
        set_state "phpfpm" "ok"
      else
        log "[CRITICAL] PHP-FPM failed to restart"
        set_state "phpfpm" "critical"
        send_alert "PHP-FPM DOWN — restart failed" \
          "PHP-FPM is DOWN and could not be automatically restarted.\n\nManual intervention required.\nCheck: sudo systemctl status $fpm_service" \
          "critical"
      fi
    fi
    return 1
  fi

  # FPM running — check worker saturation via status page if available
  local fpm_status
  fpm_status=$(curl -s --max-time 3 "http://localhost/fpm-status" 2>/dev/null \
    || curl -s --max-time 3 "http://127.0.0.1/fpm-status" 2>/dev/null)

  if [ -n "$fpm_status" ]; then
    local active_procs idle_procs
    active_procs=$(echo "$fpm_status" | grep "active processes" | awk '{print $NF}')
    idle_procs=$(echo "$fpm_status" | grep "idle processes" | awk '{print $NF}')

    if [ -n "$active_procs" ] && [ -n "$idle_procs" ] && [ "$idle_procs" -eq 0 ] 2>/dev/null; then
      log "[WARN] PHP-FPM all workers busy (active: $active_procs, idle: $idle_procs)"
      if should_alert "phpfpm" "warning"; then
        set_state "phpfpm" "warning"
        send_alert "PHP-FPM worker pool saturated" \
          "All PHP-FPM workers are busy with no idle processes.\nThis will cause new requests to queue or fail.\n\nActive workers: $active_procs\nIdle workers: $idle_procs\n\nConsider increasing pm.max_children in your PHP-FPM pool config."
      fi
      return 1
    fi
  fi

  if [ "$(get_state phpfpm)" != "ok" ]; then
    log "[OK] PHP-FPM recovered"
    send_alert "PHP-FPM recovered ✅" "PHP-FPM is now running normally."
  fi
  set_state "phpfpm" "ok"
  log_ok "PHP-FPM healthy"
}

check_disk() {
  local alerted=false

  # Use full df output: Filesystem Size Used Avail Use% Mounted
  while IFS= read -r line; do
    local usage mount
    usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')

    # Skip empty or header lines
    [ -z "$usage" ] || [ -z "$mount" ] && continue
    [[ "$usage" =~ ^[0-9]+$ ]] || continue

    # Skip irrelevant mounts
    [[ "$mount" =~ ^/(dev|sys|proc|run) ]] && continue

    if [ "$usage" -ge "$DISK_CRIT" ] 2>/dev/null; then
      log "[CRITICAL] Disk $mount at ${usage}% — CRITICAL"
      if should_alert "disk_${mount//\//_}" "critical"; then
        set_state "disk_${mount//\//_}" "critical"
        send_alert "Disk CRITICAL: $mount at ${usage}%" \
          "Disk usage on $mount has reached ${usage}% — CRITICAL level.\n\nImmediate action required to free space.\n\nLargest directories:\n$(du -sh $mount/* 2>/dev/null | sort -rh | head -10)" \
          "critical"
      fi
      alerted=true
    elif [ "$usage" -ge "$DISK_WARN" ] 2>/dev/null; then
      log "[WARN] Disk $mount at ${usage}%"
      if should_alert "disk_${mount//\//_}" "warning"; then
        set_state "disk_${mount//\//_}" "warning"
        send_alert "Disk warning: $mount at ${usage}%" \
          "Disk usage on $mount has reached ${usage}%.\n\nLargest directories:\n$(du -sh $mount/* 2>/dev/null | sort -rh | head -10)"
      fi
      alerted=true
    else
      # Recovered
      local prev_state
      prev_state=$(get_state "disk_${mount//\//_}")
      if [ "$prev_state" != "ok" ]; then
        log "[OK] Disk $mount recovered to ${usage}%"
        send_alert "Disk space recovered ✅: $mount at ${usage}%" \
          "Disk usage on $mount is back to normal (${usage}%)."
      fi
      set_state "disk_${mount//\//_}" "ok"
      log_ok "Disk $mount at ${usage}%"
    fi
  done < <(df -h 2>/dev/null | tail -n +2)
}

check_memory() {
  local mem_available_kb
  mem_available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  local mem_available_mb=$(( mem_available_kb / 1024 ))
  local mem_total_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))

  if [ "$mem_available_mb" -le "$MEM_CRIT_MB" ] 2>/dev/null; then
    log "[CRITICAL] Memory critically low: ${mem_available_mb}MB available of ${mem_total_mb}MB"
    if should_alert "memory" "critical"; then
      set_state "memory" "critical"
      send_alert "Memory CRITICAL: only ${mem_available_mb}MB available" \
        "Available memory is critically low.\n\nAvailable: ${mem_available_mb}MB\nTotal: ${mem_total_mb}MB\n\nTop memory consumers:\n$(ps aux --sort=-%mem | head -10)" \
        "critical"
    fi
  elif [ "$mem_available_mb" -le "$MEM_WARN_MB" ] 2>/dev/null; then
    log "[WARN] Memory low: ${mem_available_mb}MB available of ${mem_total_mb}MB"
    if should_alert "memory" "warning"; then
      set_state "memory" "warning"
      send_alert "Memory warning: ${mem_available_mb}MB available" \
        "Available memory is running low.\n\nAvailable: ${mem_available_mb}MB\nTotal: ${mem_total_mb}MB\n\nTop memory consumers:\n$(ps aux --sort=-%mem | head -10)"
    fi
  else
    if [ "$(get_state memory)" != "ok" ]; then
      log "[OK] Memory recovered: ${mem_available_mb}MB available"
      send_alert "Memory recovered ✅" "Available memory is back to normal (${mem_available_mb}MB available)."
    fi
    set_state "memory" "ok"
    log_ok "Memory: ${mem_available_mb}MB available of ${mem_total_mb}MB"
  fi
}

# ── Main ─────────────────────────────────────────────────────
log "--- Watchdog check starting ---"
check_mysql
check_webserver
check_phpfpm
check_disk
check_memory
log "--- Watchdog check complete ---"