#!/bin/bash
# =============================================================================
# Graywell Wordfence Reinstall + Sucuri Removal
# For each WordPress site under ROOT_DIR:
#   1. Deactivates and uninstalls Wordfence (removes all data/tables)
#   2. Deactivates and uninstalls Sucuri Security
#   3. Installs a fresh copy of Wordfence and activates it
#
# Usage:
#   bash reinstall_wordfence.sh [--root <path>] [--only <site>] [--dry-run]
#
# Examples:
#   bash reinstall_wordfence.sh
#   bash reinstall_wordfence.sh --dry-run
#   bash reinstall_wordfence.sh --only acakebakedinbrooklyn.com
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
ROOT_DIR="${HOME}/public_html"
ONLY_SITE=""
DRY_RUN=false
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

if [[ -w "$HOME" ]]; then
  LOG_DIR="$HOME/malware_scan_logs"
elif [[ -w /tmp ]]; then
  LOG_DIR="/tmp/malware_scan_logs"
else
  LOG_DIR="."
fi

SUMMARY_FILE="${LOG_DIR}/wordfence_reinstall_${TIMESTAMP}.txt"
mkdir -p "$LOG_DIR"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    ROOT_DIR="$2"; shift 2 ;;
    --only)    ONLY_SITE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: bash reinstall_wordfence.sh [options]"
      echo "  --root <path>   Root directory containing site folders (default: ~/public_html)"
      echo "  --only <site>   Only process one site folder by name"
      echo "  --dry-run       Show what would happen without making changes"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
if ! command -v wp &>/dev/null; then
  echo "ERROR: WP-CLI not found. Install it or add it to PATH."
  exit 1
fi

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "ERROR: Root directory not found: ${ROOT_DIR}"
  exit 1
fi

# ── Discover WordPress sites ──────────────────────────────────────────────────
SITE_DIRS=()

if [[ -f "${ROOT_DIR}/wp-config.php" ]]; then
  SITE_DIRS+=("$ROOT_DIR")
fi

while IFS= read -r subdir; do
  [[ -d "$subdir" ]] || continue
  name=$(basename "$subdir")
  [[ "$name" == .* ]]        && continue
  [[ "$name" == "cgi-bin" ]] && continue
  [[ "$name" == "tmp" ]]     && continue
  [[ "$name" == "logs" ]]    && continue
  [[ "$name" == "mail" ]]    && continue
  [[ "$name" == "etc" ]]     && continue
  [[ "$name" == "scripts" ]] && continue

  if [[ -n "$ONLY_SITE" && "$name" != "$ONLY_SITE" ]]; then
    continue
  fi

  if [[ -f "${subdir}/wp-config.php" ]] || [[ -d "${subdir}/wp-content" ]]; then
    SITE_DIRS+=("$subdir")
  fi
done < <(find "$ROOT_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

if [[ ${#SITE_DIRS[@]} -eq 0 ]]; then
  echo "No WordPress site directories found under: ${ROOT_DIR}"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
WP() {
  # Wrapper: prints command, skips execution in dry-run mode
  local path="$1"; shift
  if $DRY_RUN; then
    echo "   [DRY RUN] wp --path=${path} $*"
  else
    wp --path="$path" --allow-root "$@" 2>&1
  fi
}

plugin_is_installed() {
  local path="$1" slug="$2"
  wp --path="$path" --allow-root plugin list --field=name 2>/dev/null | grep -qx "$slug"
}

# ── Process sites ─────────────────────────────────────────────────────────────
TOTAL=${#SITE_DIRS[@]}
DONE=0
FAILED=0
IDX=0

echo "════════════════════════════════════════════════"
echo " Graywell Wordfence Reinstall + Sucuri Removal"
echo " Root:   ${ROOT_DIR}"
echo " Sites:  ${TOTAL}"
$DRY_RUN && echo " Mode:   DRY RUN — no changes will be made"
echo " Log:    ${SUMMARY_FILE}"
echo "════════════════════════════════════════════════"
echo ""

{
  echo "Wordfence Reinstall + Sucuri Removal — ${TIMESTAMP}"
  $DRY_RUN && echo "DRY RUN MODE"
  echo "Sites: ${TOTAL}"
  echo ""
} > "$SUMMARY_FILE"

for site_dir in "${SITE_DIRS[@]}"; do
  ((IDX++))
  site_name=$(basename "$site_dir")
  SITE_LOG="${LOG_DIR}/wordfence_${site_name}_${TIMESTAMP}.log"
  SITE_STATUS="OK"

  echo "[$IDX/$TOTAL] ${site_name}"
  {
    echo "══ ${site_name} ══"
    echo "Path: ${site_dir}"
    echo ""
  } | tee -a "$SITE_LOG"

  # Verify WP install is accessible
  if ! wp --path="$site_dir" --allow-root core is-installed 2>/dev/null; then
    echo "   ⚠  Skipping — WP not accessible at this path"
    echo "SKIP    ${site_name} — WP not accessible" >> "$SUMMARY_FILE"
    echo ""
    continue
  fi

  # ── Step 1: Remove Wordfence ────────────────────────────────────────────────
  echo "   → Removing Wordfence..." | tee -a "$SITE_LOG"
  if plugin_is_installed "$site_dir" "wordfence" || $DRY_RUN; then
    # Deactivate first (suppress errors if already inactive)
    WP "$site_dir" plugin deactivate wordfence 2>/dev/null | tee -a "$SITE_LOG" || true
    # Delete with --deactivate in case it's network-active; then delete
    WP "$site_dir" plugin delete wordfence | tee -a "$SITE_LOG" || SITE_STATUS="WARN"
    # Remove leftover Wordfence data files that plugin delete misses
    if ! $DRY_RUN; then
      rm -rf "${site_dir}/wp-content/wflogs" 2>/dev/null && \
        echo "   Removed: wp-content/wflogs" | tee -a "$SITE_LOG" || true
      rm -f "${site_dir}/wp-content/plugins/wordfence/"*.php 2>/dev/null || true
    else
      echo "   [DRY RUN] Would remove: wp-content/wflogs" | tee -a "$SITE_LOG"
    fi
    echo "   ✓ Wordfence removed" | tee -a "$SITE_LOG"
  else
    echo "   (Wordfence not installed — skipping removal)" | tee -a "$SITE_LOG"
  fi

  # ── Step 2: Remove Sucuri ───────────────────────────────────────────────────
  echo "   → Removing Sucuri Security..." | tee -a "$SITE_LOG"
  SUCURI_SLUGS=("sucuri-scanner" "sucuri-security" "sucuri")
  SUCURI_FOUND=false
  for slug in "${SUCURI_SLUGS[@]}"; do
    if plugin_is_installed "$site_dir" "$slug" || $DRY_RUN; then
      WP "$site_dir" plugin deactivate "$slug" 2>/dev/null | tee -a "$SITE_LOG" || true
      WP "$site_dir" plugin delete "$slug" | tee -a "$SITE_LOG" || SITE_STATUS="WARN"
      SUCURI_FOUND=true
      echo "   ✓ Sucuri (${slug}) removed" | tee -a "$SITE_LOG"
      break
    fi
  done
  if ! $SUCURI_FOUND && ! $DRY_RUN; then
    echo "   (Sucuri not installed — skipping)" | tee -a "$SITE_LOG"
  fi

  # ── Step 3: Clean up any Sucuri leftover files ──────────────────────────────
  if ! $DRY_RUN; then
    rm -rf "${site_dir}/wp-content/uploads/sucuri" 2>/dev/null || true
    rm -f "${site_dir}/.sucuri-"* 2>/dev/null || true
  else
    echo "   [DRY RUN] Would remove Sucuri leftover data" | tee -a "$SITE_LOG"
  fi

  # ── Step 4: Install fresh Wordfence ─────────────────────────────────────────
  echo "   → Installing fresh Wordfence..." | tee -a "$SITE_LOG"
  if WP "$site_dir" plugin install wordfence --activate | tee -a "$SITE_LOG"; then
    echo "   ✓ Wordfence installed and activated" | tee -a "$SITE_LOG"
    ((DONE++))
    echo "OK      ${site_name}" >> "$SUMMARY_FILE"
  else
    echo "   ✗ Wordfence install FAILED — check log: ${SITE_LOG}" | tee -a "$SITE_LOG"
    SITE_STATUS="FAIL"
    ((FAILED++))
    echo "FAIL    ${site_name} — install failed — ${SITE_LOG}" >> "$SUMMARY_FILE"
  fi

  echo ""
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════"
echo " DONE"
echo " Completed: ${DONE}/${TOTAL}"
echo " Failed:    ${FAILED}/${TOTAL}"
echo " Summary:   ${SUMMARY_FILE}"
echo " All logs:  ${LOG_DIR}/"
echo "════════════════════════════════════════════════"

{
  echo ""
  echo "────────────────────────────────────────────────"
  echo "TOTALS"
  echo "  Completed: ${DONE}/${TOTAL}"
  echo "  Failed:    ${FAILED}/${TOTAL}"
} >> "$SUMMARY_FILE"

[[ $FAILED -gt 0 ]] && exit 1
exit 0