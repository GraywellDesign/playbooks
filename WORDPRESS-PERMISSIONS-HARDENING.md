# WordPress File Permissions & Security Hardening Guide

## Issue: Plugin Updates Fail with Permission Errors

When applying security hardening to WordPress installations, overly restrictive file permissions prevent WordPress and plugin updates.

### Error Symptoms
```
Warning: Could not create directory. "/opt/bitnami/wordpress/wp-content/upgrade/plugin-name"
```

Updates fail because WordPress can't write to wp-content directories.

---

## Root Cause

Security hardening typically involves:
- Restricting file permissions (e.g., 644 for files, 755 for directories)
- Disabling write access to wp-content

However, **WordPress requires write access** to:
- `/wp-content/upgrade/` - for downloading and unpacking updates
- `/wp-content/uploads/` - for media uploads
- `/wp-content/cache/` - for cache plugins
- `/wp-content/plugins/` - for active plugin modifications

When the web server user (Apache's `daemon` user in Bitnami) can't write to these directories, updates fail.

---

## The Fix: Proper Permission Hierarchy

### Ownership
All WordPress files should be owned by the application user (bitnami) with the web server group (daemon):
```bash
sudo chown -R bitnami:daemon /opt/bitnami/wordpress
```

### Directory Permissions
```bash
# Core WordPress directories: 755 (no group write needed)
sudo chmod -R 755 /opt/bitnami/wordpress/wp-admin
sudo chmod -R 755 /opt/bitnami/wordpress/wp-includes
sudo chmod -R 755 /opt/bitnami/wordpress/*.php

# Directories requiring web server write access: 775
sudo chmod -R 775 /opt/bitnami/wordpress/wp-content
sudo chmod -R 775 /opt/bitnami/wordpress/wp-content/upgrade
sudo chmod -R 775 /opt/bitnami/wordpress/wp-content/uploads
sudo chmod -R 775 /opt/bitnami/wordpress/wp-content/cache
sudo chmod -R 775 /opt/bitnami/wordpress/wp-content/upgrade-temp-backup

# Config files: 644 (readable but not executable)
sudo chmod 644 /opt/bitnami/wordpress/wp-config.php
sudo chmod 644 /opt/bitnami/wordpress/.htaccess
```

### File Permissions
```bash
# PHP files: 644
find /opt/bitnami/wordpress -type f -name "*.php" -exec sudo chmod 644 {} \;

# Other files: 644
find /opt/bitnami/wordpress/wp-content -type f ! -name "*.php" -exec sudo chmod 644 {} \;
```

---

## Security Best Practices While Allowing Updates

### What to Disable (without breaking updates)
```bash
# Disable file editing from WordPress admin
echo "define('DISALLOW_FILE_EDIT', true);" >> /opt/bitnami/wordpress/wp-config.php

# Disable plugin/theme installation from admin
echo "define('DISALLOW_FILE_MODS', false);" >> /opt/bitnami/wordpress/wp-config.php
# Note: Set to FALSE to allow updates via admin dashboard
```

### Additional Security Measures
1. **Use Fail2ban** - Protect against brute force attacks
2. **Enable HTTPS** - Force SSL with HSTS headers
3. **Limit login attempts** - Use Wordfence or similar plugins
4. **Disable XML-RPC** - Remove attack vector
5. **Keep WordPress updated** - Regular updates are essential
6. **Restrict wp-admin access** - IP whitelist if possible

---

## Verification Script

Run this to verify correct permissions:

```bash
#!/bin/bash
WORDPRESS_PATH="/opt/bitnami/wordpress"

echo "Checking WordPress file permissions..."
echo "=================================="

# Check ownership
echo -n "wp-content owner: "; ls -ld $WORDPRESS_PATH/wp-content | awk '{print $3":"$4}'
echo -n "upgrade perms: "; ls -ld $WORDPRESS_PATH/wp-content/upgrade | awk '{print $1}'
echo -n "uploads perms: "; ls -ld $WORDPRESS_PATH/wp-content/uploads | awk '{print $1}'

# Check if daemon can write
if [ -w "$WORDPRESS_PATH/wp-content/upgrade" ]; then
    echo "✓ wp-content/upgrade is writable by web server"
else
    echo "✗ wp-content/upgrade is NOT writable by web server"
fi

if [ -w "$WORDPRESS_PATH/wp-content/uploads" ]; then
    echo "✓ wp-content/uploads is writable by web server"
else
    echo "✗ wp-content/uploads is NOT writable by web server"
fi
```

---

## Implementation for New Servers

When hardening a new WordPress server:

1. **Set base permissions first** (install → update → harden sequence)
2. **Use 775 for wp-content initially** - Allow updates to work
3. **Apply DISALLOW_FILE_EDIT** - Prevent direct file editing
4. **Use security plugins** - Wordfence, Sucuri Scanner instead of filesystem restrictions
5. **Enable HTTPS + HSTS** - Strongest protection
6. **Monitor updates** - Check for new versions regularly

---

## Server-Specific Notes

### Bitnami WordPress
- Web server runs as `daemon` user
- Files owned by `bitnami:daemon`
- Use group write (775) for web-writable dirs
- Located in `/opt/bitnami/wordpress/`

### Standard Linux (Apache as www-data)
- Web server runs as `www-data` user
- Files owned by `www-data:www-data` or `ubuntu:www-data`
- Same principle applies: group-writable for uploads/updates

### Security Hardening Impact
When applying security hardening:
- ✅ DO: Use HTTPS, HSTS, Fail2ban
- ✅ DO: Disable unnecessary features (XML-RPC, file edit)
- ✅ DO: Use plugin-based security (Wordfence)
- ❌ DON'T: Make wp-content world-readable (644)
- ❌ DON'T: Disable all write access to wp-content
- ❌ DON'T: Use overly restrictive permissions that break updates

---

## Related Issues

- WordPress updates fail (permission denied)
- Plugin installation fails from admin panel
- Media uploads fail with permission errors
- Cache plugins can't write cache files

## Related Files

- `/opt/bitnami/wordpress/wp-config.php` - Permissions config
- `/opt/bitnami/apache/conf/vhosts/` - Apache vhost config
- `/etc/apache2/apache2.conf` - Apache user/group config (standard installs)

---

## Last Updated
2026-06-19

## Applied To
- graywelldesign.com (Bitnami WordPress 6.7.1)
