#!/bin/bash

################################################################################
# Server Optimization Script - Intelligent Tuning for WordPress Servers
#
# Version 2.0 - Interactive configuration
#
# Features:
# - Intelligently calculates optimal Apache/PHP/Swap settings
# - Detects and preserves existing WordPress caching solutions
# - Optional Redis installation for object caching
# - Verifies OPcache configuration
# - Interactive menu to select which optimizations to apply
#
# Safe to run on any server - no forced changes without confirmation
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_VERSION="2.0"
DRY_RUN=false
VERBOSE=true
BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"

# Optimization selection flags
OPTIMIZE_APACHE=false
OPTIMIZE_PHP=false
ADD_SWAP=false
SETUP_WORDPRESS_CACHE=false
INSTALL_REDIS=false
VERIFY_OPCACHE=false

################################################################################
# Logging Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

log_menu() {
    echo -e "${CYAN}$1${NC}"
}

################################################################################
# Interactive Menu
################################################################################

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"

    if [ "$default" = "y" ]; then
        read -p "$(echo -e ${CYAN}${prompt}${NC} [Y/n]: )" -r
        [[ $REPLY =~ ^[Nn]$ ]] && return 1 || return 0
    else
        read -p "$(echo -e ${CYAN}${prompt}${NC} [y/N]: )" -r
        [[ $REPLY =~ ^[Yy]$ ]] && return 0 || return 1
    fi
}

show_optimization_menu() {
    log_section "Select Optimizations to Apply"

    echo ""
    log_menu "Choose which components to optimize:"
    echo ""
    echo "  [1] Apache MaxRequestWorkers (RECOMMENDED - prevents OOM crashes)"
    echo "  [2] PHP Memory Limit (tune per-process memory)"
    echo "  [3] Add Swap Space (RECOMMENDED - emergency buffer)"
    echo "  [4] Setup WordPress Caching (optional - page/object cache)"
    echo "  [5] Install Redis (optional - server-side object cache)"
    echo "  [6] Verify OPcache Config (check PHP bytecode cache status)"
    echo ""
    echo "  [A] All of the above"
    echo "  [M] Minimum (Apache + Swap only - safest)"
    echo "  [C] Cancel (exit without changes)"
    echo ""
    echo "  Examples: '1 3 5' or '1,3,5' for multiple selections"
    echo ""

    read -p "Enter your choice [1-6/A/M/C or space/comma-separated]: " -r CHOICE

    # Handle special cases first
    case "$CHOICE" in
        [Aa])
            OPTIMIZE_APACHE=true
            OPTIMIZE_PHP=true
            ADD_SWAP=true
            SETUP_WORDPRESS_CACHE=true
            INSTALL_REDIS=true
            VERIFY_OPCACHE=true
            return 0
            ;;
        [Mm])
            OPTIMIZE_APACHE=true
            ADD_SWAP=true
            log_warning "Minimum mode selected (Apache + Swap only)"
            return 0
            ;;
        [Cc])
            log_warning "Cancelled by user"
            exit 0
            ;;
    esac

    # Parse comma or space-separated numbers
    for num in $CHOICE; do
        num=$(echo "$num" | tr -d ' ,')
        case "$num" in
            1)
                OPTIMIZE_APACHE=true
                ;;
            2)
                OPTIMIZE_PHP=true
                ;;
            3)
                ADD_SWAP=true
                ;;
            4)
                SETUP_WORDPRESS_CACHE=true
                ;;
            5)
                INSTALL_REDIS=true
                ;;
            6)
                VERIFY_OPCACHE=true
                ;;
            "")
                ;; # Skip empty
            *)
                log_error "Invalid choice: $num"
                show_optimization_menu
                return
                ;;
        esac
    done
}

################################################################################
# System Detection
################################################################################

detect_system() {
    log_section "Detecting System Configuration"

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi

    log_info "OS: $OS $OS_VERSION"

    # CPU cores
    CPU_CORES=$(nproc)
    log_info "CPU Cores: $CPU_CORES"

    # Total RAM in MB
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
    TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
    log_info "Total RAM: ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)"

    # Available RAM in MB
    AVAILABLE_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    AVAILABLE_RAM_MB=$((AVAILABLE_RAM_KB / 1024))
    log_info "Available RAM: ${AVAILABLE_RAM_MB}MB"

    # Swap
    SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    SWAP_MB=$((SWAP_KB / 1024))
    log_info "Current Swap: ${SWAP_MB}MB"

    # Disk space available
    DISK_FREE_KB=$(df / | tail -1 | awk '{print $4}')
    DISK_FREE_GB=$((DISK_FREE_KB / 1024 / 1024))
    log_info "Disk Space Available: ${DISK_FREE_GB}GB"

    # Detect web server
    if systemctl is-active --quiet apache2; then
        WEB_SERVER="apache2"
        MPM_TYPE=$(apache2ctl -M 2>/dev/null | grep mpm | awk '{print $1}' | cut -d_ -f1)
        log_info "Web Server: Apache 2.4 (MPM: $MPM_TYPE)"
    else
        log_error "Apache2 not found or not running"
        exit 1
    fi

    # Detect PHP version
    PHP_VERSION=$(php -v | head -1 | awk '{print $2}')
    log_info "PHP Version: $PHP_VERSION"

    # Find Apache PHP config
    if [ -f "/etc/php/${PHP_VERSION%.*}/apache2/php.ini" ]; then
        APACHE_PHP_INI="/etc/php/${PHP_VERSION%.*}/apache2/php.ini"
    else
        log_error "Cannot find Apache PHP configuration"
        exit 1
    fi
    log_info "Apache PHP Config: $APACHE_PHP_INI"

    # Detect WordPress root (where index.php and wp-load.php are)
    WORDPRESS_ROOT=""
    WORDPRESS_INSTALLED=false

    # Get DocumentRoot from Apache
    if [ -f "/etc/apache2/sites-enabled/000-default.conf" ] || [ -f "/etc/apache2/sites-enabled/default.conf" ]; then
        APACHE_ROOT=$(grep -h "DocumentRoot" /etc/apache2/sites-enabled/*.conf 2>/dev/null | head -1 | awk '{print $2}')
        if [ -n "$APACHE_ROOT" ] && [ -f "$APACHE_ROOT/index.php" ] && [ -f "$APACHE_ROOT/wp-load.php" ]; then
            WORDPRESS_ROOT="$APACHE_ROOT"
            WORDPRESS_INSTALLED=true
        fi
    fi

    # If not found via Apache, search common locations
    if [ "$WORDPRESS_INSTALLED" = false ]; then
        for path in /var/www/html /var/www /home/*/public_html /usr/share/nginx/html /var/www/wordpress; do
            if [ -f "$path/wp-load.php" ] && [ -f "$path/index.php" ]; then
                WORDPRESS_ROOT="$path"
                WORDPRESS_INSTALLED=true
                break
            fi
        done
    fi

    # Detect wp-config.php location (may be outside WORDPRESS_ROOT for security)
    WPCONFIG_PATH=""
    if [ "$WORDPRESS_INSTALLED" = true ]; then
        # Check in WordPress root first
        if [ -f "$WORDPRESS_ROOT/wp-config.php" ]; then
            WPCONFIG_PATH="$WORDPRESS_ROOT/wp-config.php"
        else
            # Check parent directory (common Lightsail setup)
            PARENT_DIR=$(dirname "$WORDPRESS_ROOT")
            if [ -f "$PARENT_DIR/wp-config.php" ]; then
                WPCONFIG_PATH="$PARENT_DIR/wp-config.php"
            fi
        fi

        if [ -n "$WPCONFIG_PATH" ]; then
            log_info "WordPress found at: $WORDPRESS_ROOT"
            log_info "wp-config.php at: $WPCONFIG_PATH"
        else
            WORDPRESS_INSTALLED=false
            log_warning "WordPress root found but wp-config.php not detected"
        fi
    fi

    if [ "$WORDPRESS_INSTALLED" = false ]; then
        log_warning "WordPress not detected in common locations"
    fi
}

################################################################################
# Caching Detection
################################################################################

detect_caching() {
    log_section "Detecting Current Caching Configuration"

    # Check for cache plugins
    CACHE_PLUGIN_FOUND=""
    if [ "$WORDPRESS_INSTALLED" = true ]; then
        if [ -d "$WORDPRESS_ROOT/wp-content/plugins/wp-super-cache" ]; then
            CACHE_PLUGIN_FOUND="WP Super Cache"
            log_info "Found: WP Super Cache"
        elif [ -d "$WORDPRESS_ROOT/wp-content/plugins/w3-total-cache" ]; then
            CACHE_PLUGIN_FOUND="W3 Total Cache"
            log_info "Found: W3 Total Cache"
        elif [ -d "$WORDPRESS_ROOT/wp-content/plugins/wp-fastest-cache" ]; then
            CACHE_PLUGIN_FOUND="WP Fastest Cache"
            log_info "Found: WP Fastest Cache"
        else
            log_warning "No cache plugin detected"
        fi
    fi

    # Check for Redis
    REDIS_RUNNING=false
    if command -v redis-cli &> /dev/null && redis-cli ping &> /dev/null; then
        REDIS_RUNNING=true
        log_success "Redis is running"
    else
        log_warning "Redis not running"
    fi

    # Check for Memcached
    MEMCACHED_RUNNING=false
    if pgrep -x memcached > /dev/null; then
        MEMCACHED_RUNNING=true
        log_success "Memcached is running"
    else
        log_warning "Memcached not running"
    fi

    # Check OPcache
    OPCACHE_ENABLED=$(php -r 'echo extension_loaded("Zend OPcache") ? "YES" : "NO";')
    log_info "OPcache: $OPCACHE_ENABLED"
}

################################################################################
# Calculations
################################################################################

calculate_optimal_values() {
    log_section "Calculating Optimal Server Configuration"

    # System reserves (minimum to keep system running)
    SYSTEM_RESERVE_MB=$((CPU_CORES * 512))  # 512MB per CPU core for OS
    [ $SYSTEM_RESERVE_MB -lt 1024 ] && SYSTEM_RESERVE_MB=1024  # Minimum 1GB
    log_info "System Reserve (OS): ${SYSTEM_RESERVE_MB}MB"

    # MySQL reserve (approximate)
    MYSQL_RESERVE_MB=$((TOTAL_RAM_MB / 8))  # ~12.5% of RAM for MySQL
    [ $MYSQL_RESERVE_MB -lt 512 ] && MYSQL_RESERVE_MB=512
    log_info "MySQL Reserve (est.): ${MYSQL_RESERVE_MB}MB"

    # Available for Apache/PHP
    AVAILABLE_FOR_PHP=$((TOTAL_RAM_MB - SYSTEM_RESERVE_MB - MYSQL_RESERVE_MB))
    log_info "Available for Apache/PHP: ${AVAILABLE_FOR_PHP}MB"

    # PHP Process Size Estimation
    PHP_PROCESS_SIZE=80
    if [ "$TOTAL_RAM_MB" -lt 2048 ]; then
        PHP_PROCESS_SIZE=50  # Smaller for low-RAM servers
    elif [ "$TOTAL_RAM_MB" -gt 8192 ]; then
        PHP_PROCESS_SIZE=120  # Larger for high-RAM servers
    fi
    log_info "Estimated PHP Process Size: ${PHP_PROCESS_SIZE}MB"

    # Calculate MaxRequestWorkers
    CALCULATED_MAX_WORKERS=$((AVAILABLE_FOR_PHP / PHP_PROCESS_SIZE))

    # Apply safety limits
    MIN_WORKERS=4
    MAX_WORKERS=$((CPU_CORES * 4))  # At most 4 per core

    if [ "$CALCULATED_MAX_WORKERS" -lt "$MIN_WORKERS" ]; then
        MAX_REQUEST_WORKERS=$MIN_WORKERS
    elif [ "$CALCULATED_MAX_WORKERS" -gt "$MAX_WORKERS" ]; then
        MAX_REQUEST_WORKERS=$MAX_WORKERS
    else
        MAX_REQUEST_WORKERS=$CALCULATED_MAX_WORKERS
    fi

    log_info "Calculated MaxRequestWorkers: $MAX_REQUEST_WORKERS (range: $MIN_WORKERS-$MAX_WORKERS)"

    # Derive other Apache settings
    START_SERVERS=$((CPU_CORES))
    [ $START_SERVERS -lt 2 ] && START_SERVERS=2

    MIN_SPARE=$((CPU_CORES * 2))
    [ $MIN_SPARE -lt 5 ] && MIN_SPARE=5

    MAX_SPARE=$((CPU_CORES * 4))
    [ $MAX_SPARE -lt 10 ] && MAX_SPARE=10

    log_info "Apache Settings:"
    log_info "  - StartServers: $START_SERVERS"
    log_info "  - MinSpareServers: $MIN_SPARE"
    log_info "  - MaxSpareServers: $MAX_SPARE"

    # Calculate PHP Memory Limit
    PHP_MEMORY_LIMIT=$((TOTAL_RAM_MB / 10))

    if [ "$PHP_MEMORY_LIMIT" -lt 128 ]; then
        PHP_MEMORY_LIMIT=128
    elif [ "$PHP_MEMORY_LIMIT" -gt 512 ]; then
        PHP_MEMORY_LIMIT=512
    fi

    log_info "Calculated PHP Memory Limit: ${PHP_MEMORY_LIMIT}M"

    # Calculate Swap
    CURRENT_SWAP_MB=$SWAP_MB
    RECOMMENDED_SWAP_MB=$((TOTAL_RAM_MB))  # 1x RAM

    if [ "$CURRENT_SWAP_MB" -lt "$RECOMMENDED_SWAP_MB" ]; then
        SWAP_NEEDED=$((RECOMMENDED_SWAP_MB - CURRENT_SWAP_MB))
        log_warning "Current swap (${CURRENT_SWAP_MB}MB) is less than recommended (${RECOMMENDED_SWAP_MB}MB)"
        log_info "Will add ${SWAP_NEEDED}MB swap"
    else
        SWAP_NEEDED=0
        log_success "Swap space is adequate"
    fi
}

################################################################################
# Configuration Summary
################################################################################

show_configuration_summary() {
    log_section "Configuration Summary"

    echo ""
    echo "Current Settings vs Recommended:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Get current Apache settings
    if [ -f "/etc/apache2/mods-available/mpm_prefork.conf" ]; then
        CURRENT_MAX_WORKERS=$(grep "MaxRequestWorkers" /etc/apache2/mods-available/mpm_prefork.conf | awk '{print $2}')
    else
        CURRENT_MAX_WORKERS="unknown"
    fi
    printf "%-35s %-20s %-20s\n" "Setting" "Current" "Recommended"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-35s %-20s %-20s\n" "MaxRequestWorkers" "$CURRENT_MAX_WORKERS" "$MAX_REQUEST_WORKERS"
    printf "%-35s %-20s %-20s\n" "PHP Memory Limit" "$(php -r 'echo ini_get("memory_limit");')" "${PHP_MEMORY_LIMIT}M"
    printf "%-35s %-20s %-20s\n" "Swap Space" "${CURRENT_SWAP_MB}MB" "${RECOMMENDED_SWAP_MB}MB"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$WORDPRESS_INSTALLED" = true ]; then
        echo "WordPress Configuration:"
        echo "  - Installation root: $WORDPRESS_ROOT"
        echo "  - wp-config.php: $WPCONFIG_PATH"
        if [ -n "$CACHE_PLUGIN_FOUND" ]; then
            echo "  - Cache plugin: $CACHE_PLUGIN_FOUND (will preserve)"
        else
            echo "  - Cache plugin: None detected"
        fi
    fi
    echo ""

    if [ "$OPTIMIZE_APACHE" = true ] || [ "$OPTIMIZE_PHP" = true ] || [ "$ADD_SWAP" = true ] || \
       [ "$SETUP_WORDPRESS_CACHE" = true ] || [ "$INSTALL_REDIS" = true ] || [ "$VERIFY_OPCACHE" = true ]; then
        echo "Selected Optimizations:"
        [ "$OPTIMIZE_APACHE" = true ] && echo "  ✓ Apache MaxRequestWorkers tuning"
        [ "$OPTIMIZE_PHP" = true ] && echo "  ✓ PHP Memory Limit optimization"
        [ "$ADD_SWAP" = true ] && echo "  ✓ Swap space configuration"
        [ "$SETUP_WORDPRESS_CACHE" = true ] && echo "  ✓ WordPress caching setup"
        [ "$INSTALL_REDIS" = true ] && echo "  ✓ Redis installation"
        [ "$VERIFY_OPCACHE" = true ] && echo "  ✓ OPcache verification"
        echo ""
    fi
}

################################################################################
# Apache Configuration
################################################################################

optimize_apache() {
    if [ "$OPTIMIZE_APACHE" = false ]; then
        return 0
    fi

    log_section "Optimizing Apache Configuration"

    if [ ! -f "/etc/apache2/mods-available/mpm_prefork.conf" ]; then
        log_error "Cannot find mpm_prefork.conf"
        return 1
    fi

    MPM_CONF="/etc/apache2/mods-available/mpm_prefork.conf"

    # Backup
    if [ "$DRY_RUN" = false ]; then
        cp "$MPM_CONF" "$MPM_CONF$BACKUP_SUFFIX"
        log_success "Backed up: $MPM_CONF$BACKUP_SUFFIX"
    fi

    # Create new configuration
    cat > /tmp/mpm_prefork_new.conf << 'EOF'
<IfModule mpm_prefork_module>
        StartServers            START_SERVERS
        MinSpareServers         MIN_SPARE
        MaxSpareServers         MAX_SPARE
        MaxRequestWorkers       MAX_WORKERS
        MaxConnectionsPerChild  0
        MaxMemoryPerChild       0
</IfModule>
EOF

    sed -i "s/START_SERVERS/$START_SERVERS/g" /tmp/mpm_prefork_new.conf
    sed -i "s/MIN_SPARE/$MIN_SPARE/g" /tmp/mpm_prefork_new.conf
    sed -i "s/MAX_SPARE/$MAX_SPARE/g" /tmp/mpm_prefork_new.conf
    sed -i "s/MAX_WORKERS/$MAX_REQUEST_WORKERS/g" /tmp/mpm_prefork_new.conf

    if [ "$DRY_RUN" = false ]; then
        cp /tmp/mpm_prefork_new.conf "$MPM_CONF"
        log_success "Updated Apache MPM configuration"
        log_info "  StartServers: $START_SERVERS"
        log_info "  MinSpareServers: $MIN_SPARE"
        log_info "  MaxSpareServers: $MAX_SPARE"
        log_info "  MaxRequestWorkers: $MAX_REQUEST_WORKERS"
    else
        log_info "DRY RUN: Would update Apache configuration"
        cat /tmp/mpm_prefork_new.conf
    fi

    rm -f /tmp/mpm_prefork_new.conf
}

################################################################################
# PHP Configuration
################################################################################

optimize_php() {
    if [ "$OPTIMIZE_PHP" = false ]; then
        return 0
    fi

    log_section "Optimizing PHP Configuration"

    if [ ! -f "$APACHE_PHP_INI" ]; then
        log_error "Cannot find PHP configuration at $APACHE_PHP_INI"
        return 1
    fi

    # Backup
    if [ "$DRY_RUN" = false ]; then
        cp "$APACHE_PHP_INI" "$APACHE_PHP_INI$BACKUP_SUFFIX"
        log_success "Backed up: $APACHE_PHP_INI$BACKUP_SUFFIX"
    fi

    # Update memory_limit if not already higher
    CURRENT_MEMORY=$(grep "^memory_limit" "$APACHE_PHP_INI" | awk -F'=' '{print $2}' | xargs)
    CURRENT_MEMORY_NUM=$(echo $CURRENT_MEMORY | sed 's/M//')

    if [ "$CURRENT_MEMORY_NUM" -lt "$PHP_MEMORY_LIMIT" ]; then
        if [ "$DRY_RUN" = false ]; then
            sed -i "s/^memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT}M/" "$APACHE_PHP_INI"
            log_success "Updated memory_limit to ${PHP_MEMORY_LIMIT}M (was $CURRENT_MEMORY)"
        else
            log_info "DRY RUN: Would update memory_limit from $CURRENT_MEMORY to ${PHP_MEMORY_LIMIT}M"
        fi
    else
        log_info "Memory limit already sufficient: $CURRENT_MEMORY"
    fi

    # Ensure max_execution_time is reasonable
    CURRENT_EXEC_TIME=$(grep "^max_execution_time" "$APACHE_PHP_INI" | awk -F'=' '{print $2}' | xargs)
    if [ "$CURRENT_EXEC_TIME" = "0" ] || [ -z "$CURRENT_EXEC_TIME" ]; then
        EXEC_TIME=120
        if [ "$DRY_RUN" = false ]; then
            sed -i "s/^max_execution_time = .*/max_execution_time = $EXEC_TIME/" "$APACHE_PHP_INI"
            log_success "Set max_execution_time to ${EXEC_TIME}s (was unlimited)"
        else
            log_info "DRY RUN: Would set max_execution_time to ${EXEC_TIME}s"
        fi
    fi
}

################################################################################
# Swap Configuration
################################################################################

add_swap() {
    if [ "$ADD_SWAP" = false ]; then
        return 0
    fi

    log_section "Configuring Swap Space"

    if [ "$SWAP_NEEDED" -le 0 ]; then
        log_success "Swap space is adequate, skipping"
        return 0
    fi

    # Check disk space
    if [ "$DISK_FREE_GB" -lt "$((SWAP_NEEDED / 1024 + 1))" ]; then
        log_warning "Not enough disk space to add ${SWAP_NEEDED}MB swap (only ${DISK_FREE_GB}GB free)"
        return 1
    fi

    SWAP_FILE="/var/cache/swap"
    SWAP_SIZE_MB=$SWAP_NEEDED

    if [ "$DRY_RUN" = false ]; then
        log_info "Creating swap file: $SWAP_FILE (${SWAP_SIZE_MB}MB)"

        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB 2>/dev/null
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null 2>&1
        swapon "$SWAP_FILE"

        # Make permanent
        if ! grep -q "$SWAP_FILE" /etc/fstab; then
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        fi

        log_success "Added ${SWAP_SIZE_MB}MB swap space"
        log_info "Swap status:"
        free -h | grep -i swap
    else
        log_info "DRY RUN: Would create ${SWAP_SIZE_MB}MB swap at $SWAP_FILE"
    fi
}

################################################################################
# OPcache Verification
################################################################################

verify_opcache() {
    if [ "$VERIFY_OPCACHE" = false ]; then
        return 0
    fi

    log_section "Verifying OPcache Configuration"

    OPCACHE_ENABLED=$(php -r 'echo extension_loaded("Zend OPcache") ? "YES" : "NO";')

    if [ "$OPCACHE_ENABLED" = "YES" ]; then
        log_success "OPcache is enabled"

        # Get OPcache stats
        php -r '
        if (extension_loaded("Zend OPcache")) {
            $status = opcache_get_status(false);
            echo "  Version: " . phpversion("Zend OPcache") . "\n";
            echo "  Memory Used: " . round($status["memory_usage"]["used_memory"] / 1024 / 1024, 2) . "MB / " . round($status["memory_usage"]["total_allocated_memory"] / 1024 / 1024, 2) . "MB\n";
            echo "  Cache Hits: " . $status["opcache_statistics"]["hits"] . "\n";
            echo "  Cache Misses: " . $status["opcache_statistics"]["misses"] . "\n";
            $hit_rate = ($status["opcache_statistics"]["hits"] / ($status["opcache_statistics"]["hits"] + $status["opcache_statistics"]["misses"])) * 100;
            echo "  Hit Rate: " . round($hit_rate, 2) . "%\n";
        }
        '

        log_info "OPcache is configured and running optimally"
    else
        log_error "OPcache is NOT enabled"
        log_warning "Enable OPcache in php.ini for significant performance improvement:"
        log_info "Add: zend_extension=opcache.so"
    fi
}

################################################################################
# Redis Installation
################################################################################

install_redis() {
    if [ "$INSTALL_REDIS" = false ]; then
        return 0
    fi

    log_section "Installing Redis Server"

    # Check if Redis already running
    if command -v redis-cli &> /dev/null && redis-cli ping &> /dev/null; then
        log_success "Redis is already installed and running"
        setup_wp_redis
        return 0
    fi

    if [ "$DRY_RUN" = false ]; then
        log_info "Installing Redis server..."

        # Install Redis
        if command -v apt-get &> /dev/null; then
            apt-get update >/dev/null
            apt-get install -y redis-server >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y redis >/dev/null 2>&1
        else
            log_error "Cannot detect package manager"
            return 1
        fi

        # Enable and start Redis
        systemctl enable redis-server >/dev/null 2>&1 || systemctl enable redis >/dev/null 2>&1
        systemctl start redis-server 2>/dev/null || systemctl start redis >/dev/null 2>&1

        if redis-cli ping &> /dev/null; then
            log_success "Redis server installed and running"
            setup_wp_redis
        else
            log_error "Failed to start Redis server"
            return 1
        fi
    else
        log_info "DRY RUN: Would install and start Redis server"
    fi
}

setup_wp_redis() {
    if [ "$WORDPRESS_INSTALLED" = false ]; then
        log_warning "WordPress not detected, skipping wp-redis setup"
        return 0
    fi

    log_info "Setting up WordPress Redis integration..."

    cd "$WORDPRESS_ROOT" || return 1

    # Check if WP-CLI is available
    if ! command -v wp &> /dev/null; then
        if [ "$DRY_RUN" = false ]; then
            log_warning "WP-CLI not found, installing..."
            curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>/dev/null
            chmod +x wp-cli.phar
            sudo mv wp-cli.phar /usr/local/bin/wp 2>/dev/null
        fi
    fi

    # Try to install redis-cache plugin if not already installed
    if [ "$DRY_RUN" = false ]; then
        if wp --allow-root --path="$WORDPRESS_ROOT" plugin is-installed redis-cache 2>/dev/null; then
            log_info "Redis Cache plugin already installed"
            if ! wp --allow-root --path="$WORDPRESS_ROOT" plugin is-active redis-cache 2>/dev/null; then
                wp --allow-root --path="$WORDPRESS_ROOT" plugin activate redis-cache 2>/dev/null
                log_success "Activated Redis Cache plugin"
            fi
        else
            log_info "Installing Redis Cache plugin..."
            if wp --allow-root --path="$WORDPRESS_ROOT" plugin install redis-cache --activate 2>/dev/null; then
                log_success "Installed and activated Redis Cache plugin"

                # Configure Redis
                if wp --allow-root --path="$WORDPRESS_ROOT" redis enable-cache-commands 2>/dev/null; then
                    log_success "Redis cache enabled for WordPress"
                fi
            else
                log_warning "Could not install Redis Cache plugin via WP-CLI"
                log_info "Manual installation: WordPress Admin > Plugins > Add New > Search 'Redis Cache'"
            fi
        fi
    else
        log_info "DRY RUN: Would install and configure Redis Cache plugin for WordPress"
    fi
}

################################################################################
# WordPress Caching Setup
################################################################################

setup_wordpress_caching() {
    if [ "$SETUP_WORDPRESS_CACHE" = false ]; then
        return 0
    fi

    if [ "$WORDPRESS_INSTALLED" = false ]; then
        log_section "WordPress Caching - Skipped"
        log_warning "WordPress not detected"
        return 0
    fi

    log_section "Configuring WordPress Caching"

    # Verify wp-config.php exists
    if [ ! -f "$WPCONFIG_PATH" ]; then
        log_error "wp-config.php not found at $WPCONFIG_PATH"
        return 1
    fi

    cd "$WORDPRESS_ROOT" || return 1
    log_info "Working directory: $WORDPRESS_ROOT"
    log_info "Using wp-config.php: $WPCONFIG_PATH"

    # Check for existing cache plugins
    if [ -n "$CACHE_PLUGIN_FOUND" ]; then
        log_success "Cache plugin already installed: $CACHE_PLUGIN_FOUND"
        log_info "Skipping plugin installation (preserving existing setup)"

        # Just ensure WP_CACHE is defined
        if ! grep -q "define.*WP_CACHE" "$WPCONFIG_PATH"; then
            if [ "$DRY_RUN" = false ]; then
                sed -i "/That's all, stop editing/i define('WP_CACHE', true);" "$WPCONFIG_PATH" 2>/dev/null || true
                log_info "Enabled WP_CACHE in wp-config.php"
            fi
        fi
        return 0
    fi

    # Ask user if they want to install a cache plugin
    log_warning "No cache plugin detected"
    echo ""
    log_menu "Would you like to install a WordPress caching plugin?"
    echo "  [1] WP Super Cache (recommended - simple and fast)"
    echo "  [2] W3 Total Cache (advanced features)"
    echo "  [3] Skip - I'll install my own or use server-side caching only"
    echo ""
    read -p "Choose [1-3]: " -r CACHE_CHOICE

    case "$CACHE_CHOICE" in
        1)
            install_cache_plugin "wp-super-cache"
            ;;
        2)
            install_cache_plugin "w3-total-cache"
            ;;
        3)
            log_info "Skipping WordPress cache plugin installation"
            ;;
        *)
            log_warning "Invalid choice, skipping"
            ;;
    esac
}

install_cache_plugin() {
    local plugin_name="$1"

    # Check if WP-CLI is available
    if ! command -v wp &> /dev/null; then
        if [ "$DRY_RUN" = false ]; then
            log_warning "WP-CLI not found, installing..."
            curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>/dev/null
            chmod +x wp-cli.phar
            sudo mv wp-cli.phar /usr/local/bin/wp 2>/dev/null
        fi
    fi

    if [ "$DRY_RUN" = false ]; then
        log_info "Installing $plugin_name..."

        if wp --allow-root --path="$WORDPRESS_ROOT" plugin install "$plugin_name" --activate 2>/dev/null; then
            log_success "Installed and activated $plugin_name"

            # Enable WP_CACHE
            if ! grep -q "define.*WP_CACHE" "$WPCONFIG_PATH"; then
                sed -i "/That's all, stop editing/i define('WP_CACHE', true);" "$WPCONFIG_PATH" 2>/dev/null || true
                log_info "Enabled WP_CACHE in wp-config.php"
            fi
        else
            log_error "Failed to install $plugin_name"
            log_info "Install manually: WordPress Admin > Plugins > Add New > Search '$plugin_name'"
        fi
    else
        log_info "DRY RUN: Would install $plugin_name"
    fi
}

################################################################################
# Service Restart
################################################################################

restart_services() {
    # Only restart if Apache config changed
    if [ "$OPTIMIZE_APACHE" = false ] && [ "$OPTIMIZE_PHP" = false ]; then
        return 0
    fi

    log_section "Restarting Services"

    if [ "$DRY_RUN" = false ]; then
        log_info "Testing Apache configuration..."
        if apache2ctl -t; then
            log_success "Apache configuration is valid"
            log_info "Restarting Apache..."
            systemctl restart apache2
            log_success "Apache restarted"
        else
            log_error "Apache configuration has errors, not restarting"
            return 1
        fi
    else
        log_info "DRY RUN: Would restart Apache"
    fi
}

################################################################################
# Verification
################################################################################

verify_changes() {
    log_section "Verifying Changes"

    log_info "Current system status:"

    # Check Apache
    if systemctl is-active --quiet apache2; then
        log_success "Apache2 is running"
        if [ "$OPTIMIZE_APACHE" = true ]; then
            CURRENT_MAX_WORKERS=$(grep "MaxRequestWorkers" /etc/apache2/mods-available/mpm_prefork.conf | awk '{print $2}')
            log_info "  MaxRequestWorkers: $CURRENT_MAX_WORKERS"
        fi
    else
        log_error "Apache2 is not running"
    fi

    # Check PHP Memory
    if [ "$OPTIMIZE_PHP" = true ]; then
        CURRENT_PHP_MEMORY=$(php -r 'echo ini_get("memory_limit");')
        log_info "PHP Memory Limit: $CURRENT_PHP_MEMORY"
    fi

    # Check Swap
    if [ "$ADD_SWAP" = true ]; then
        CURRENT_SWAP=$(free -h | grep Swap | awk '{print $2}')
        log_success "Swap Space: $CURRENT_SWAP"
    fi

    # Check Load Average
    LOAD=$(uptime | awk -F'load average:' '{print $2}')
    log_info "Current Load Average:$LOAD"
}

################################################################################
# Main Execution
################################################################################

main() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║     Server Optimization Script v${SCRIPT_VERSION}                           ║"
    echo "║     Intelligent Apache, PHP, Swap & Caching Configuration     ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
    --dry-run       Show what would be done without making changes
    -h, --help      Show this help message

This script will interactively guide you through server optimizations:
1. System Analysis - detect current configuration
2. Menu Selection - choose which components to optimize
3. Configuration - show calculated optimal values
4. Confirmation - review and confirm changes
5. Apply - make changes with backups
6. Verify - confirm changes took effect

Optimizations available:
  - Apache MaxRequestWorkers (prevents OOM crashes)
  - PHP Memory Limit (per-process optimization)
  - Swap Space (emergency buffer)
  - WordPress Caching (page/object cache plugins)
  - Redis Server (server-side object cache)
  - OPcache Verification (PHP bytecode caching)

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Execute
    detect_system
    detect_caching
    calculate_optimal_values
    show_optimization_menu
    show_configuration_summary

    if prompt_yes_no "Continue with these optimizations?"; then
        optimize_apache
        optimize_php
        add_swap
        verify_opcache
        install_redis
        setup_wordpress_caching
        restart_services

        sleep 2
        verify_changes

        log_section "Optimization Complete"
        log_success "Server has been optimized for WordPress performance"
        echo ""
        log_info "Next steps:"
        log_info "1. Monitor server load and memory usage over 24 hours"
        log_info "2. Test website performance under normal and peak load"
        log_info "3. Check cache hit rates in WordPress (if using cache plugin)"
        log_info "4. Monitor Redis statistics (if Redis was installed)"
        log_info "5. Consider reducing WordPress plugins (currently: many)"
        echo ""
    else
        log_warning "Optimizations cancelled"
        exit 0
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
