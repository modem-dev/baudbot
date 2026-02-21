#!/usr/bin/env bash
# startup-cleanup.sh — Clean stale sockets and restart the Slack bridge.
# Run this at the start of every control-agent session.
#
# Usage: bash ~/.pi/agent/skills/control-agent/startup-cleanup.sh <live-session-ids...>
#
# Pass the live session UUIDs (from list_sessions) as arguments.
# Any .sock file whose UUID is NOT in the live set gets removed.
# Stale .alias symlinks pointing to removed sockets also get cleaned.
# Then restarts the slack-bridge tmux session with the current control-agent UUID.

set -euo pipefail

SOCKET_DIR="$HOME/.pi/session-control"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <live-uuid-1> [live-uuid-2] ..."
  echo "Pass the live session UUIDs from list_sessions as arguments."
  exit 1
fi

# Build a set of live UUIDs
declare -A LIVE
for uuid in "$@"; do
  LIVE["$uuid"]=1
done

echo "=== Stale Socket Cleanup ==="
echo "Live sessions: ${!LIVE[*]}"

# Remove stale .sock files
cleaned=0
for sock in "$SOCKET_DIR"/*.sock; do
  [ -e "$sock" ] || continue
  uuid=$(basename "$sock" .sock)
  if [ -z "${LIVE[$uuid]:-}" ]; then
    echo "Removing stale socket: $uuid"
    rm -f "$sock"
    ((cleaned++))
  fi
done

# Remove stale .alias symlinks (pointing to non-existent targets)
for alias in "$SOCKET_DIR"/*.alias; do
  [ -L "$alias" ] || continue
  target=$(readlink "$alias")
  if [ ! -e "$SOCKET_DIR/$target" ]; then
    echo "Removing stale alias: $(basename "$alias") -> $target"
    rm -f "$alias"
  fi
done

echo "Cleaned $cleaned stale socket(s)."

# Restart Slack bridge with current control-agent UUID
echo ""
echo "=== Slack Bridge Restart ==="

# Find control-agent UUID from alias
CONTROL_ALIAS="$SOCKET_DIR/control-agent.alias"
if [ -L "$CONTROL_ALIAS" ]; then
  MY_UUID=$(readlink "$CONTROL_ALIAS" | sed 's/.sock$//')
  echo "Control-agent UUID: $MY_UUID"
else
  echo "ERROR: control-agent.alias not found. Cannot start Slack bridge."
  exit 1
fi

# Kill existing slack-bridge tmux session if running
if tmux has-session -t slack-bridge 2>/dev/null; then
  echo "Killing existing slack-bridge session..."
  tmux kill-session -t slack-bridge
  sleep 1
fi

# Select bridge script: prefer broker pull mode when SLACK_BROKER_* vars are present,
# then Socket Mode when SLACK_BOT_TOKEN + SLACK_APP_TOKEN are present.
# If neither mode is configured, skip bridge startup.
BRIDGE_SCRIPT=""
if [ -f "$HOME/runtime/slack-bridge/broker-bridge.mjs" ] && varlock run --path "$HOME/.config/" -- sh -c '
  test -n "$SLACK_BROKER_URL" &&
  test -n "$SLACK_BROKER_WORKSPACE_ID" &&
  test -n "$SLACK_BROKER_SERVER_PRIVATE_KEY" &&
  test -n "$SLACK_BROKER_SERVER_PUBLIC_KEY" &&
  test -n "$SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY" &&
  test -n "$SLACK_BROKER_PUBLIC_KEY" &&
  test -n "$SLACK_BROKER_SIGNING_PUBLIC_KEY"' 2>/dev/null; then
  BRIDGE_SCRIPT="broker-bridge.mjs"
elif varlock run --path "$HOME/.config/" -- sh -c '
  test -n "$SLACK_BOT_TOKEN" &&
  test -n "$SLACK_APP_TOKEN"' 2>/dev/null; then
  BRIDGE_SCRIPT="bridge.mjs"
fi

if [ -z "$BRIDGE_SCRIPT" ]; then
  echo "No Slack transport configured (missing broker keys and socket tokens); skipping bridge startup."
  echo ""
  echo "=== Cleanup Complete ==="
  exit 0
fi

# Start fresh slack-bridge
echo "Starting slack-bridge ($BRIDGE_SCRIPT) with PI_SESSION_ID=$MY_UUID..."
tmux new-session -d -s slack-bridge \
  "unset PKG_EXECPATH; export PATH=\$HOME/.varlock/bin:\$HOME/opt/node-v22.14.0-linux-x64/bin:\$PATH && export PI_SESSION_ID=$MY_UUID && cd ~/runtime/slack-bridge && exec varlock run --path ~/.config/ -- node $BRIDGE_SCRIPT"

# Wait for bridge to come up
sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7890/send -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "400" ]; then
  echo "✅ Slack bridge is up (HTTP $HTTP_CODE)"
else
  echo "⚠️  Slack bridge may not be ready yet (HTTP $HTTP_CODE). Check manually."
fi

echo ""
echo "=== Cleanup Complete ==="
