#!/bin/bash
# Baudbot Agent Uninstall Script
# Reverses everything setup.sh does.
# Run as root: sudo ~/baudbot/bin/uninstall.sh
#
# Flags:
#   --keep-home   Remove user but preserve /home/baudbot_agent
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
      echo "  --keep-home   Remove user but preserve /home/baudbot_agent"
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
  echo "⚠️  This will remove the baudbot_agent user and all system-level changes."
  if $KEEP_HOME; then
    echo "   (--keep-home: /home/baudbot_agent will be preserved)"
  else
    echo "   ⚠️  /home/baudbot_agent will be DELETED (use --keep-home to preserve)"
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

# ── 1. Kill all baudbot_agent processes ───────────────────────────────────────

echo "=== Killing baudbot_agent processes ==="
if id baudbot_agent &>/dev/null; then
  if pgrep -u baudbot_agent &>/dev/null; then
    run pkill -u baudbot_agent || true
    sleep 1
    # Force kill stragglers
    if pgrep -u baudbot_agent &>/dev/null; then
      run pkill -9 -u baudbot_agent || true
    fi
    removed "baudbot_agent processes"
  else
    skipped "processes (none running)"
  fi
else
  skipped "processes (user doesn't exist)"
fi

# ── 2. Stop + remove firewall service ───────────────────────────────────────

echo "=== Removing firewall service ==="
if systemctl is-enabled baudbot-firewall &>/dev/null 2>&1; then
  run systemctl stop baudbot-firewall || true
  run systemctl disable baudbot-firewall
  removed "baudbot-firewall service (disabled)"
else
  skipped "baudbot-firewall service (not enabled)"
fi

if [ -f /etc/systemd/system/baudbot-firewall.service ]; then
  run rm -f /etc/systemd/system/baudbot-firewall.service
  run systemctl daemon-reload
  removed "baudbot-firewall.service unit file"
else
  skipped "baudbot-firewall.service (not found)"
fi

# ── 3. Flush iptables rules ─────────────────────────────────────────────────

echo "=== Removing iptables rules ==="
if id baudbot_agent &>/dev/null; then
  UID_BAUDBOT=$(id -u baudbot_agent)
  if iptables -w -L BAUDBOT_OUTPUT -n &>/dev/null 2>&1; then
    run iptables -w -D OUTPUT -m owner --uid-owner "$UID_BAUDBOT" -j BAUDBOT_OUTPUT 2>/dev/null || true
    run iptables -w -F BAUDBOT_OUTPUT
    run iptables -w -X BAUDBOT_OUTPUT
    removed "iptables BAUDBOT_OUTPUT chain"
  else
    skipped "iptables (BAUDBOT_OUTPUT chain not found)"
  fi
else
  # User already gone — try to clean up chain by name
  if iptables -w -L BAUDBOT_OUTPUT -n &>/dev/null 2>&1; then
    # Can't match by UID, but can still flush the chain
    # Remove any OUTPUT jumps to BAUDBOT_OUTPUT
    while iptables -w -D OUTPUT -j BAUDBOT_OUTPUT 2>/dev/null; do :; done
    run iptables -w -F BAUDBOT_OUTPUT
    run iptables -w -X BAUDBOT_OUTPUT
    removed "iptables BAUDBOT_OUTPUT chain (orphaned)"
  else
    skipped "iptables (BAUDBOT_OUTPUT chain not found)"
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

echo "=== Removing baudbot systemd unit ==="
if systemctl is-enabled baudbot &>/dev/null 2>&1; then
  run systemctl stop baudbot || true
  run systemctl disable baudbot
  removed "baudbot service (stopped + disabled)"
else
  skipped "baudbot service (not enabled)"
fi

if [ -f /etc/systemd/system/baudbot.service ]; then
  run rm -f /etc/systemd/system/baudbot.service
  run systemctl daemon-reload
  removed "baudbot.service unit file"
else
  skipped "baudbot.service (not found)"
fi

echo "=== Removing baudbot CLI ==="
if [ -L /usr/local/bin/baudbot ]; then
  run rm -f /usr/local/bin/baudbot
  removed "/usr/local/bin/baudbot symlink"
elif [ -f /usr/local/bin/baudbot ]; then
  run rm -f /usr/local/bin/baudbot
  removed "/usr/local/bin/baudbot"
else
  skipped "/usr/local/bin/baudbot (not found)"
fi

echo "=== Removing /opt release snapshots ==="
if [ -d /opt/baudbot ]; then
  run rm -rf /opt/baudbot
  removed "/opt/baudbot releases"
else
  skipped "/opt/baudbot (not found)"
fi

echo "=== Removing sudoers ==="
if [ -f /etc/sudoers.d/baudbot-agent ]; then
  run rm -f /etc/sudoers.d/baudbot-agent
  removed "/etc/sudoers.d/baudbot-agent"
else
  skipped "sudoers (not found)"
fi

# ── 6. Remove /usr/local/bin wrappers ───────────────────────────────────────

echo "=== Removing system wrappers ==="
for bin in baudbot-docker baudbot-safe-bash; do
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
  # Check if anyone else is in the group besides baudbot_agent
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

# ── 9. Remove baudbot_agent user + home ───────────────────────────────────────

echo "=== Removing baudbot_agent user ==="
if id baudbot_agent &>/dev/null; then
  if $KEEP_HOME; then
    run userdel baudbot_agent
    removed "baudbot_agent user (home preserved)"
  else
    run userdel -r baudbot_agent
    removed "baudbot_agent user + /home/baudbot_agent"
  fi
else
  skipped "baudbot_agent user (doesn't exist)"
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
    echo "   /home/baudbot_agent was preserved. Remove manually when ready."
  fi
  echo ""
  echo "Remaining manual steps:"
  echo "  - Remove admin user from baudbot_agent group: gpasswd -d <user> baudbot_agent"
  echo "    (or log out and back in — group was deleted)"
  echo "  - The source repo ($REPO_DIR) was not removed."
fi
