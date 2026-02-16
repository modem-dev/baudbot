#!/bin/bash
# Deploy extensions and bridge from hornet source to agent runtime.
#
# Run as root (or bentlegen with sudo) after any admin change to ~/hornet/.
# This copies files from the read-only source repo to their runtime locations,
# setting appropriate ownership:
#   - Security-critical files → root:hornet_agent 644 (agent can read, not write)
#   - Agent-modifiable files → hornet_agent:hornet_agent 664
#
# Usage:
#   sudo ~/hornet/bin/deploy.sh           # deploy all
#   sudo ~/hornet/bin/deploy.sh --dry-run # show what would change
#
# After deploy, restart the bridge if it's running:
#   sudo -u hornet_agent bash -c 'tmux send-keys -t bridge C-c; sleep 1; tmux send-keys -t bridge "cd ~/runtime/slack-bridge && node bridge.mjs" Enter'

set -euo pipefail

HORNET_SRC="/home/hornet_agent/hornet"
AGENT_HOME="/home/hornet_agent"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

log() { echo "  $1"; }

deploy_file() {
  local src="$1"
  local dest="$2"
  local owner="$3"
  local mode="$4"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would copy: $src → $dest ($owner, $mode)"
    return
  fi
  cp -a "$src" "$dest"
  chown "$owner" "$dest"
  chmod "$mode" "$dest"
  log "✓ $(basename "$dest") ($owner, $mode)"
}

# ── Extensions ───────────────────────────────────────────────────────────────

echo "Deploying extensions..."

# Security-critical extensions — root-owned, agent can read but not write
PROTECTED_EXTENSIONS=(
  "tool-guard.ts"
  "tool-guard.test.mjs"
)

# Agent-modifiable extensions — hornet_agent-owned
AGENT_EXTENSIONS=(
  "auto-name.ts"
  "zen-provider.ts"
  "sentry-monitor.ts"
)

EXT_SRC="$HORNET_SRC/pi/extensions"
EXT_DEST="$AGENT_HOME/.pi/agent/extensions"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$EXT_DEST"
fi

# Deploy all extension files and subdirectories
for ext in "$EXT_SRC"/*; do
  base=$(basename "$ext")

  # Skip node_modules — those are built in-place
  [ "$base" = "node_modules" ] && continue

  if [ -d "$ext" ]; then
    # Extension subdirectory (agentmail, kernel, email-monitor)
    if [ "$DRY_RUN" -eq 0 ]; then
      rsync -a --delete "$ext/" "$EXT_DEST/$base/"
      chown -R hornet_agent:hornet_agent "$EXT_DEST/$base/"
      log "✓ $base/ (hornet_agent:hornet_agent)"
    else
      log "would rsync: $ext/ → $EXT_DEST/$base/ (hornet_agent:hornet_agent)"
    fi
    continue
  fi

  # Check if this is a protected extension
  is_protected=0
  for pf in "${PROTECTED_EXTENSIONS[@]}"; do
    if [ "$base" = "$pf" ]; then
      is_protected=1
      break
    fi
  done

  if [ "$is_protected" -eq 1 ]; then
    deploy_file "$ext" "$EXT_DEST/$base" "root:hornet_agent" "644"
  else
    deploy_file "$ext" "$EXT_DEST/$base" "hornet_agent:hornet_agent" "664"
  fi
done

# ── Skills ───────────────────────────────────────────────────────────────────

echo "Deploying skills..."

SKILLS_SRC="$HORNET_SRC/pi/skills"
SKILLS_DEST="$AGENT_HOME/.pi/agent/skills"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$SKILLS_DEST"
  rsync -a "$SKILLS_SRC/" "$SKILLS_DEST/"
  chown -R hornet_agent:hornet_agent "$SKILLS_DEST/"
  log "✓ skills/ (hornet_agent:hornet_agent)"
else
  log "would rsync: $SKILLS_SRC/ → $SKILLS_DEST/ (hornet_agent:hornet_agent)"
fi

# ── Slack Bridge ─────────────────────────────────────────────────────────────

echo "Deploying slack-bridge runtime..."

BRIDGE_SRC="$HORNET_SRC/slack-bridge"
BRIDGE_DEST="$AGENT_HOME/runtime/slack-bridge"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BRIDGE_DEST"
  rsync -a "$BRIDGE_SRC/" "$BRIDGE_DEST/"

  # Security module — root-owned, agent cannot modify
  chown root:hornet_agent "$BRIDGE_DEST/security.mjs"
  chmod 644 "$BRIDGE_DEST/security.mjs"
  log "✓ security.mjs (root:hornet_agent, 644)"

  # Security tests — root-owned
  if [ -f "$BRIDGE_DEST/security.test.mjs" ]; then
    chown root:hornet_agent "$BRIDGE_DEST/security.test.mjs"
    chmod 644 "$BRIDGE_DEST/security.test.mjs"
    log "✓ security.test.mjs (root:hornet_agent, 644)"
  fi

  # Bridge logic — agent-modifiable
  chown hornet_agent:hornet_agent "$BRIDGE_DEST/bridge.mjs"
  chmod 664 "$BRIDGE_DEST/bridge.mjs"
  log "✓ bridge.mjs (hornet_agent:hornet_agent, 664)"

  # Package files and node_modules — agent-owned
  chown -R hornet_agent:hornet_agent "$BRIDGE_DEST/node_modules" 2>/dev/null || true
  for pf in package.json package-lock.json; do
    [ -f "$BRIDGE_DEST/$pf" ] && chown hornet_agent:hornet_agent "$BRIDGE_DEST/$pf"
  done
  log "✓ node_modules/ + package files (hornet_agent:hornet_agent)"
else
  log "would rsync: $BRIDGE_SRC/ → $BRIDGE_DEST/"
  log "would set security.mjs → root:hornet_agent 644"
  log "would set bridge.mjs → hornet_agent:hornet_agent 664"
fi

# ── Settings ─────────────────────────────────────────────────────────────────

echo "Deploying settings..."

if [ -f "$HORNET_SRC/pi/settings.json" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    cp "$HORNET_SRC/pi/settings.json" "$AGENT_HOME/.pi/agent/settings.json"
    chown hornet_agent:hornet_agent "$AGENT_HOME/.pi/agent/settings.json"
    chmod 600 "$AGENT_HOME/.pi/agent/settings.json"
    log "✓ settings.json (hornet_agent:hornet_agent, 600)"
  else
    log "would copy settings.json"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "🔍 Dry run complete — no changes made."
else
  echo "✅ Deploy complete."
  echo ""
  echo "If the slack bridge is running, restart it:"
  echo "  sudo -u hornet_agent bash -c 'cd ~/runtime/slack-bridge && node bridge.mjs'"
fi
