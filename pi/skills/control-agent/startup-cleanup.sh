#!/usr/bin/env bash
# startup-cleanup.sh — Clean stale sockets and restart the Slack bridge.
# Run this at the start of every control-agent session.
#
# Usage: bash ~/.pi/agent/skills/control-agent/startup-cleanup.sh <live-session-ids...>
#
# Pass the live session UUIDs (from list_sessions) as arguments.
# Any .sock file whose UUID is NOT in the live set gets removed.
# Stale .alias symlinks pointing to removed sockets also get cleaned.
# Then restarts the slack-bridge process with the current control-agent UUID.

set -euo pipefail

BRIDGE_POLICY_HELPER="$HOME/runtime/bin/lib/bridge-restart-policy.sh"
if [ -r "$BRIDGE_POLICY_HELPER" ]; then
  # shellcheck source=bin/lib/bridge-restart-policy.sh
  source "$BRIDGE_POLICY_HELPER"
fi

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

BRIDGE_PID_FILE="$HOME/.pi/agent/slack-bridge.pid"
BRIDGE_LOG_DIR="$HOME/.pi/agent/logs"
BRIDGE_LOG_FILE="$BRIDGE_LOG_DIR/slack-bridge.log"
BRIDGE_STATUS_FILE="$HOME/.pi/agent/slack-bridge-supervisor.json"

kill_bridge_supervisor() {
  local bridge_pid="$1"
  [ -n "$bridge_pid" ] || return 0
  if ! kill -0 "$bridge_pid" 2>/dev/null; then
    return 0
  fi

  # Best-effort: terminate direct children first so no stale bridge process keeps the port.
  local bridge_child_pids
  bridge_child_pids="$(pgrep -P "$bridge_pid" 2>/dev/null || true)"
  if [ -n "$bridge_child_pids" ]; then
    kill $bridge_child_pids 2>/dev/null || true
    sleep 1
    kill -9 $bridge_child_pids 2>/dev/null || true
  fi

  kill "$bridge_pid" 2>/dev/null || true
  sleep 1
  kill -9 "$bridge_pid" 2>/dev/null || true
}

# Kill existing slack-bridge process if running
if [ -f "$BRIDGE_PID_FILE" ]; then
  BRIDGE_PID="$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)"
  if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "Killing existing slack-bridge process (pid=$BRIDGE_PID)..."
    kill_bridge_supervisor "$BRIDGE_PID"
  fi
  rm -f "$BRIDGE_PID_FILE"
fi

# Select bridge script: prefer broker pull mode when SLACK_BROKER_* vars are present,
# then Socket Mode when SLACK_BOT_TOKEN + SLACK_APP_TOKEN are present.
# If neither mode is configured, skip bridge startup.
BRIDGE_SCRIPT=""
if [ -f "/opt/baudbot/current/slack-bridge/broker-bridge.mjs" ] && varlock run --path "$HOME/.config/" -- sh -c '
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
# Keep a supervisor loop (matching start.sh) so bridge restarts automatically on crash.
echo "Starting slack-bridge ($BRIDGE_SCRIPT) with PI_SESSION_ID=$MY_UUID..."
mkdir -p "$BRIDGE_LOG_DIR"
(
  unset PKG_EXECPATH
  export PATH="$HOME/.varlock/bin:$HOME/opt/node/bin:$PATH"
  export PI_SESSION_ID="$MY_UUID"
  cd /opt/baudbot/current/slack-bridge

  if command -v bb_bridge_supervise >/dev/null 2>&1; then
    bb_bridge_supervise "$BRIDGE_LOG_FILE" "$BRIDGE_STATUS_FILE" "$BRIDGE_SCRIPT" \
      varlock run --path ~/.config/ -- node "$BRIDGE_SCRIPT"
  else
    while true; do
      if varlock run --path ~/.config/ -- node "$BRIDGE_SCRIPT" >>"$BRIDGE_LOG_FILE" 2>&1; then
        exit_code=0
      else
        exit_code=$?
      fi
      echo "[$(date -Is)] bridge-supervisor event=restart_scheduled mode=legacy script=$BRIDGE_SCRIPT exit_code=$exit_code delay_seconds=5" >>"$BRIDGE_LOG_FILE"
      sleep 5
    done
  fi
) &
NEW_BRIDGE_PID=$!
echo "$NEW_BRIDGE_PID" > "$BRIDGE_PID_FILE"
chmod 600 "$BRIDGE_PID_FILE"
echo "Bridge pid: $NEW_BRIDGE_PID"
echo "Bridge logs: $BRIDGE_LOG_FILE"

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
