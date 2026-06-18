================================================================================
                    PLAYBOOKS SCRIPT REFERENCE GUIDE
                      Common Commands & Snippets
================================================================================

This file documents all common script commands from the GraywellDesign/playbooks
repository. Use these snippets for server setup, security, malware cleanup, and
SSL certificate management.

Email: graywelldesign@gmail.com

================================================================================
1. INITIAL SERVER SETUP
================================================================================

PURPOSE: Download and run the initial server setup script with email and API keys

COMMAND:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/setup.sh -O setup.sh
chmod +x setup.sh
sudo bash setup.sh <<< 'graywelldesign@gmail.com;YOUR_SENDINBLUE_SMTP_KEY;YOUR_CLOUDFLARE_API_TOKEN'

NOTES:
- Downloads setup.sh script
- Makes it executable
- Runs with sudo and pipes credentials via heredoc
- Configures initial server environment

================================================================================
2. SECURITY AUDIT
================================================================================

PURPOSE: Run comprehensive security audit on the server

COMMAND:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/security_audit.sh -O security_audit.sh
chmod +x security_audit.sh
sudo ./security_audit.sh

NOTES:
- Downloads security_audit.sh script
- Makes it executable
- Runs with sudo for system-level checks

================================================================================
3. WATCHDOG INSTALLATION
================================================================================

PURPOSE: Install watchdog service for server monitoring

COMMAND:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/install-watchdog.sh -O install-watchdog.sh
chmod +x install-watchdog.sh
sudo ./install-watchdog.sh

NOTES:
- Downloads watchdog installation script
- Makes it executable
- Runs with sudo to install as system service

================================================================================
4. PERFORMANCE TUNING
================================================================================

PURPOSE: Optimize server performance settings

COMMAND:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/performance_tune.sh -O performance_tune.sh
chmod +x performance_tune.sh
sudo ./performance_tune.sh

NOTES:
- Downloads performance tuning script
- Makes it executable
- Runs with sudo for system configuration changes

================================================================================
5. MALWARE & SECURITY TOOLS - BATCH DOWNLOAD
================================================================================

PURPOSE: Download all security and malware scanning scripts in one command

COMMAND:
for s in malware_scan_nosudo malware_cleanup rotate-db-passwords reset-wp-passwords block-uploads-php scan-databases verify-wp-core; do wget -q https://raw.githubusercontent.com/GraywellDesign/playbooks/main/${s}.sh -O ${s}.sh; done && chmod +x *.sh

SCRIPTS DOWNLOADED:
  - malware_scan_nosudo.sh - Scan for malware without sudo
  - malware_cleanup.sh - Clean up detected malware
  - rotate-db-passwords.sh - Rotate database passwords
  - reset-wp-passwords.sh - Reset WordPress user passwords
  - block-uploads-php.sh - Block PHP execution in uploads directory
  - scan-databases.sh - Scan databases for threats
  - verify-wp-core.sh - Verify WordPress core files integrity

NOTES:
- Batch downloads multiple scripts using a loop
- Uses -q flag to suppress download progress
- Makes all scripts executable with one chmod command

================================================================================
6. CLEANUP - REMOVE SECURITY SCRIPTS FROM HOME DIRECTORY (DEPTH 3)
================================================================================

PURPOSE: Clean up downloaded security scripts from home directory (shallow search)

COMMAND:
find ~/ -maxdepth 3 -type f \( \
  -name "malware_scan_nosudo.sh" \
  -o -name "malware_cleanup.sh" \
  -o -name "malware_cleanup_all.sh" \
  -o -name "malware_scan_all_sites.sh" \
  -o -name "rotate-db-passwords.sh" \
  -o -name "reset-wp-passwords.sh" \
  -o -name "block-uploads-php.sh" \
  -o -name "scan-databases.sh" \
  -o -name "verify-wp-core.sh" \
  -o -name "reinstall_wordfence.sh" \
  -o -name "shuffle_salts.sh" \
\) -delete && echo "Done"

NOTES:
- Searches only 3 levels deep from home directory (faster)
- Deletes matching script files
- Prints "Done" when complete

================================================================================
7. LOCATE SECURITY SCRIPTS - EXTENDED SEARCH (DEPTH 6)
================================================================================

PURPOSE: Find all security scripts across home directory (deeper search)

COMMAND:
find ~/ -maxdepth 6 -type f \( \
  -name "malware_scan_nosudo.sh" \
  -o -name "malware_cleanup.sh" \
  -o -name "malware_cleanup_all.sh" \
  -o -name "malware_scan_all_sites.sh" \
  -o -name "rotate-db-passwords.sh" \
  -o -name "reset-wp-passwords.sh" \
  -o -name "block-uploads-php.sh" \
  -o -name "scan-databases.sh" \
  -o -name "verify-wp-core.sh" \
  -o -name "reinstall_wordfence.sh" \
  -o -name "shuffle_salts.sh" \
\) -ls

NOTES:
- Searches up to 6 levels deep from home directory
- Uses -ls flag to list files with details (permissions, ownership, size, dates)
- Useful for locating scripts before cleanup or verification

================================================================================
8. ATTACK VECTOR HUNT
================================================================================

PURPOSE: Hunt for attack vectors in WordPress installation (per site)

COMMAND:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/attack_vector_hunt_per_site.sh -O attack_vector_hunt_per_site.sh
chmod +x attack_vector_hunt_per_site.sh
./attack_vector_hunt_per_site.sh

NOTES:
- Downloads attack vector hunting script
- Makes it executable
- Runs without sudo (operates on site files user can access)
- Analyzes suspicious patterns in WordPress installation

================================================================================
9. WORDPRESS SECURITY SUITE
================================================================================

PURPOSE: Reset WordPress passwords and shuffle security salts

COMMAND A - Run setup again:
sudo bash setup.sh <<< 'graywelldesign@gmail.com;YOUR_SENDINBLUE_SMTP_KEY;YOUR_CLOUDFLARE_API_TOKEN'

COMMAND B - Reset WordPress passwords:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/reset-wp-passwords.sh -O reset-wp-passwords.sh
chmod +x reset-wp-passwords.sh
./reset-wp-passwords.sh

COMMAND C - Shuffle WordPress salts:
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/shuffle_salts.sh -O shuffle_salts.sh
chmod +x shuffle_salts.sh
./shuffle_salts.sh

NOTES:
- reset-wp-passwords.sh: Regenerates all WordPress user passwords
- shuffle_salts.sh: Changes WordPress security salts/keys for better security
- Run after detecting compromised accounts
- May require WordPress admin credentials

================================================================================
10. HTACCESS ANALYSIS - HUNT FOR MALICIOUS PHP
================================================================================

PURPOSE: Search for PHP references in .htaccess files (potential backdoors)

COMMAND:
grep -r "\.php\|\.phtml" /home3/esalas/public_html --include=".htaccess" | grep -v "uploads\|Deny from all"

NOTES:
- Searches .htaccess files recursively under public_html
- Looks for .php or .phtml references
- Filters out legitimate entries: "uploads" directory and "Deny from all" rules
- Useful for detecting malicious redirects/handlers
- May need to adjust path from "/home3/esalas/" to your actual account

ALTERNATIVE - Check specific account:
grep -r "\.php\|\.phtml" /home{NUMBER}/{USERNAME}/public_html --include=".htaccess" | grep -v "uploads\|Deny from all"

================================================================================
11. WORDPRESS CORE UPDATES
================================================================================

PURPOSE: Update WordPress core, plugins, and themes

COMMAND:
wp plugin update --all --allow-root
wp theme update --all --allow-root
wp core update --allow-root

NOTES:
- wp plugin update --all: Updates all WordPress plugins
- wp theme update --all: Updates all WordPress themes
- wp core update: Updates WordPress core files
- --allow-root flag: Allows running WP-CLI as root (necessary on servers)
- Run in WordPress root directory
- Check backups before running in production

================================================================================
12. SSL CERTIFICATE - CERTBOT + CLOUDFLARE DNS
================================================================================

PURPOSE: Setup and auto-renew SSL certificate via Certbot and Cloudflare DNS

DOMAIN: tylerslandinghoa.com

FULL SCRIPT:
#!/bin/bash
# Certbot Cloudflare DNS renewal setup + autorenew
# Requires: Cloudflare API token with Edit zone DNS permissions

CLOUDFLARE_TOKEN="YOUR_CLOUDFLARE_API_TOKEN"
DOMAIN="tylerslandinghoa.com"

# Install Cloudflare certbot plugin
apt install python3-certbot-dns-cloudflare -y

# Create credentials file
mkdir -p /root/.secrets
cat > /root/.secrets/cloudflare.ini << EOF
dns_cloudflare_api_token = ${CLOUDFLARE_TOKEN}
EOF
chmod 600 /root/.secrets/cloudflare.ini

# Issue/renew certificate
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d ${DOMAIN} \
  -d www.${DOMAIN} \
  --non-interactive \
  --agree-tos \
  --email graywelldesign@gmail.com

# Reload Apache to pick up new cert
systemctl reload apache2

# Set up auto-renewal cron (runs daily at 3am, only renews if within 30 days of expiry)
CRON_JOB="0 3 * * * root certbot renew --quiet --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini && systemctl reload apache2"
echo "${CRON_JOB}" > /etc/cron.d/certbot-renew
chmod 644 /etc/cron.d/certbot-renew

echo "Done. Certificate renewed and auto-renewal cron installed for ${DOMAIN}"
echo "Verify cron: cat /etc/cron.d/certbot-renew"

STEP-BY-STEP:
1. Installs python3-certbot-dns-cloudflare plugin
2. Creates /root/.secrets/cloudflare.ini with API token
3. Issues certificate for domain and www.domain using Cloudflare DNS validation
4. Reloads Apache with new certificate
5. Sets up daily cron job at 3am for auto-renewal
6. Cron only renews if within 30 days of expiration

VERIFICATION:
cat /etc/cron.d/certbot-renew

NOTES:
- Requires valid Cloudflare API token with DNS edit permissions
- Stores token in /root/.secrets/cloudflare.ini with restricted permissions (600)
- Auto-renewal cron runs daily at 3:00 AM
- Apache reloads automatically after successful renewal
- Email notifications sent to graywelldesign@gmail.com for issues
- Requires root/sudo access

================================================================================
QUICK REFERENCE - COMMON WORKFLOW
================================================================================

For a fresh server with malware issues:

1. Initial Setup:
   [Run: Initial Server Setup]

2. Security Audit:
   [Run: Security Audit]

3. Malware Scanning & Cleanup:
   [Run: Malware & Security Tools - Batch Download]
   Then run individual scripts as needed:
   ./malware_scan_nosudo.sh
   ./malware_cleanup.sh
   ./scan-databases.sh
   ./verify-wp-core.sh

4. Security Hardening:
   [Run: WordPress Security Suite (reset passwords + shuffle salts)]
   [Run: Block uploads PHP]

5. Install Monitoring:
   [Run: Watchdog Installation]

6. Server Optimization:
   [Run: Server Optimization - Intelligent Tuning]
   (Use --dry-run first to preview, then select menu options)

7. Performance:
   [Run: Performance Tuning]

8. SSL Certificate (if needed):
   [Run: SSL Certificate - Certbot + Cloudflare DNS]

9. Updates:
   [Run: WordPress Core Updates]

10. Cleanup (optional):
    [Run: Cleanup - Remove Security Scripts]

QUICK OPTIMIZATION WORKFLOW (Just performance tuning):
- Initial Setup → Server Optimization → Performance Tuning → Updates





================================================================================
13. SERVER OPTIMIZATION - INTELLIGENT TUNING
================================================================================

PURPOSE: Intelligently optimize WordPress server for production load
- Auto-calculates safe Apache MaxRequestWorkers based on available RAM
- Configures optimal PHP memory limits per system resources
- Adds swap space as emergency buffer to prevent crashes
- Optional: Install Redis, WordPress caching plugin, verify OPcache
- Interactive menu - select exactly which optimizations to apply

COMMAND - PREVIEW FIRST (ALWAYS RECOMMENDED):
wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/optimize-server.sh -O optimize-server.sh
chmod +x optimize-server.sh
sudo ./optimize-server.sh --dry-run

COMMAND - APPLY OPTIMIZATIONS:
sudo ./optimize-server.sh

NOTES:
- Downloads optimize-server.sh script
- Makes it executable
- Runs with sudo for system configuration changes
- --dry-run flag: Shows all changes WITHOUT making them (use first!)
- Interactive menu: Choose which optimizations to apply
  [1] Apache MaxRequestWorkers (RECOMMENDED)
  [2] PHP Memory Limit (optional)
  [3] Add Swap Space (RECOMMENDED)
  [4] Setup WordPress Caching (optional - user chooses plugin)
  [5] Install Redis (optional - advanced caching)
  [6] Verify OPcache Config (optional - informational)
  [A] All of the above
  [M] Minimum (Apache + Swap only - safest)
  [C] Cancel

FEATURES:
- Detects WordPress root and wp-config.php location automatically
- Handles Lightsail setup (wp-config.php outside web root)
- Detects existing cache plugins (WP Super Cache, W3 Total Cache, etc.)
- Preserves client's existing configurations
- Creates timestamped backups of all modified files
- Validates Apache config before restart

WHAT IT CALCULATES:
- MaxRequestWorkers: (Available RAM - System Reserve) / Process Size
- PHP Memory Limit: 10-15% of total RAM (128M-512M range)
- Swap Space: 1x total RAM (emergency buffer)
- All values capped for safety and system stability

EXAMPLE USAGE:
1. ssh user@server
2. wget https://raw.githubusercontent.com/GraywellDesign/playbooks/main/optimize-server.sh -O optimize-server.sh
3. chmod +x optimize-server.sh
4. sudo ./optimize-server.sh --dry-run    (review changes)
5. sudo ./optimize-server.sh              (select menu options, apply)
6. Monitor load and memory for 24 hours

BACKUPS CREATED:
- /etc/apache2/mods-available/mpm_prefork.conf.backup-YYYYMMDD-HHMMSS
- /etc/php/X.Y/apache2/php.ini.backup-YYYYMMDD-HHMMSS

WORDPRESS CACHING OPTIONS:
If no cache plugin found, script will ask which to install:
  [1] WP Super Cache (recommended - simple and fast)
  [2] W3 Total Cache (advanced features)
  [3] Skip - I'll install my own or use server-side caching only

REDIS (Optional):
- Install redis-server package
- Install and configure wp-redis plugin for WordPress object cache
- Requires ongoing monitoring
- Only installs if selected from menu

OPCACHE (Optional):
- Verifies PHP bytecode caching is enabled
- Reports OPcache statistics and hit rates
- Informational only - does not make changes

NOTES:
- Script is safe for any WordPress/Apache server
- Always run with --dry-run first to preview changes
- All config files backed up before modifications
- User confirmation required before applying changes
- No forced changes - respects existing client setup
- For servers under medium-to-heavy intermittent load








================================================================================
IMPORTANT NOTES
================================================================================

SECURITY:
- These scripts contain sensitive information (API keys, tokens)
- Store securely and do not commit to public repos
- Delete credentials after server setup
- Review scripts before executing on production servers

SUDO REQUIREMENTS:
- Most scripts require sudo for system-level operations
- Some can run without sudo (noted in descriptions)

PATH ADJUSTMENTS:
- Some paths may need adjustment for your specific setup:
  /home3/esalas/public_html → adjust account number and username
  /etc/cron.d/certbot-renew → common location for cron jobs

VERIFICATION:
- Always verify scripts ran successfully
- Check logs for errors
- Test WordPress functionality after running security scripts
- Verify SSL certificate with: certbot certificates

BACKUP BEFORE MAJOR OPERATIONS:
- Back up databases before running malware cleanup
- Back up wp-config.php before shuffling salts
- Test in staging environment if possible

================================================================================
