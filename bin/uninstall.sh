#!/bin/bash
# Baudbot Agent Uninstall Script
# Reverses everything setup.sh does.
# Run as root: sudo ~/baudbot/bin/uninstall.sh
#
# Flags:
#   --keep-home   Remove user but preserve agent home directory
#   --dry-run     Print what would be done without doing it
#   --yes         Skip confirmation prompt
#
# ⚠️  Keep this in sync with setup.sh — if you add something to setup,
#     add the reverse here.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
bb_enable_strict_mode
bb_init_paths

AGENT_USER="$BAUDBOT_AGENT_USER"
AGENT_HOME="$BAUDBOT_AGENT_HOME"
RELEASE_ROOT="$BAUDBOT_RELEASE_ROOT"

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
      echo "  --keep-home   Remove user but preserve $AGENT_HOME"
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

bb_require_root "uninstall"

REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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
  echo "⚠️  This will remove the $AGENT_USER user and all system-level changes."
  if $KEEP_HOME; then
    echo "   (--keep-home: $AGENT_HOME will be preserved)"
  else
    echo "   ⚠️  $AGENT_HOME will be DELETED (use --keep-home to preserve)"
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

# ── 1. Kill all agent processes ─────────────────────────────────────────────

echo "=== Killing $AGENT_USER processes ==="
if id "$AGENT_USER" &>/dev/null; then
  if pgrep -u "$AGENT_USER" &>/dev/null; then
    run pkill -u "$AGENT_USER" || true
    sleep 1
    # Force kill stragglers
    if pgrep -u "$AGENT_USER" &>/dev/null; then
      run pkill -9 -u "$AGENT_USER" || true
    fi
    removed "$AGENT_USER processes"
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
if id "$AGENT_USER" &>/dev/null; then
  UID_BAUDBOT=$(id -u "$AGENT_USER")
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

echo "=== Removing release snapshots ==="
if [ -d "$RELEASE_ROOT" ]; then
  run rm -rf "$RELEASE_ROOT"
  removed "$RELEASE_ROOT releases"
else
  skipped "$RELEASE_ROOT (not found)"
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
  # Check if anyone else is in the group besides the agent user
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

# ── 9. Remove agent user + home ─────────────────────────────────────────────

echo "=== Removing $AGENT_USER user ==="
if id "$AGENT_USER" &>/dev/null; then
  if $KEEP_HOME; then
    run userdel "$AGENT_USER"
    removed "$AGENT_USER user (home preserved)"
  else
    run userdel -r "$AGENT_USER"
    removed "$AGENT_USER user + $AGENT_HOME"
  fi
else
  skipped "$AGENT_USER user (doesn't exist)"
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
    echo "   $AGENT_HOME was preserved. Remove manually when ready."
  fi
  echo ""
  echo "Remaining manual steps:"
  echo "  - Remove admin user from $AGENT_USER group: gpasswd -d <user> $AGENT_USER"
  echo "    (or log out and back in — group was deleted)"
  echo "  - The source repo ($REPO_DIR) was not removed."
fi
