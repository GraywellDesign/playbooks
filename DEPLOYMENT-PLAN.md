# Watchdog Hardened v2 - Deployment & Testing Plan

## Overview

Testing and deployment strategy for Catalytic Ministries (13.216.20.121) with rollout to other servers after success.

---

## Phase 1: Pre-Deployment Testing (Local - Your Machine)

### Step 1: Validate Script Syntax

```bash
# Check for bash syntax errors
bash -n watchdog-hardened.sh

# Check for common issues
shellcheck watchdog-hardened.sh 2>&1 | head -20
```

### Step 2: Review Changes

Compare hardened version to original:

```bash
diff -u watchdog-enhanced.sh watchdog-hardened.sh | head -100

# Key changes to verify:
# ✓ flock for concurrency (line ~60)
# ✓ backup_config_file() function (line ~210)
# ✓ rollback_config() function (line ~220)
# ✓ validate_configuration() (line ~130)
# ✓ safe_read_error_log() with error handling (line ~275)
# ✓ should_send_alert() with throttling (line ~155)
# ✓ cleanup_old_state_files() (line ~550)
```

---

## Phase 2: Deployment to Catalytic Ministries

### Deployment Window
- **When:** During low-traffic period (off-hours recommended)
- **Estimated time:** 30 minutes
- **Rollback available:** Yes (keeps old version as backup)

### Step 1: Connect to Server

```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121
```

### Step 2: Stop Current Watchdog

```bash
sudo systemctl stop graywell-watchdog.timer
sudo systemctl stop graywell-watchdog.service

# Verify stopped
sudo systemctl status graywell-watchdog.timer 2>&1 | head -5
# Should show: inactive (dead)
```

### Step 3: Backup Current Version

```bash
# Backup old script
sudo cp /opt/scripts/watchdog-enhanced.sh \
  /opt/scripts/watchdog-enhanced.sh.backup-$(date +%Y%m%d-%H%M%S)

# Backup old config
sudo cp /etc/graywell-watchdog.conf \
  /etc/graywell-watchdog.conf.backup-$(date +%Y%m%d-%H%M%S)

# Verify backups exist
ls -lh /opt/scripts/watchdog-enhanced.sh.backup-*
ls -lh /etc/graywell-watchdog.conf.backup-*
```

### Step 4: Deploy Hardened Version

From your local machine:

```bash
# Copy files to server
scp -i /Users/ericsalas/esalas_rsa \
  watchdog-hardened.sh \
  graywell-watchdog.conf \
  root@13.216.20.121:/tmp/

# SSH in and move to proper locations
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

# Copy hardened script
sudo cp /tmp/watchdog-hardened.sh /opt/scripts/watchdog-enhanced.sh
sudo chmod +x /opt/scripts/watchdog-enhanced.sh

# Verify script
bash -n /opt/scripts/watchdog-enhanced.sh && echo "✓ Script syntax OK"

# Copy config
sudo cp /tmp/graywell-watchdog.conf /etc/graywell-watchdog.conf
sudo chmod 600 /etc/graywell-watchdog.conf

# Create logs if needed
sudo touch /var/log/graywell-watchdog-enhanced.log
sudo touch /var/log/graywell-watchdog-diagnostic.log
sudo chmod 644 /var/log/graywell-watchdog-*.log

# Create state directory
sudo mkdir -p /var/run/graywell-watchdog
sudo chmod 755 /var/run/graywell-watchdog

echo "✓ Deployment complete"

EOF
```

### Step 5: Verify Deployment

```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

echo "=== Checking installation ==="

# Check script exists and is executable
[ -x /opt/scripts/watchdog-enhanced.sh ] && echo "✓ Script executable" || echo "✗ Script not executable"

# Check config exists
[ -f /etc/graywell-watchdog.conf ] && echo "✓ Config file present" || echo "✗ Config missing"

# Check log files
[ -f /var/log/graywell-watchdog-enhanced.log ] && echo "✓ Main log ready" || echo "✗ Main log missing"
[ -f /var/log/graywell-watchdog-diagnostic.log ] && echo "✓ Diagnostic log ready" || echo "✗ Diagnostic log missing"

# Check state directory
[ -d /var/run/graywell-watchdog ] && echo "✓ State directory ready" || echo "✗ State directory missing"

EOF
```

### Step 6: Start Hardened Watchdog

```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

# Reload systemd daemon
sudo systemctl daemon-reload

# Start the watchdog
sudo systemctl start graywell-watchdog.timer

# Verify it's running
sudo systemctl status graywell-watchdog.timer --no-pager

# Check service status
sudo systemctl status graywell-watchdog.service --no-pager | head -20

EOF
```

### Step 7: Run First Manual Test

```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

echo "Running first watchdog cycle..."
sudo /opt/scripts/watchdog-enhanced.sh

echo ""
echo "=== Results ==="
echo "Last 20 log entries:"
sudo tail -20 /var/log/graywell-watchdog-enhanced.log | jq '.'

echo ""
echo "Any errors or warnings?"
sudo tail -50 /var/log/graywell-watchdog-enhanced.log | jq 'select(.level | test("ERROR|WARN|CRITICAL"))'

EOF
```

---

## Phase 3: Initial Monitoring (Days 1-3)

### Monitoring Schedule

**Day 1 (Deployment Day):**
- Check logs every 2 hours
- Verify watchdog is running
- Confirm no errors in diagnostics

**Days 2-3:**
- Check logs daily
- Verify all checks pass
- Confirm email alerts working (if issues occur)

### What to Monitor

```bash
# 1. Watchdog is running every minute
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
echo "Last 10 watchdog cycles:"
sudo tail -20 /var/log/graywell-watchdog-enhanced.log | jq '.level,.message' | paste -d " " - -
EOF

# 2. No ERROR or CRITICAL logs
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
echo "Errors in last 24 hours:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level | test("ERROR|CRITICAL"))' | wc -l
# Should be 0 or very few
EOF

# 3. Service health is OK
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
echo "Last health check results:"
sudo tail -50 /var/log/graywell-watchdog-enhanced.log | jq 'select(.component=="mysql" or .component=="apache" or .component=="memory" or .component=="disk") | {time:.timestamp, component:.component, level:.level}'
EOF

# 4. No restart loops detected
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
echo "Restart loop alerts:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.message | contains("loop"))' | wc -l
# Should be 0
EOF

# 5. Email delivery working (if alerts sent)
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
echo "Email alerts sent:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level=="ALERT")' | wc -l
EOF
```

### Acceptance Criteria (Day 1 Pass/Fail)

✓ **PASS if all of:**
- Watchdog runs every 1 minute without errors
- All service health checks show "OK"
- No restart loops detected
- No permission errors or missing file errors
- Configuration validation passes on each cycle

✗ **FAIL if any of:**
- Script crashes or stops running
- ERROR or CRITICAL logs appear
- Email alerts about failures
- Unexpected restarts detected

---

## Phase 4: Stability Testing (Days 4-7)

### Purpose
Verify watchdog behaves correctly under normal conditions and doesn't introduce problems.

### Tests to Run

#### Test 1: Normal Operation (Passive Monitoring)
```bash
# Just let it run and monitor
# Check logs daily for any concerning patterns
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

# Summary report
echo "=== 7-Day Watchdog Summary ==="
echo ""
echo "Total cycles run:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level=="START")' | wc -l

echo ""
echo "Services status distribution:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level=="OK") | .component' | sort | uniq -c

echo ""
echo "Any issues detected:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level | test("WARN|ERROR|CRITICAL"))' | wc -l

echo ""
echo "Recovery actions taken:"
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level=="ACTION")' | wc -l

EOF
```

#### Test 2: Concurrency Lock Verification
```bash
# Verify flock is working (preventing concurrent runs)
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

# Create test script to stress-test concurrency
cat > /tmp/test-concurrency.sh << 'SUBEOF'
#!/bin/bash

# Start 5 watchdog cycles simultaneously
for i in {1..5}; do
  /opt/scripts/watchdog-enhanced.sh &
done

# Wait for all to complete
wait

# Check logs for concurrency warnings
echo "Concurrency warnings:"
tail -100 /var/log/graywell-watchdog-enhanced.log | grep -c "concurrency"

SUBEOF

chmod +x /tmp/test-concurrency.sh
sudo /tmp/test-concurrency.sh

# Expected: Should see 4 "concurrency" warnings (first succeeds, 4 others blocked by lock)

EOF
```

#### Test 3: Rollback Mechanism
```bash
# Simulate a config change failure to verify rollback works
# DO NOT RUN THIS ON PRODUCTION - For testing only

# If you want to test: manually change a config, run watchdog, verify it detects and fixes
```

#### Test 4: Alert Email Verification
```bash
# Check if test alert was received
# Look for alert in security@graywelldesign.com inbox
# Should have diagnosis information included
```

### Stability Acceptance Criteria

✓ **PASS if:**
- 7 days of continuous operation without crashes
- No degradation in website performance
- Watchdog CPU/memory usage stable
- Emails delivered within 5 minutes of events
- Concurrency locking works (blocks duplicate runs)

✗ **FAIL if:**
- Website performance noticeably slower
- Watchdog script crashes
- CPU usage continuously high
- Emails not arriving
- Multiple concurrent runs detected

---

## Phase 5: Rollout to Other Servers

### If Catalytic Ministries Test PASSES

Rollout to remaining servers:

1. **Christ Journey** (100.27.149.231)
   - Same deployment process
   - Test for 3-7 days
   - Monitor performance impact

2. **Graywell Tech** (98.94.184.200)
   - Same deployment process
   - Test for 3-7 days

3. **Other Managed Servers**
   - Bitnami servers (different paths)
   - Requires path adjustments in config

### Rollout Checklist

For each server:

```bash
☐ Backup old watchdog script and config
☐ Deploy hardened version
☐ Run syntax validation
☐ Start watchdog and verify logs
☐ Manual test: run first cycle
☐ Monitor logs for 24 hours
☐ Document any issues or customizations needed
☐ Sign off: Ready for production
```

---

## Rollback Procedure

If issues occur, immediate rollback to previous version:

```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

# Stop current watchdog
sudo systemctl stop graywell-watchdog.timer
sudo systemctl stop graywell-watchdog.service

# Restore backup
BACKUP_DATE=$(ls -t /opt/scripts/watchdog-enhanced.sh.backup-* | head -1 | grep -oP '\d{8}-\d{6}$')

sudo cp /opt/scripts/watchdog-enhanced.sh.backup-$BACKUP_DATE \
  /opt/scripts/watchdog-enhanced.sh

sudo cp /etc/graywell-watchdog.conf.backup-$BACKUP_DATE \
  /etc/graywell-watchdog.conf

# Restart with old version
sudo systemctl daemon-reload
sudo systemctl start graywell-watchdog.timer

# Verify
sudo systemctl status graywell-watchdog.timer

echo "Rollback complete - old version restored"

EOF
```

---

## Success Criteria - Full Deployment

After successful testing on Catalytic Ministries and rollout to all servers:

### Uptime Improvement
- ✅ Fewer than 1 unplanned outage per month
- ✅ Outages that occur are auto-recovered within seconds (not hours)
- ✅ Restart loops detected and stopped (human intervention on 3+ cycles)

### Performance
- ✅ No measurable impact on website performance
- ✅ Watchdog CPU: <5% per minute
- ✅ Watchdog memory: <10MB
- ✅ Log rotation working (logs not bloating)

### Reliability
- ✅ All email alerts received and useful
- ✅ Diagnostics accurate (>90% confidence)
- ✅ Config changes within bounds only
- ✅ No silent failures or missed issues

### Operational
- ✅ Admin can review logs and understand actions taken
- ✅ Rollback procedure works if needed
- ✅ Documentation complete and accurate

---

## Troubleshooting During Testing

### Issue: Script syntax errors
```bash
# Cause: Deployment issue
# Fix:
bash -n /opt/scripts/watchdog-enhanced.sh
# Should show no output (success)
```

### Issue: Permission denied errors
```bash
# Cause: File permissions wrong
# Fix:
sudo chmod 755 /opt/scripts/watchdog-enhanced.sh
sudo chmod 644 /var/log/graywell-watchdog*.log
sudo chmod 600 /etc/graywell-watchdog.conf
```

### Issue: Logs not being created
```bash
# Cause: Missing log files or write permissions
# Fix:
sudo touch /var/log/graywell-watchdog-enhanced.log
sudo touch /var/log/graywell-watchdog-diagnostic.log
sudo chmod 644 /var/log/graywell-watchdog*.log
sudo chown root:root /var/log/graywell-watchdog*.log
```

### Issue: Watchdog not running
```bash
# Cause: Systemd timer not enabled
# Fix:
sudo systemctl daemon-reload
sudo systemctl enable graywell-watchdog.timer
sudo systemctl start graywell-watchdog.timer
sudo systemctl status graywell-watchdog.timer

# Check timer logs
sudo journalctl -u graywell-watchdog.timer -n 20
```

### Issue: Alerts not being sent
```bash
# Cause: msmtp not configured or email invalid
# Fix:
# Check email config
sudo cat /etc/graywell-watchdog.conf | grep ALERT_EMAIL

# Test msmtp
echo "Test" | msmtp -a default your-email@example.com

# Check mail log
sudo tail -30 /var/log/mail.log
```

---

## Monitoring Command Cheatsheet

```bash
# Real-time log monitoring
ssh root@13.216.20.121 'tail -f /var/log/graywell-watchdog-enhanced.log | jq .'

# Recent errors
ssh root@13.216.20.121 'cat /var/log/graywell-watchdog-enhanced.log | jq "select(.level | test(\"ERROR|CRITICAL\"))"'

# Recovery actions
ssh root@13.216.20.121 'cat /var/log/graywell-watchdog-enhanced.log | jq "select(.level==\"ACTION\")"'

# Restart history
ssh root@13.216.20.121 'cat /var/log/graywell-watchdog-enhanced.log | jq "select(.message | contains(\"restart\"))"'

# Alert history
ssh root@13.216.20.121 'cat /var/log/graywell-watchdog-enhanced.log | jq "select(.level==\"ALERT\")"'

# Service health
ssh root@13.216.20.121 'tail -20 /var/log/graywell-watchdog-enhanced.log | jq "select(.level==\"OK\")"'
```

---

## Expected Timeline

- **Day 0:** Deploy to Catalytic Ministries
- **Days 1-3:** Initial monitoring and validation
- **Days 4-7:** Stability testing
- **Day 8:** Decision to proceed or rollback
- **If PASS - Days 9-10:** Rollout to Christ Journey
- **Days 11-17:** Test on Christ Journey
- **Days 18-21:** Rollout to remaining servers
- **Day 22+:** Full production monitoring

**Total: ~3 weeks to full production deployment**

---

## Communication Plan

### When Things Are Working
- Check logs daily
- No action needed
- Brief customer update: "Monitoring systems upgraded"

### If Issue Detected
- Immediate analysis of logs
- If fixable: Fix and document
- If not: Rollback and investigate

### Customer Communication
- Transparent: "Watchdog detected and auto-recovered X issue"
- Detailed: Include diagnosis and action taken
- Preventive: "This would have been a Y-hour outage without automated recovery"
