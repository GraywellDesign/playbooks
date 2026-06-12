#!/bin/bash

################################################################################
# ATTACK VECTOR HUNT - PER-SITE SCANNER
# 
# Purpose: Recursively search all sites in /home3/esalas/public_html for 
#          malicious code patterns, obfuscation, and backdoors
#
# Usage: ./attack_vector_hunt_per_site.sh [/path/to/public_html] [output_dir]
# 
# Example: ./attack_vector_hunt_per_site.sh /home3/esalas/public_html ./reports
#
# Author: Security Team
# Date: 2026-06-12
################################################################################

# Configuration
WEBROOT="${1:-.}"
OUTPUT_DIR="${2:-.}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_REPORT="$OUTPUT_DIR/ATTACK_SCAN_SUMMARY_$TIMESTAMP.txt"
DETAILED_REPORT="$OUTPUT_DIR/ATTACK_SCAN_DETAILED_$TIMESTAMP.txt"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_SITES=0
INFECTED_SITES=0
SUSPICIOUS_SITES=0

################################################################################
# UTILITY FUNCTIONS
################################################################################

log_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
    echo "=== $1 ===" >> "$DETAILED_REPORT"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $1" >> "$DETAILED_REPORT"
}

log_alert() {
    echo -e "${RED}[ALERT]${NC} $1"
    echo "[ALERT] $1" >> "$DETAILED_REPORT"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $1" >> "$DETAILED_REPORT"
}

log_findings() {
    echo "$1" >> "$DETAILED_REPORT"
}

create_output_dir() {
    mkdir -p "$OUTPUT_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Cannot create output directory: $OUTPUT_DIR${NC}"
        exit 1
    fi
}

validate_webroot() {
    if [ ! -d "$WEBROOT" ]; then
        echo -e "${RED}ERROR: Web root directory not found: $WEBROOT${NC}"
        exit 1
    fi
    log_info "Web root: $WEBROOT"
}

################################################################################
# SEARCH FUNCTIONS
################################################################################

search_goto_statements() {
    local site_dir="$1"
    local results=$(grep -r "goto " "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_base64_patterns() {
    local site_dir="$1"
    local results=$(grep -r "base64_decode\|gzuncompress\|gzinflate" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_eval_assert() {
    local site_dir="$1"
    local results=$(grep -r "@eval\|@assert\|@system\|@exec\|@passthru" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_non_ascii() {
    local site_dir="$1"
    local results=$(find "$site_dir" -name "*.php" -type f -exec grep -l '[^\x00-\x7F]' {} \; 2>/dev/null)
    echo "$results"
}

search_file_sizes() {
    local site_dir="$1"
    # Search for Monarx signature (17706 bytes) and other suspicious sizes
    local results=$(find "$site_dir" -name "*.php" \( -size 17706c -o -size 1337c -o -size 12345c \) 2>/dev/null)
    echo "$results"
}

search_recently_modified() {
    local site_dir="$1"
    # Files modified in last 7 days
    local results=$(find "$site_dir" -name "*.php" -type f -mtime -7 2>/dev/null | head -20)
    echo "$results"
}

search_preg_replace() {
    local site_dir="$1"
    local results=$(grep -r "preg_replace.*\/e\|/e.*preg_replace" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_dynamic_includes() {
    local site_dir="$1"
    local results=$(grep -r "include.*\$\|require.*\$\|include.*_\|require.*_" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_obfuscated_functions() {
    local site_dir="$1"
    local results=$(grep -r "function \$\|function.*{.*{.*{" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_static_arrays() {
    local site_dir="$1"
    local results=$(grep -r "static.*array\|implode.*array\|strrev\|str_rot13" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_system_commands() {
    local site_dir="$1"
    local results=$(grep -r "system(\|exec(\|shell_exec(\|passthru(\|popen(" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

search_monarx_signature() {
    local site_dir="$1"
    # Monarx uses specific pattern: base64_decode + preg_replace + eval
    local results=$(grep -r "base64_decode.*preg_replace\|preg_replace.*base64_decode" "$site_dir" --include="*.php" 2>/dev/null)
    echo "$results"
}

################################################################################
# SITE ANALYSIS
################################################################################

analyze_site() {
    local site_path="$1"
    local site_name=$(basename "$site_path")
    local site_infected=0
    local site_suspicious=0
    local findings_count=0

    echo ""
    log_header "ANALYZING SITE: $site_name"
    
    # Initialize site report
    echo "" >> "$DETAILED_REPORT"
    echo "========================================" >> "$DETAILED_REPORT"
    echo "SITE: $site_name" >> "$DETAILED_REPORT"
    echo "PATH: $site_path" >> "$DETAILED_REPORT"
    echo "SCAN DATE: $(date)" >> "$DETAILED_REPORT"
    echo "========================================" >> "$DETAILED_REPORT"

    # Check if directory has PHP files
    php_count=$(find "$site_path" -name "*.php" -type f 2>/dev/null | wc -l)
    if [ "$php_count" -eq 0 ]; then
        log_info "No PHP files found in $site_name"
        echo "[INFO] No PHP files in this site" >> "$DETAILED_REPORT"
        return 0
    fi
    log_info "Found $php_count PHP files"

    # ==================== SEARCH 1: GOTO STATEMENTS ====================
    log_warn "SEARCH 1: Goto statements"
    results=$(search_goto_statements "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: Goto statements"
        echo "$results" | while read line; do
            echo "  $line"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 1] GOTO STATEMENTS:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No goto statements"
        echo "[SEARCH 1] GOTO STATEMENTS: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 2: BASE64 PATTERNS ====================
    log_warn "SEARCH 2: Base64 decode patterns"
    results=$(search_base64_patterns "$site_path")
    if [ -n "$results" ]; then
        # Count matches - may be legitimate
        count=$(echo "$results" | wc -l)
        if [ "$count" -gt 20 ]; then
            log_alert "FOUND: $count base64_decode patterns (suspicious)"
            ((site_suspicious++))
        else
            log_warn "  ⚠ Found $count instances (verify legitimacy)"
        fi
        echo "[SEARCH 2] BASE64 PATTERNS: $count matches" >> "$DETAILED_REPORT"
        ((findings_count++))
    else
        log_info "  ✓ No base64 patterns"
        echo "[SEARCH 2] BASE64 PATTERNS: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 3: EVAL/ASSERT/SYSTEM ====================
    log_warn "SEARCH 3: Eval/Assert/System calls"
    results=$(search_eval_assert "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: Code execution functions"
        echo "$results" | head -5 | while read line; do
            echo "  $line"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 3] EVAL/ASSERT/SYSTEM:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No eval/assert/system calls"
        echo "[SEARCH 3] EVAL/ASSERT/SYSTEM: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 4: NON-ASCII CHARACTERS ====================
    log_warn "SEARCH 4: Non-ASCII characters in PHP"
    results=$(search_non_ascii "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: Non-ASCII characters (HIGHLY SUSPICIOUS)"
        echo "$results" | while read line; do
            echo "  $line"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 4] NON-ASCII CHARACTERS:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No non-ASCII characters"
        echo "[SEARCH 4] NON-ASCII CHARACTERS: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 5: SUSPICIOUS FILE SIZES ====================
    log_warn "SEARCH 5: Suspicious file sizes"
    results=$(search_file_sizes "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: Files with suspicious sizes"
        echo "$results" | while read line; do
            filesize=$(stat -f%z "$line" 2>/dev/null || stat -c%s "$line" 2>/dev/null)
            echo "  $line ($filesize bytes)"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 5] SUSPICIOUS FILE SIZES:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No suspicious file sizes"
        echo "[SEARCH 5] SUSPICIOUS FILE SIZES: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 6: RECENTLY MODIFIED ====================
    log_warn "SEARCH 6: Recently modified files (last 7 days)"
    results=$(search_recently_modified "$site_path")
    if [ -n "$results" ]; then
        count=$(echo "$results" | wc -l)
        log_warn "  ⚠ Found $count recently modified files (review manually)"
        echo "[SEARCH 6] RECENTLY MODIFIED (7 days): $count files" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
    else
        log_info "  ✓ No recently modified files"
        echo "[SEARCH 6] RECENTLY MODIFIED: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 7: PREG_REPLACE /e ====================
    log_warn "SEARCH 7: Preg_replace /e (RCE vulnerability)"
    results=$(search_preg_replace "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: preg_replace with /e flag"
        echo "$results" | while read line; do
            echo "  $line"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 7] PREG_REPLACE /e:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No preg_replace /e"
        echo "[SEARCH 7] PREG_REPLACE /e: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 8: DYNAMIC INCLUDES ====================
    log_warn "SEARCH 8: Dynamic include/require statements"
    results=$(search_dynamic_includes "$site_path")
    if [ -n "$results" ]; then
        count=$(echo "$results" | wc -l)
        if [ "$count" -gt 10 ]; then
            log_alert "FOUND: $count dynamic includes (suspicious)"
            ((site_suspicious++))
        else
            log_warn "  ⚠ Found $count dynamic includes"
        fi
        echo "[SEARCH 8] DYNAMIC INCLUDES: $count matches" >> "$DETAILED_REPORT"
        ((findings_count++))
    else
        log_info "  ✓ No dynamic includes"
        echo "[SEARCH 8] DYNAMIC INCLUDES: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 9: OBFUSCATED FUNCTIONS ====================
    log_warn "SEARCH 9: Obfuscated functions"
    results=$(search_obfuscated_functions "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: Obfuscated function definitions"
        echo "$results" | head -3 | while read line; do
            echo "  $line"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 9] OBFUSCATED FUNCTIONS:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No obfuscated functions"
        echo "[SEARCH 9] OBFUSCATED FUNCTIONS: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 10: STATIC ARRAYS ====================
    log_warn "SEARCH 10: Static arrays and string manipulation"
    results=$(search_static_arrays "$site_path")
    if [ -n "$results" ]; then
        count=$(echo "$results" | wc -l)
        if [ "$count" -gt 5 ]; then
            log_warn "  ⚠ Found $count instances of obfuscation techniques"
            echo "[SEARCH 10] STATIC ARRAYS: $count matches" >> "$DETAILED_REPORT"
        fi
        ((findings_count++))
    else
        log_info "  ✓ No suspicious string manipulation"
        echo "[SEARCH 10] STATIC ARRAYS: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SEARCH 11: MONARX SIGNATURE ====================
    log_warn "SEARCH 11: Monarx webshell signature"
    results=$(search_monarx_signature "$site_path")
    if [ -n "$results" ]; then
        log_alert "FOUND: Monarx backdoor pattern detected!"
        echo "$results" | while read line; do
            echo "  $line"
        done
        echo "" >> "$DETAILED_REPORT"
        echo "[SEARCH 11] MONARX SIGNATURE:" >> "$DETAILED_REPORT"
        echo "$results" >> "$DETAILED_REPORT"
        ((findings_count++))
        ((site_infected++))
    else
        log_info "  ✓ No Monarx signature"
        echo "[SEARCH 11] MONARX SIGNATURE: CLEAN" >> "$DETAILED_REPORT"
    fi

    # ==================== SITE SUMMARY ====================
    echo "" >> "$DETAILED_REPORT"
    echo "SITE SUMMARY FOR: $site_name" >> "$DETAILED_REPORT"
    echo "  Total findings: $findings_count" >> "$DETAILED_REPORT"
    echo "  Infected indicators: $site_infected" >> "$DETAILED_REPORT"
    echo "  Suspicious indicators: $site_suspicious" >> "$DETAILED_REPORT"

    if [ "$site_infected" -gt 0 ]; then
        log_alert "SITE STATUS: LIKELY INFECTED ($site_infected infected indicators)"
        echo "$site_name,INFECTED,$site_infected,$site_suspicious" >> "$SUMMARY_REPORT"
        ((INFECTED_SITES++))
        return 1
    elif [ "$site_suspicious" -gt 0 ]; then
        log_warn "SITE STATUS: SUSPICIOUS ($site_suspicious suspicious indicators)"
        echo "$site_name,SUSPICIOUS,$site_infected,$site_suspicious" >> "$SUMMARY_REPORT"
        ((SUSPICIOUS_SITES++))
        return 0
    else
        log_info "SITE STATUS: CLEAN"
        echo "$site_name,CLEAN,0,0" >> "$SUMMARY_REPORT"
        return 0
    fi
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     ATTACK VECTOR HUNT - PER-SITE SCANNER          ║${NC}"
    echo -e "${BLUE}║                                                    ║${NC}"
    echo -e "${BLUE}║  Searching for malware, backdoors, and obfuscation ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Initialize
    create_output_dir
    validate_webroot

    # Create reports
    > "$SUMMARY_REPORT"
    > "$DETAILED_REPORT"

    # Write report headers
    {
        echo "=========================================="
        echo "ATTACK VECTOR HUNT - DETAILED REPORT"
        echo "Scan Date: $(date)"
        echo "Web Root: $WEBROOT"
        echo "=========================================="
        echo ""
    } > "$DETAILED_REPORT"

    {
        echo "SITE_NAME,STATUS,INFECTED_COUNT,SUSPICIOUS_COUNT"
    } > "$SUMMARY_REPORT"

    # Find all site directories (excluding known system directories)
    echo -e "${YELLOW}Finding all site directories...${NC}"
    while IFS= read -r site_path; do
        if [ -d "$site_path" ]; then
            ((TOTAL_SITES++))
            analyze_site "$site_path"
        fi
    done < <(find "$WEBROOT" -maxdepth 1 -type d ! -name "public_html" | tail -n +2 | sort)

    # ==================== FINAL REPORT ====================
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              SCAN COMPLETED                        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Total sites scanned: $TOTAL_SITES"
    echo -e "  ${RED}Infected sites: $INFECTED_SITES${NC}"
    echo -e "  ${YELLOW}Suspicious sites: $SUSPICIOUS_SITES${NC}"
    echo -e "  ${GREEN}Clean sites: $((TOTAL_SITES - INFECTED_SITES - SUSPICIOUS_SITES))${NC}"
    echo ""
    echo "Reports generated:"
    echo "  Summary: $SUMMARY_REPORT"
    echo "  Detailed: $DETAILED_REPORT"
    echo ""

    # Print summary table
    echo -e "${YELLOW}=== QUICK SUMMARY ===${NC}"
    cat "$SUMMARY_REPORT" | column -t -s',' 
    echo ""

    if [ "$INFECTED_SITES" -gt 0 ]; then
        echo -e "${RED}⚠️  WARNING: $INFECTED_SITES infected site(s) detected!${NC}"
        echo "Review the detailed report for remediation steps."
        return 1
    else
        echo -e "${GREEN}✓ No infected sites detected${NC}"
        return 0
    fi
}

# Run main function
main
exit $?
