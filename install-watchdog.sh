#!/bin/bash
# ============================================================
#  Graywell Design — Watchdog Installer
#  Installs watchdog.sh as a systemd service + timer
#  Usage: sudo bash install-watchdog.sh
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GRN}[OK]${NC}    $1"; }
fixed() { echo -e "  ${GRN}[DONE]${NC}  $1"; }
info()  { echo -e "  ${BLU}[INFO]${NC}  $1"; }
bad()   { echo -e "  ${RED}[FAIL]${NC}  $1"; }

[ "$EUID" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

echo -e "\n${BOLD}Graywell Watchdog Installer${NC}\n"

# ── Download watchdog.sh ──────────────────────────────────
WATCHDOG_URL="https://raw.githubusercontent.com/GraywellDesign/playbooks/main/watchdog.sh"
WATCHDOG_DEST="/opt/scripts/watchdog.sh"

mkdir -p /opt/scripts

if [ -f "$WATCHDOG_DEST" ]; then
  ok "watchdog.sh already installed at $WATCHDOG_DEST"
else
  info "Downloading watchdog.sh..."
  wget -qO "$WATCHDOG_DEST" "$WATCHDOG_URL" \
    && fixed "Downloaded watchdog.sh" \
    || { bad "Failed to download watchdog.sh from $WATCHDOG_URL"; exit 1; }
fi

chmod 700 "$WATCHDOG_DEST"

# ── Verify msmtp is configured ───────────────────────────
if [ ! -f /etc/msmtprc ]; then
  bad "msmtp not configured — run server setup script first (setup.sh)"
  exit 1
else
  ok "msmtp config found"
fi

# ── Create systemd service ────────────────────────────────
cat > /etc/systemd/system/graywell-watchdog.service <<'EOF'
[Unit]
Description=Graywell Server Watchdog
After=network.target mysql.service mariadb.service apache2.service nginx.service

[Service]
Type=oneshot
ExecStart=/opt/scripts/watchdog.sh
StandardOutput=null
StandardError=append:/var/log/graywell-watchdog.log
EOF

fixed "Created graywell-watchdog.service"

# ── Create systemd timer (runs every 60 seconds) ──────────
cat > /etc/systemd/system/graywell-watchdog.timer <<'EOF'
[Unit]
Description=Graywell Watchdog Timer — runs every 60 seconds
Requires=graywell-watchdog.service

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
EOF

fixed "Created graywell-watchdog.timer (60s interval)"

# ── Create log file with rotation config ─────────────────
touch /var/log/graywell-watchdog.log
chmod 640 /var/log/graywell-watchdog.log

cat > /etc/logrotate.d/graywell-watchdog <<'EOF'
/var/log/graywell-watchdog.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 root root
}
EOF

fixed "Log rotation configured (14 days)"

# ── Enable and start ──────────────────────────────────────
systemctl daemon-reload
systemctl enable graywell-watchdog.timer
systemctl start graywell-watchdog.timer

# Run once immediately so we know it works
info "Running initial watchdog check..."
bash "$WATCHDOG_DEST"

echo ""
if systemctl is-active --quiet graywell-watchdog.timer; then
  ok "Watchdog timer is active and running every 60 seconds"
else
  bad "Watchdog timer failed to start — check: systemctl status graywell-watchdog.timer"
fi

echo ""
echo -e "${BOLD}Watchdog installed successfully.${NC}"
echo -e "  Monitor log:    tail -f /var/log/graywell-watchdog.log"
echo -e "  Timer status:   systemctl status graywell-watchdog.timer"
echo -e "  Run manually:   sudo bash /opt/scripts/watchdog.sh"
echo ""