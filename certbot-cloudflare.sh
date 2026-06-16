#!/bin/bash
# ============================================================
#  Certbot Cloudflare DNS renewal setup + autorenew
#  Requires: Cloudflare API token with Edit Zone DNS permissions
#
#  Deploy as a standalone command:
#    sudo cp certbot-cloudflare /usr/local/bin/certbot-cloudflare
#    sudo chmod +x /usr/local/bin/certbot-cloudflare
#  Then run: sudo certbot-cloudflare
# ============================================================

set -e

# ── Cloudflare API Token ─────────────────────────────────────
if [ -z "$CLOUDFLARE_TOKEN" ]; then
  read -rp "Cloudflare API Token (Edit Zone DNS permission): " CLOUDFLARE_TOKEN
fi
if [ -z "$CLOUDFLARE_TOKEN" ]; then
  echo "ERROR: Cloudflare API token is required." >&2
  exit 1
fi

# ── Domain ───────────────────────────────────────────────────
# Auto-detect from Apache/Nginx virtualhost, then fall back to prompt
detect_domain() {
  # Try Apache ServerName directives
  local d
  d=$(grep -rh "ServerName " /etc/apache2/sites-enabled/ 2>/dev/null \
      | grep -v "#" | awk '{print $2}' | grep -v "^www\." \
      | grep "\." | head -1)
  [ -n "$d" ] && { echo "$d"; return; }

  # Try Nginx server_name directives
  d=$(grep -rh "server_name " /etc/nginx/sites-enabled/ 2>/dev/null \
      | grep -v "#" | awk '{print $2}' | tr -d ';' \
      | grep -v "^www\." | grep "\." | head -1)
  [ -n "$d" ] && { echo "$d"; return; }

  # Try hostname -f
  d=$(hostname -f 2>/dev/null | grep "\.")
  [ -n "$d" ] && { echo "$d"; return; }

  echo ""
}

DETECTED=$(detect_domain)

if [ -n "$DETECTED" ]; then
  read -rp "Domain [detected: ${DETECTED}]: " DOMAIN_INPUT
  DOMAIN="${DOMAIN_INPUT:-$DETECTED}"
else
  read -rp "Domain (e.g. example.com): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
  echo "ERROR: Domain is required." >&2
  exit 1
fi

# Strip leading www. if someone typed it
DOMAIN="${DOMAIN#www.}"

echo ""
echo "  Domain : ${DOMAIN}"
echo "  www    : www.${DOMAIN}"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Install Cloudflare certbot plugin ────────────────────────
echo ""
echo "[1/5] Installing certbot-dns-cloudflare..."
apt-get install -y python3-certbot-dns-cloudflare -q

# ── Credentials file ─────────────────────────────────────────
echo "[2/5] Writing Cloudflare credentials..."
mkdir -p /root/.secrets
cat > /root/.secrets/cloudflare.ini << EOF
dns_cloudflare_api_token = ${CLOUDFLARE_TOKEN}
EOF
chmod 600 /root/.secrets/cloudflare.ini

# ── Issue / renew certificate ─────────────────────────────────
echo "[3/5] Issuing certificate for ${DOMAIN} and www.${DOMAIN}..."
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d "${DOMAIN}" \
  -d "www.${DOMAIN}" \
  --non-interactive \
  --agree-tos \
  --email graywelldesign@gmail.com

# ── Reload web server ─────────────────────────────────────────
echo "[4/5] Reloading web server..."
if systemctl is-active --quiet apache2; then
  systemctl reload apache2
  echo "  Apache reloaded."
elif systemctl is-active --quiet nginx; then
  systemctl reload nginx
  echo "  Nginx reloaded."
else
  echo "  No running Apache/Nginx detected — skipping reload."
fi

# ── Auto-renewal cron ─────────────────────────────────────────
echo "[5/5] Installing auto-renewal cron (daily 3am)..."
cat > /etc/cron.d/certbot-renew << EOF
# Renew all Cloudflare DNS certs daily; reloads web server on success
0 3 * * * root certbot renew --quiet \\
  --dns-cloudflare \\
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \\
  && { systemctl is-active --quiet apache2 && systemctl reload apache2; \\
       systemctl is-active --quiet nginx && systemctl reload nginx; } 2>/dev/null || true
EOF
chmod 644 /etc/cron.d/certbot-renew

echo ""
echo "✓ Done. Certificate issued and auto-renewal cron installed for ${DOMAIN}"
echo "  Verify cert  : certbot certificates"
echo "  Verify cron  : cat /etc/cron.d/certbot-renew"
echo "  Test renewal : certbot renew --dry-run --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini"
