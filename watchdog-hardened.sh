#!/bin/bash
# ============================================================
#  Graywell Design — Enhanced Server Watchdog v2 (Hardened)
#  Production-ready with safety fixes, concurrency protection,
#  auto-rollback, and comprehensive error handling
#
#  Logs:    /var/log/graywell-watchdog-enhanced.log (JSON)
#  State:   /var/run/graywell-watchdog/
#  Config:  /etc/graywell-watchdog.conf
# ============================================================

set -u

# ── CONFIG ──────────────────────────────────────────────────
ALERT_EMAIL="${ALERT_EMAIL:-security@graywelldesign.com}"
LOG="/var/log/graywell-watchdog-enhanced.log"
DIAGNOSTIC_LOG="/var/log/graywell-watchdog-diagnostic.log"
STATE_DIR="/var/run/graywell-watchdog"
LOCKFILE="$STATE_DIR/watchdog.lock"
LOCK_TIMEOUT=30

DISK_WARN=85
DISK_CRIT=95
MEM_WARN_MB=150
MEM_CRIT_MB=75
HTTP_TIMEOUT=10
CHECK_URL="http://localhost"

# Auto-recovery limits
declare -A TUNING_LIMITS=(
  [MaxRequestWorkers_min]=8
  [MaxRequestWorkers_max]=32
  [php_memory_limit_min]=128M
  [php_memory_limit_max]=1G
  [mysql_max_connections_min]=100
  [mysql_max_connections_max]=1000
)

# Restart loop protection
MAX_RESTART_ATTEMPTS=3
RESTART_WINDOW_MINUTES=10

# Alert throttling
ALERT_THROTTLE_SECONDS=600  # Don't send same alert more than every 10 min

# Configuration validation patterns (support multiple versions)
declare -a APACHE_ERROR_PATTERNS=(
  "AH00161.*MaxRequestWorkers"     # Current versions
  "server_limit.*workers"           # Future pattern
  "too.*request.*worker"            # Generic fallback
)

mkdir -p "$STATE_DIR"

# ── CONCURRENCY LOCKING ─────────────────────────────────────
# Prevent concurrent runs using flock
acquire_lock() {
  if ! exec 200>"$LOCKFILE"; then
    json_log "ERROR" "lock" "Cannot create lock file" "{\"lockfile\":\"$LOCKFILE\"}"
    exit 1
  fi

  if ! flock -x -w "$LOCK_TIMEOUT" 200 2>/dev/null; then
    json_log "WARN" "concurrency" "Previous watchdog cycle still running" \
      "{\"lockfile\":\"$LOCKFILE\",\"timeout_seconds\":$LOCK_TIMEOUT}"
    exit 0  # Exit gracefully, don't run concurrent cycle
  fi
}

# Lock will be automatically released on script exit
trap 'exec 200>&-' EXIT

# ── LOGGING ─────────────────────────────────────────────────
ts()     { date '+%Y-%m-%d %H:%M:%S'; }
ts_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

json_log() {
  local level="$1" component="$2" message="$3" details="${4:-}"
  local timestamp
  timestamp=$(ts_iso)

  local json="{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"component\":\"$component\",\"message\":\"$message\""
  [ -n "$details" ] && json="$json,\"details\":$details"
  json="$json}"

  echo "$json" >> "$LOG"

  if [ "$level" = "DIAGNOSIS" ]; then
    echo "$json" >> "$DIAGNOSTIC_LOG"
  fi
}

rotate_logs() {
  for logfile in "$LOG" "$DIAGNOSTIC_LOG"; do
    if [ -f "$logfile" ]; then
      local size
      size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo 0)

      if [ "$size" -gt 10485760 ]; then  # 10MB
        local timestamp
        timestamp=$(date +%s)
        mv "$logfile" "$logfile.$timestamp"
        gzip "$logfile.$timestamp" 2>/dev/null &

        # Keep only last 5 rotated versions
        ls -t "$logfile".*.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
      fi
    fi
  done
}

# ── CONFIGURATION VALIDATION ────────────────────────────────
validate_configuration() {
  json_log "DEBUG" "config" "Validating configuration" "{}"

  # Check bounds validity
  local mrw_min="${TUNING_LIMITS[MaxRequestWorkers_min]}"
  local mrw_max="${TUNING_LIMITS[MaxRequestWorkers_max]}"

  if [ "$mrw_min" -ge "$mrw_max" ]; then
    json_log "CRITICAL" "config" "Invalid MaxRequestWorkers bounds" \
      "{\"min\":$mrw_min,\"max\":$mrw_max,\"error\":\"min >= max\"}"
    return 1
  fi

  if [ "$mrw_max" -lt 8 ]; then
    json_log "WARN" "config" "MaxRequestWorkers max bound very low" \
      "{\"max\":$mrw_max,\"recommendation\":\"set to at least 16\"}"
  fi

  # Check alert email
  if [[ ! "$ALERT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    json_log "WARN" "config" "Invalid ALERT_EMAIL format" \
      "{\"email\":\"$ALERT_EMAIL\"}"
  fi

  json_log "DEBUG" "config" "Configuration validation passed" "{}"
  return 0
}

# ── STATE MANAGEMENT ────────────────────────────────────────
get_state() {
  cat "$STATE_DIR/$1" 2>/dev/null || echo "ok"
}

set_state() {
  echo "$2" > "$STATE_DIR/$1"
}

# Enhanced restart tracking with timestamp display
track_restart() {
  local service="$1"
  local restart_file="$STATE_DIR/${service}_restart_times"
  local current_time
  current_time=$(date +%s)
  local window_seconds=$(( RESTART_WINDOW_MINUTES * 60 ))
  local cutoff_time=$(( current_time - window_seconds ))

  # Add current restart
  echo "$current_time" >> "$restart_file"

  # Remove old entries outside window
  awk -v cutoff="$cutoff_time" '$1 > cutoff' "$restart_file" > "$restart_file.tmp"
  mv "$restart_file.tmp" "$restart_file"

  # Count recent restarts
  local count
  count=$(wc -l < "$restart_file" 2>/dev/null || echo 0)

  json_log "DEBUG" "restart_tracking" "Restart recorded" \
    "{\"service\":\"$service\",\"count_in_window\":$count,\"max_allowed\":$MAX_RESTART_ATTEMPTS,\"window_minutes\":$RESTART_WINDOW_MINUTES}"

  echo "$count"
}

# Alert throttling to prevent email storms
should_send_alert() {
  local alert_type="$1"
  local alert_id
  alert_id=$(echo "$alert_type" | md5sum | awk '{print $1}' | head -c 16)
  local alert_file="$STATE_DIR/alert_${alert_id}_lasttime"
  local last_time
  last_time=$(cat "$alert_file" 2>/dev/null || echo 0)
  local current_time
  current_time=$(date +%s)
  local elapsed=$(( current_time - last_time ))

  if [ "$elapsed" -lt "$ALERT_THROTTLE_SECONDS" ]; then
    json_log "DEBUG" "alerts" "Alert throttled (sent recently)" \
      "{\"alert_type\":\"$alert_type\",\"seconds_since_last\":$elapsed,\"throttle_seconds\":$ALERT_THROTTLE_SECONDS}"
    return 1
  fi

  echo "$current_time" > "$alert_file"
  return 0
}

send_alert() {
  local subject="$1"
  local body="$2"
  local priority="${3:-normal}"
  local diagnosis="${4:-}"

  if ! should_send_alert "$subject"; then
    return 0
  fi

  local host
  host=$(hostname)
  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')
  local full_subject="[$host] $subject"
  [ "$priority" = "critical" ] && full_subject="[CRITICAL] [$host] $subject"

  local email_body="$body"
  if [ -n "$diagnosis" ]; then
    email_body="$email_body

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DIAGNOSIS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$diagnosis"
  fi

  printf "Subject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s\n\n--\nServer: %s (%s)\nTime: %s\nLog: %s\nDiagnostic Log: %s" \
    "${full_subject}" "${email_body}" "${host}" "${server_ip}" "$(ts)" "${LOG}" "${DIAGNOSTIC_LOG}" \
    | /usr/bin/msmtp "$ALERT_EMAIL" 2>/dev/null \
    || json_log "WARN" "alerts" "Failed to send email alert" "{\"subject\":\"$subject\"}"

  json_log "ALERT" "system" "$subject" "{\"priority\":\"$priority\"}"
}

# ── DIAGNOSTICS ENGINE ──────────────────────────────────────

# Enhanced error log reading with safety checks
safe_read_error_log() {
  local error_log="$1"
  local lines_to_check="${2:-1000}"

  # Verify file exists and is readable
  if [ ! -f "$error_log" ]; then
    json_log "ERROR" "diagnostics" "Error log file not found" \
      "{\"file\":\"$error_log\"}"
    echo "UNCHECKED"
    return 1
  fi

  if [ ! -r "$error_log" ]; then
    json_log "ERROR" "diagnostics" "Error log not readable (permission denied)" \
      "{\"file\":\"$error_log\"}"
    echo "UNCHECKED"
    return 1
  fi

  # Read last N lines (fast) instead of whole file
  tail -n "$lines_to_check" "$error_log" 2>/dev/null || {
    json_log "ERROR" "diagnostics" "Cannot read error log" \
      "{\"file\":\"$error_log\"}"
    echo "UNCHECKED"
    return 1
  }
}

detect_maxrequestworkers_exhaustion() {
  local error_log="/var/log/apache2/error.log"
  local cutoff_time
  cutoff_time=$(( $(date +%s) - 600 ))  # Last 10 minutes

  if [ ! -r "$error_log" ]; then
    json_log "DEBUG" "diagnostics" "Cannot check MaxRequestWorkers (error log unreadable)" \
      "{\"file\":\"$error_log\"}"
    return 1
  fi

  # Check each pattern (multiple versions)
  local matched_pattern=""
  for pattern in "${APACHE_ERROR_PATTERNS[@]}"; do
    if tail -n 500 "$error_log" 2>/dev/null | grep -q "$pattern"; then
      matched_pattern="$pattern"
      break
    fi
  done

  if [ -n "$matched_pattern" ]; then
    local count
    count=$(tail -n 500 "$error_log" 2>/dev/null | grep -c "$matched_pattern" || echo 0)

    if [ "$count" -gt 2 ]; then
      json_log "DEBUG" "diagnostics" "MaxRequestWorkers pattern detected in logs" \
        "{\"pattern\":\"$matched_pattern\",\"occurrences\":$count}"
      echo "CONFIRMED"
      return 0
    fi
  fi

  echo "NOT_DETECTED"
  return 1
}

detect_memory_pressure() {
  local mem_available_kb
  mem_available_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')

  if [ -z "$mem_available_kb" ]; then
    json_log "WARN" "diagnostics" "Cannot read MemAvailable from /proc/meminfo" "{}"
    return 1
  fi

  local mem_available_mb=$(( mem_available_kb / 1024 ))

  if [ "$mem_available_mb" -lt "$MEM_CRIT_MB" ]; then
    echo "CRITICAL"
  elif [ "$mem_available_mb" -lt "$MEM_WARN_MB" ]; then
    echo "WARNING"
  else
    echo "OK"
  fi
}

detect_db_connection_exhaustion() {
  local mysql_log="/var/log/mysql/error.log"

  if [ ! -r "$mysql_log" ]; then
    json_log "DEBUG" "diagnostics" "Cannot check DB connections (log unreadable)" "{}"
    return 1
  fi

  if tail -n 200 "$mysql_log" 2>/dev/null | grep -q "Aborted connection"; then
    local count
    count=$(tail -n 200 "$mysql_log" 2>/dev/null | grep -c "Aborted connection" || echo 0)

    if [ "$count" -gt 5 ]; then
      echo "CONFIRMED:$count"
      return 0
    fi
  fi

  echo "NOT_DETECTED"
  return 1
}

diagnose_apache_unresponsiveness() {
  local http_code="$1"

  json_log "DIAGNOSIS" "apache" "Analyzing Apache unresponsiveness" \
    "{\"http_code\":\"$http_code\"}"

  local diagnosis=""
  local recommended_fix=""
  local confidence=0

  # Check MaxRequestWorkers exhaustion
  if detect_maxrequestworkers_exhaustion >/dev/null 2>&1; then
    diagnosis="Apache has hit MaxRequestWorkers limit - unable to accept new connections"
    recommended_fix="Increase MaxRequestWorkers setting"
    confidence=95

    json_log "DIAGNOSIS" "root_cause" "MaxRequestWorkers exhaustion" \
      "{\"confidence\":$confidence}"

    echo "$diagnosis|$recommended_fix|$confidence"
    return 0
  fi

  # Check memory pressure
  local mem_status
  mem_status=$(detect_memory_pressure)

  if [ "$mem_status" != "OK" ]; then
    diagnosis="System memory pressure - insufficient resources"
    recommended_fix="Increase available memory or optimize application"
    confidence=80

    json_log "DIAGNOSIS" "root_cause" "Memory pressure" \
      "{\"confidence\":$confidence,\"status\":\"$mem_status\"}"

    echo "$diagnosis|$recommended_fix|$confidence"
    return 0
  fi

  # Generic diagnosis
  diagnosis="Apache not responding to HTTP (root cause unknown)"
  recommended_fix="Check application logs and system resources"
  confidence=30

  echo "$diagnosis|$recommended_fix|$confidence"
}

# ── SMART RECOVERY WITH ROLLBACK ────────────────────────────

backup_config_file() {
  local config_file="$1"
  if [ -f "$config_file" ]; then
    cp "$config_file" "$config_file.pre-watchdog-$(date +%s)"
  fi
}

rollback_config() {
  local config_file="$1"
  local backup_file="$2"

  if [ -f "$backup_file" ]; then
    cp "$backup_file" "$config_file"
    json_log "RECOVERY" "rollback" "Configuration rolled back" \
      "{\"config\":\"$config_file\",\"from_backup\":\"$backup_file\"}"
    return 0
  else
    json_log "ERROR" "rollback" "Backup file not found for rollback" \
      "{\"config\":\"$config_file\",\"expected_backup\":\"$backup_file\"}"
    return 1
  fi
}

increase_maxrequestworkers() {
  local current_value="$1"
  local max_allowed="${TUNING_LIMITS[MaxRequestWorkers_max]}"
  local min_allowed="${TUNING_LIMITS[MaxRequestWorkers_min]}"

  # Calculate new value (50% increase)
  local new_value=$(( (current_value * 150) / 100 ))
  [ "$new_value" -lt $((current_value + 8)) ] && new_value=$((current_value + 8))
  [ "$new_value" -gt "$max_allowed" ] && new_value="$max_allowed"

  # Check if already at max
  if [ "$new_value" -eq "$current_value" ]; then
    json_log "INFO" "recovery" "MaxRequestWorkers already at maximum" \
      "{\"current\":$current_value,\"max\":$max_allowed}"
    return 1
  fi

  local config_file="/etc/apache2/mods-available/mpm_prefork.conf"

  # Backup original
  backup_config_file "$config_file"
  local backup_file="$config_file.pre-watchdog-$(date +%s)"

  # Make the change
  if ! sudo sed -i "s/MaxRequestWorkers[[:space:]]*[0-9]*/MaxRequestWorkers       $new_value/" "$config_file"; then
    json_log "ERROR" "recovery" "Failed to update MaxRequestWorkers in config" \
      "{\"attempted_value\":$new_value}"
    return 1
  fi

  # VALIDATE config syntax
  if ! sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
    json_log "ERROR" "recovery" "Apache config syntax check failed after change" \
      "{\"new_value\":$new_value}"
    rollback_config "$config_file" "$backup_file"
    return 1
  fi

  json_log "ACTION" "recovery" "Increased MaxRequestWorkers" \
    "{\"from\":$current_value,\"to\":$new_value,\"max_allowed\":$max_allowed}"

  return 0
}

restart_service_with_rollback() {
  local service="$1"
  local friendly="$2"
  local backup_file="${3:-}"

  # Check restart loop protection
  local restart_count
  restart_count=$(track_restart "$service")

  if [ "$restart_count" -ge "$MAX_RESTART_ATTEMPTS" ]; then
    json_log "ALERT" "safety" "Restart loop detected - stopping auto-recovery" \
      "{\"service\":\"$service\",\"attempts\":$restart_count,\"window_minutes\":$RESTART_WINDOW_MINUTES}"
    return 1
  fi

  json_log "ACTION" "recovery" "Restarting service" \
    "{\"service\":\"$service\",\"friendly\":\"$friendly\",\"attempt\":$restart_count}"

  # Attempt restart
  if ! sudo systemctl restart "$service" 2>&1 | tee -a "$DIAGNOSTIC_LOG" | tail -1 | grep -q ""; then
    : # Restart issued
  fi

  sleep 3

  # Verify service is running
  if ! sudo systemctl is-active --quiet "$service"; then
    json_log "FAILED" "recovery" "Service failed to restart" \
      "{\"service\":\"$service\"}"

    # Auto-rollback if backup exists
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
      local config_file="${backup_file%.pre-watchdog-*}"
      json_log "RECOVERY" "auto_rollback" "Service restart failed, rolling back config" \
        "{\"service\":\"$service\",\"config\":\"$config_file\"}"
      rollback_config "$config_file" "$backup_file"
      sudo systemctl restart "$service" 2>&1 | tee -a "$DIAGNOSTIC_LOG" >/dev/null
    fi

    return 1
  fi

  json_log "SUCCESS" "recovery" "Service restart successful" \
    "{\"service\":\"$service\"}"
  return 0
}

# ── CLEANUP ─────────────────────────────────────────────────
cleanup_old_state_files() {
  local retention_days=30
  local cutoff_time=$(( $(date +%s) - (retention_days * 86400) ))

  find "$STATE_DIR" -type f -name "*_restart_times" 2>/dev/null | while read -r file; do
    if [ -f "$file" ]; then
      awk -v cutoff="$cutoff_time" '$1 > cutoff' "$file" > "$file.tmp"
      mv "$file.tmp" "$file"

      [ ! -s "$file" ] && rm "$file"
    fi
  done

  json_log "MAINTENANCE" "cleanup" "Cleaned old state files" \
    "{\"retention_days\":$retention_days}"
}

# ── SERVICE CHECKS ──────────────────────────────────────────

check_mysql() {
  local service_name="mysql"

  if ! pgrep -x mysqld &>/dev/null && ! pgrep -x mariadbd &>/dev/null; then
    json_log "WARN" "mysql" "MySQL process not found"
    set_state "mysql" "warning"

    restart_service_with_rollback "$service_name" "MySQL/MariaDB"
    return 1
  fi

  if ! mysql --connect-timeout=5 -e "SELECT 1" &>/dev/null; then
    json_log "WARN" "mysql" "MySQL not responding to queries"
    set_state "mysql" "warning"
    return 1
  fi

  set_state "mysql" "ok"
  json_log "OK" "mysql" "MySQL healthy"
}

check_webserver() {
  local ws_name="Apache"
  local ws_service="apache2"

  if ! pgrep -x apache2 &>/dev/null; then
    json_log "WARN" "apache" "Apache process not found"
    set_state "webserver" "warning"

    restart_service_with_rollback "$ws_service" "$ws_name"
    return 1
  fi

  # HTTP test with timeout
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$HTTP_TIMEOUT" \
    --connect-timeout 5 \
    "$CHECK_URL" 2>/dev/null)

  if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
    json_log "ERROR" "apache" "Apache not responding to HTTP requests" \
      "{\"http_code\":\"${http_code:-timeout}\"}"

    set_state "webserver" "critical"

    # Run diagnostics
    local diagnosis
    diagnosis=$(diagnose_apache_unresponsiveness "$http_code")
    local IFS="|"
    read -r diag_msg fix_msg confidence <<< "$diagnosis"

    # Attempt targeted recovery if MaxRequestWorkers issue
    if echo "$diagnosis" | grep -q "MaxRequestWorkers"; then
      local current_mrw
      current_mrw=$(grep -oP 'MaxRequestWorkers\s+\K[0-9]+' /etc/apache2/mods-available/mpm_prefork.conf 2>/dev/null)

      if [ -n "$current_mrw" ]; then
        local backup_file="/etc/apache2/mods-available/mpm_prefork.conf.pre-watchdog-$(date +%s)"

        if increase_maxrequestworkers "$current_mrw"; then
          if restart_service_with_rollback "$ws_service" "$ws_name" "$backup_file"; then
            # Verify recovery
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
              --max-time "$HTTP_TIMEOUT" "$CHECK_URL" 2>/dev/null)

            if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
              local new_mrw
              new_mrw=$(grep -oP 'MaxRequestWorkers\s+\K[0-9]+' /etc/apache2/mods-available/mpm_prefork.conf 2>/dev/null)

              send_alert "Apache auto-recovered: MaxRequestWorkers tuned" \
                "Apache was unresponsive due to worker limit exhaustion.\n\nAction taken: Increased MaxRequestWorkers from $current_mrw to $new_mrw\n\nStatus: Service restarted and responding normally (HTTP $http_code)" \
                "warning" "$diag_msg\n\nRemediation: $fix_msg (Confidence: $confidence%)"

              set_state "webserver" "ok"
              return 0
            fi
          fi
        fi
      fi
    fi

    # If targeted recovery didn't work, try standard restart
    restart_service_with_rollback "$ws_service" "$ws_name"

    send_alert "Apache unresponsive - restart attempted" \
      "Apache is not responding to HTTP requests.\n\n$diag_msg" \
      "critical" "$diag_msg\n\nRecommended fix: $fix_msg (Confidence: $confidence%)"

    return 1
  fi

  if [ "$(get_state webserver)" != "ok" ]; then
    json_log "RECOVERY" "apache" "Apache recovered" \
      "{\"http_code\":$http_code}"
    send_alert "Apache recovered ✅" "Apache is now responding normally (HTTP $http_code)."
  fi

  set_state "webserver" "ok"
  json_log "OK" "apache" "Apache healthy" "{\"http_code\":$http_code}"
}

check_disk() {
  json_log "CHECK" "disk" "Checking disk usage"

  while IFS= read -r line; do
    local usage mount
    usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')

    [ -z "$usage" ] || [ -z "$mount" ] && continue
    [[ "$usage" =~ ^[0-9]+$ ]] || continue
    [[ "$mount" =~ ^/(dev|sys|proc|run) ]] && continue

    if [ "$usage" -ge "$DISK_CRIT" ] 2>/dev/null; then
      json_log "CRITICAL" "disk" "Disk critically full" \
        "{\"mount\":\"$mount\",\"usage_percent\":$usage}"
      set_state "disk_${mount//\//_}" "critical"

      if should_send_alert "DISK_CRITICAL_${mount}"; then
        send_alert "CRITICAL: Disk $mount at ${usage}%" \
          "Disk usage at critical level.\n\nMount: $mount\nUsage: ${usage}%\n\nManual intervention required." \
          "critical"
      fi
    elif [ "$usage" -ge "$DISK_WARN" ] 2>/dev/null; then
      json_log "WARNING" "disk" "Disk usage high" \
        "{\"mount\":\"$mount\",\"usage_percent\":$usage}"
      set_state "disk_${mount//\//_}" "warning"
    else
      set_state "disk_${mount//\//_}" "ok"
    fi
  done < <(df -Pk 2>/dev/null | tail -n +2)
}

check_memory() {
  local mem_available_kb
  mem_available_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')

  if [ -z "$mem_available_kb" ]; then
    json_log "ERROR" "memory" "Cannot read MemAvailable" "{}"
    return 1
  fi

  local mem_available_mb=$(( mem_available_kb / 1024 ))
  local mem_total_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))

  local mem_status
  mem_status=$(detect_memory_pressure)

  json_log "CHECK" "memory" "Memory check" \
    "{\"available_mb\":$mem_available_mb,\"total_mb\":$mem_total_mb,\"status\":\"$mem_status\"}"

  if [ "$mem_status" = "CRITICAL" ]; then
    set_state "memory" "critical"
    if should_send_alert "MEMORY_CRITICAL"; then
      send_alert "CRITICAL: Memory pressure" \
        "Available memory critically low.\n\nAvailable: ${mem_available_mb}MB of ${mem_total_mb}MB" \
        "critical" "Memory pressure may cause service failures."
    fi
  elif [ "$mem_status" = "WARNING" ]; then
    set_state "memory" "warning"
    if should_send_alert "MEMORY_WARNING"; then
      send_alert "WARNING: Memory usage high" \
        "Available memory running low.\n\nAvailable: ${mem_available_mb}MB of ${mem_total_mb}MB"
    fi
  else
    set_state "memory" "ok"
  fi
}

# ── MAIN ────────────────────────────────────────────────────
main() {
  # Acquire exclusive lock (prevents concurrent runs)
  acquire_lock

  rotate_logs

  # Validate configuration before proceeding
  if ! validate_configuration; then
    json_log "CRITICAL" "startup" "Configuration validation failed"
    exit 1
  fi

  json_log "START" "watchdog" "Watchdog cycle started" "{}"

  check_mysql
  check_webserver
  check_disk
  check_memory

  # Cleanup old state files periodically (every 10 cycles)
  local cycle_counter
  cycle_counter=$(cat "$STATE_DIR/cycle_counter" 2>/dev/null || echo 0)
  cycle_counter=$((cycle_counter + 1))

  if [ $((cycle_counter % 10)) -eq 0 ]; then
    cleanup_old_state_files
  fi

  echo "$cycle_counter" > "$STATE_DIR/cycle_counter"

  json_log "COMPLETE" "watchdog" "Watchdog cycle completed" "{}"
}

main "$@"
