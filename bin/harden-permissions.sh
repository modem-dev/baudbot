#!/bin/bash
# Harden filesystem permissions for baudbot_agent
# Run as baudbot_agent (or via: sudo -u baudbot_agent ~/baudbot/bin/harden-permissions.sh)
#
# Pi creates session logs, control sockets, and settings with permissive defaults
# (644/755). This locks them down to owner-only so group members can't read
# agent conversations or connect to control sockets.

set -euo pipefail

changed=0

fix_dir() {
  local target="$1"
  local mode="$2"
  if [ -d "$target" ]; then
    current=$(stat -c '%a' "$target")
    if [ "$current" != "$mode" ]; then
      chmod "$mode" "$target"
      echo "  ✓ $target ($current → $mode)"
      changed=$((changed + 1))
    fi
  fi
}

fix_file() {
  local target="$1"
  local mode="$2"
  if [ -f "$target" ]; then
    current=$(stat -c '%a' "$target")
    if [ "$current" != "$mode" ]; then
      chmod "$mode" "$target"
      echo "  ✓ $target ($current → $mode)"
      changed=$((changed + 1))
    fi
  fi
}

echo "🔒 Hardening baudbot_agent permissions..."

# Pi state directories — restrict to owner only
fix_dir "$HOME/.pi" "700"
fix_dir "$HOME/.pi/agent" "700"
fix_dir "$HOME/.pi/session-control" "700"

# Pi session directories
if [ -d "$HOME/.pi/agent/sessions" ]; then
  fix_dir "$HOME/.pi/agent/sessions" "700"
  # Lock down each session subdirectory
  find "$HOME/.pi/agent/sessions" -mindepth 1 -maxdepth 1 -type d -exec chmod 700 {} +
fi

# Session logs (full conversation history)
if [ -d "$HOME/.pi/agent/sessions" ]; then
  find "$HOME/.pi/agent/sessions" -name '*.jsonl' -not -perm 600 -exec chmod 600 {} + 2>/dev/null || true
  count=$(find "$HOME/.pi/agent/sessions" -name '*.jsonl' 2>/dev/null | wc -l)
  [ "$count" -gt 0 ] && echo "  ✓ $count session log(s) → 600"
fi

# Pi settings
fix_file "$HOME/.pi/agent/settings.json" "600"

# Secrets
fix_file "$HOME/.config/.env" "600"

# SSH (should already be correct from setup.sh)
fix_dir "$HOME/.ssh" "700"
find "$HOME/.ssh" -name 'id_*' -not -name '*.pub' -exec chmod 600 {} + 2>/dev/null

# Runtime directories
fix_dir "$HOME/runtime" "750"

if [ "$changed" -eq 0 ]; then
  echo "  ✓ All permissions already correct"
fi

echo "🔒 Done."
