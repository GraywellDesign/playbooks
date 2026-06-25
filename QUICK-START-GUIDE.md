# Quick Start - Deploy Watchdog Hardened v2

## TL;DR - Deploy in 10 Minutes

```bash
# 1. Copy files to server
scp -i /Users/ericsalas/esalas_rsa \
  watchdog-hardened.sh graywell-watchdog.conf \
  root@13.216.20.121:/tmp/

# 2. Install on server
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
sudo systemctl stop graywell-watchdog.timer

# Backup old version
sudo cp /opt/scripts/watchdog-enhanced.sh \
  /opt/scripts/watchdog-enhanced.sh.backup-$(date +%Y%m%d)
sudo cp /etc/graywell-watchdog.conf \
  /etc/graywell-watchdog.conf.backup-$(date +%Y%m%d)

# Deploy hardened version
sudo cp /tmp/watchdog-hardened.sh /opt/scripts/watchdog-enhanced.sh
sudo chmod +x /opt/scripts/watchdog-enhanced.sh
sudo cp /tmp/graywell-watchdog.conf /etc/graywell-watchdog.conf

# Verify and start
bash -n /opt/scripts/watchdog-enhanced.sh && echo "✓ Script OK"
sudo systemctl daemon-reload
sudo systemctl start graywell-watchdog.timer
sudo systemctl status graywell-watchdog.timer

# Test
sudo /opt/scripts/watchdog-enhanced.sh
echo "Last 10 log entries:"
sudo tail -10 /var/log/graywell-watchdog-enhanced.log | jq '.'
EOF
```

Done! Watchdog is now running with hardened safety features.

---

## What Changed (Key Fixes)

1. **Concurrency Locking** - Prevents two watchdog cycles from running simultaneously
2. **Auto-Rollback** - If config change fails, automatically rollback to previous version
3. **Error Handling** - Better diagnostics if log files aren't readable
4. **Configuration Validation** - Checks bounds on startup to prevent bad config
5. **Alert Throttling** - Prevents email storms (same alert every 10 min max)
6. **State Cleanup** - Old restart tracking files cleaned up weekly
7. **Optimized Parsing** - Only checks last 500-1000 lines of logs (fast)

---

## Verify Installation

```bash
# SSH to server and run:
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

echo "=== WATCHDOG STATUS ==="
sudo systemctl status graywell-watchdog.timer --no-pager | head -10

echo ""
echo "=== LAST CYCLE RESULTS ==="
sudo tail -5 /var/log/graywell-watchdog-enhanced.log | jq '.level, .component, .message'

echo ""
echo "=== ANY ERRORS? ==="
sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level | test("ERROR|CRITICAL"))' | wc -l
echo "(Should be 0)"

echo ""
echo "=== EMAIL CONFIGURED? ==="
sudo grep ALERT_EMAIL /etc/graywell-watchdog.conf

EOF
```

Expected output:
```
=== WATCHDOG STATUS ===
Active: active (waiting)
Trigger: (timed out)

=== LAST CYCLE RESULTS ===
"OK"
"apache"
"Apache healthy"

=== ANY ERRORS? ===
0

=== EMAIL CONFIGURED? ===
ALERT_EMAIL="security@graywelldesign.com"
```

---

## Monitoring (After Deployment)

### Daily Check
```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 \
  'sudo tail -50 /var/log/graywell-watchdog-enhanced.log | jq "select(.level | test(\"ERROR|CRITICAL\"))"' | wc -l
# Should be 0 or very few
```

### Weekly Summary
```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
echo "Weekly Watchdog Summary"
echo "Cycles run: $(sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level=="START")' | wc -l)"
echo "Issues detected: $(sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level | test("WARN|ERROR|CRITICAL"))' | wc -l)"
echo "Recoveries: $(sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.level=="ACTION")' | wc -l)"
echo "Restart loops blocked: $(sudo cat /var/log/graywell-watchdog-enhanced.log | jq 'select(.message | contains("loop"))' | wc -l)"
EOF
```

---

## If Something Goes Wrong

### Rollback to Previous Version (1 minute)
```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'
sudo systemctl stop graywell-watchdog.timer

# Restore backup
sudo cp /opt/scripts/watchdog-enhanced.sh.backup-* /opt/scripts/watchdog-enhanced.sh
sudo cp /etc/graywell-watchdog.conf.backup-* /etc/graywell-watchdog.conf

sudo systemctl start graywell-watchdog.timer
echo "Rolled back to previous version"
EOF
```

### Debug Script Issues
```bash
ssh -i /Users/ericsalas/esalas_rsa root@13.216.20.121 << 'EOF'

# Check script syntax
bash -n /opt/scripts/watchdog-enhanced.sh && echo "✓ Syntax OK" || echo "✗ Syntax error"

# Check permissions
ls -l /opt/scripts/watchdog-enhanced.sh
# Should show: -rwxr-xr-x (755)

# Check config
ls -l /etc/graywell-watchdog.conf
# Should show: -rw------- (600)

# Run manually with debug
sudo bash -x /opt/scripts/watchdog-enhanced.sh 2>&1 | head -50

# Check systemd service
sudo journalctl -u graywell-watchdog.service -n 30

EOF
```

---

## File Checklist

Before deployment, verify you have:

- ✅ `watchdog-hardened.sh` - Main script with all fixes
- ✅ `graywell-watchdog.conf` - Configuration file
- ✅ `DEPLOYMENT-PLAN.md` - Full testing plan
- ✅ `AUDIT-CONCERNS.md` - What was fixed
- ✅ This file - Quick start guide

---

## After Deployment Checklist

After running the deployment script above:

- [ ] Script deployed to `/opt/scripts/watchdog-enhanced.sh`
- [ ] Config deployed to `/etc/graywell-watchdog.conf`
- [ ] Systemd timer restarted
- [ ] No errors in first cycle
- [ ] Email alert configured
- [ ] Logs directory writable
- [ ] State directory exists

---

## Expected Behavior

### Normal Operation
- Runs every 1 minute silently
- Logs "OK" for each healthy service
- No emails (unless there's an issue)
- Minimal CPU/memory impact

### When Issue Occurs
1. Watchdog detects problem (error log, timeout, etc.)
2. Runs diagnostics to identify root cause
3. Takes targeted action if possible (e.g., increase MaxRequestWorkers)
4. Sends email with diagnosis and what was done
5. Logs everything for audit trail

### If Restart Loop Detected
1. After 3 restarts in 10 minutes: stops trying
2. Sends critical alert: "Manual intervention required"
3. Logs all diagnostics for investigation
4. Prevents further resource waste

---

## Questions?

Refer to:
- **Technical Details:** `WATCHDOG-ENHANCED-README.md`
- **What Was Fixed:** `AUDIT-CONCERNS.md`
- **Full Testing Plan:** `DEPLOYMENT-PLAN.md`

---

## Timeline to Production

- **Day 0:** Deploy to Catalytic Ministries
- **Days 1-7:** Monitor and test
- **Day 8:** If successful, rollout to other servers
- **Week 3:** All servers running hardened watchdog

---

## Success Indicators (After 1 Week)

✅ Watchdog running every minute without errors
✅ Services all showing "OK" status
✅ Zero restart loops
✅ No unexpected emails or alerts
✅ Website performance unchanged
✅ CPU/memory usage minimal
