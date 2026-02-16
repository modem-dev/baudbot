#!/bin/bash
# Hornet Agent Uninstall Script
# Reverses everything setup.sh does.
# Run as root: sudo ~/hornet/bin/uninstall.sh
#
# Flags:
#   --keep-home   Remove user but preserve /home/hornet_agent
#   --dry-run     Print what would be done without doing it
#   --yes         Skip confirmation prompt
#
# ⚠️  Keep this in sync with setup.sh — if you add something to setup,
#     add the reverse here.

set -euo pipefail

KEEP_HOME=false
DRY_RUN=false
AUTO_YES=false

for arg in "$@"; do
  case "$arg" in
    --keep-home) KEEP_HOME=true ;;
    --dry-run)   DRY_RUN=true ;;
    --yes)       AUTO_YES=true ;;
    -h|--help)
      echo "Usage: sudo $0 [--keep-home] [--dry-run] [--yes]"
      echo ""
      echo "  --keep-home   Remove user but preserve /home/hornet_agent"
      echo "  --dry-run     Print what would be done without doing it"
      echo "  --yes         Skip confirmation prompt"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Must run as root (sudo $0)"
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOVED=()
SKIPPED=()

run() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

removed() { REMOVED+=("$1"); }
skipped() { SKIPPED+=("$1"); }

# ── Confirmation ─────────────────────────────────────────────────────────────

if ! $AUTO_YES && ! $DRY_RUN; then
  echo "⚠️  This will remove the hornet_agent user and all system-level changes."
  if $KEEP_HOME; then
    echo "   (--keep-home: /home/hornet_agent will be preserved)"
  else
    echo "   ⚠️  /home/hornet_agent will be DELETED (use --keep-home to preserve)"
  fi
  echo ""
  read -rp "Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
if $DRY_RUN; then
  echo "=== Dry run — no changes will be made ==="
  echo ""
fi

# ── 1. Kill all hornet_agent processes ───────────────────────────────────────

echo "=== Killing hornet_agent processes ==="
if id hornet_agent &>/dev/null; then
  if pgrep -u hornet_agent &>/dev/null; then
    run pkill -u hornet_agent || true
    sleep 1
    # Force kill stragglers
    if pgrep -u hornet_agent &>/dev/null; then
      run pkill -9 -u hornet_agent || true
    fi
    removed "hornet_agent processes"
  else
    skipped "processes (none running)"
  fi
else
  skipped "processes (user doesn't exist)"
fi

# ── 2. Stop + remove firewall service ───────────────────────────────────────

echo "=== Removing firewall service ==="
if systemctl is-enabled hornet-firewall &>/dev/null 2>&1; then
  run systemctl stop hornet-firewall || true
  run systemctl disable hornet-firewall
  removed "hornet-firewall service (disabled)"
else
  skipped "hornet-firewall service (not enabled)"
fi

if [ -f /etc/systemd/system/hornet-firewall.service ]; then
  run rm -f /etc/systemd/system/hornet-firewall.service
  run systemctl daemon-reload
  removed "hornet-firewall.service unit file"
else
  skipped "hornet-firewall.service (not found)"
fi

# ── 3. Flush iptables rules ─────────────────────────────────────────────────

echo "=== Removing iptables rules ==="
if id hornet_agent &>/dev/null; then
  UID_HORNET=$(id -u hornet_agent)
  if iptables -w -L HORNET_OUTPUT -n &>/dev/null 2>&1; then
    run iptables -w -D OUTPUT -m owner --uid-owner "$UID_HORNET" -j HORNET_OUTPUT 2>/dev/null || true
    run iptables -w -F HORNET_OUTPUT
    run iptables -w -X HORNET_OUTPUT
    removed "iptables HORNET_OUTPUT chain"
  else
    skipped "iptables (HORNET_OUTPUT chain not found)"
  fi
else
  # User already gone — try to clean up chain by name
  if iptables -w -L HORNET_OUTPUT -n &>/dev/null 2>&1; then
    # Can't match by UID, but can still flush the chain
    # Remove any OUTPUT jumps to HORNET_OUTPUT
    while iptables -w -D OUTPUT -j HORNET_OUTPUT 2>/dev/null; do :; done
    run iptables -w -F HORNET_OUTPUT
    run iptables -w -X HORNET_OUTPUT
    removed "iptables HORNET_OUTPUT chain (orphaned)"
  else
    skipped "iptables (HORNET_OUTPUT chain not found)"
  fi
fi

# ── 4. Restore /proc (remove hidepid) ───────────────────────────────────────

echo "=== Restoring /proc mount ==="
if mount | grep -q 'hidepid=2'; then
  run mount -o remount,hidepid=0 /proc
  removed "/proc hidepid=2 (remounted default)"
else
  skipped "/proc (hidepid not active)"
fi

if grep -q 'hidepid=2' /etc/fstab 2>/dev/null; then
  if ! $DRY_RUN; then
    sed -i '/^proc.*hidepid=2/d' /etc/fstab
  else
    echo "  [dry-run] sed -i '/^proc.*hidepid=2/d' /etc/fstab"
  fi
  removed "/etc/fstab hidepid entry"
else
  skipped "/etc/fstab (no hidepid entry)"
fi

# ── 5. Remove sudoers ───────────────────────────────────────────────────────

echo "=== Removing sudoers ==="
if [ -f /etc/sudoers.d/hornet-agent ]; then
  run rm -f /etc/sudoers.d/hornet-agent
  removed "/etc/sudoers.d/hornet-agent"
else
  skipped "sudoers (not found)"
fi

# ── 6. Remove /usr/local/bin wrappers ───────────────────────────────────────

echo "=== Removing system wrappers ==="
for bin in hornet-docker hornet-safe-bash; do
  if [ -f "/usr/local/bin/$bin" ]; then
    run rm -f "/usr/local/bin/$bin"
    removed "/usr/local/bin/$bin"
  else
    skipped "/usr/local/bin/$bin (not found)"
  fi
done

# ── 7. Remove procview group ────────────────────────────────────────────────

echo "=== Removing procview group ==="
if getent group procview &>/dev/null; then
  # Check if anyone else is in the group besides hornet_agent
  members=$(getent group procview | cut -d: -f4)
  if [ -n "$members" ]; then
    echo "  ⚠️  procview group has members: $members"
    echo "  Removing group (members will lose membership)"
  fi
  run groupdel procview
  removed "procview group"
else
  skipped "procview group (not found)"
fi

# ── 8. Remove pre-commit hook ───────────────────────────────────────────────

echo "=== Removing pre-commit hook ==="
HOOK="$REPO_DIR/.git/hooks/pre-commit"
if [ -f "$HOOK" ]; then
  # Only remove if it's root-owned (ours)
  if [ "$(stat -c %u "$HOOK")" = "0" ]; then
    run rm -f "$HOOK"
    removed "root-owned pre-commit hook"
  else
    skipped "pre-commit hook (not root-owned, probably user's)"
  fi
else
  skipped "pre-commit hook (not found)"
fi

# ── 9. Remove hornet_agent user + home ───────────────────────────────────────

echo "=== Removing hornet_agent user ==="
if id hornet_agent &>/dev/null; then
  if $KEEP_HOME; then
    run userdel hornet_agent
    removed "hornet_agent user (home preserved)"
  else
    run userdel -r hornet_agent
    removed "hornet_agent user + /home/hornet_agent"
  fi
else
  skipped "hornet_agent user (doesn't exist)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
if [ ${#REMOVED[@]} -gt 0 ]; then
  echo ""
  if $DRY_RUN; then
    echo "Would remove:"
  else
    echo "Removed:"
  fi
  for item in "${REMOVED[@]}"; do
    echo "  ✓ $item"
  done
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo ""
  echo "Skipped (already clean):"
  for item in "${SKIPPED[@]}"; do
    echo "  - $item"
  done
fi

echo ""
if $DRY_RUN; then
  echo "🔍 Dry run complete. Run without --dry-run to apply."
else
  echo "✅ Uninstall complete."
  if $KEEP_HOME; then
    echo "   /home/hornet_agent was preserved. Remove manually when ready."
  fi
  echo ""
  echo "Remaining manual steps:"
  echo "  - Remove admin user from hornet_agent group: gpasswd -d <user> hornet_agent"
  echo "    (or log out and back in — group was deleted)"
  echo "  - The source repo ($REPO_DIR) was not removed."
fi
