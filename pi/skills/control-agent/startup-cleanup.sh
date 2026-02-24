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

# Prevent varlock SEA binary from misinterpreting argv when called from a
# session that was itself launched via varlock (PKG_EXECPATH leaks into child
# processes and causes `varlock run` to treat subcommands as Node module paths).
unset PKG_EXECPATH 2>/dev/null || true

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

BRIDGE_LOG_DIR="$HOME/.pi/agent/logs"
BRIDGE_LOG_FILE="$BRIDGE_LOG_DIR/slack-bridge.log"
BRIDGE_DIR="/opt/baudbot/current/slack-bridge"
BRIDGE_TMUX_SESSION="slack-bridge"

mkdir -p "$BRIDGE_LOG_DIR"

# --- Kill anything holding port 7890, any existing bridge tmux session,
#     and any leftover old-style PID-file supervisor.
echo "Cleaning up old bridge..."
PORT_PIDS=$(lsof -ti :7890 2>/dev/null || true)
if [ -n "$PORT_PIDS" ]; then
  echo "Killing processes on port 7890: $PORT_PIDS"
  echo "$PORT_PIDS" | xargs kill -9 2>/dev/null || true
  sleep 1
fi
tmux kill-session -t "$BRIDGE_TMUX_SESSION" 2>/dev/null || true
OLD_PID_FILE="$HOME/.pi/agent/slack-bridge.pid"
if [ -f "$OLD_PID_FILE" ]; then
  OLD_PID="$(cat "$OLD_PID_FILE" 2>/dev/null || true)"
  [ -n "$OLD_PID" ] && kill -9 "$OLD_PID" 2>/dev/null || true
  rm -f "$OLD_PID_FILE"
fi

# --- Detect bridge mode ---
BRIDGE_SCRIPT=""
if [ -f "$BRIDGE_DIR/broker-bridge.mjs" ] && varlock run --path "$HOME/.config/" -- sh -c '
  test -n "$SLACK_BROKER_URL" &&
  test -n "$SLACK_BROKER_WORKSPACE_ID" &&
  test -n "$SLACK_BROKER_SERVER_PRIVATE_KEY" &&
  test -n "$SLACK_BROKER_SERVER_PUBLIC_KEY" &&
  test -n "$SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY" &&
  test -n "$SLACK_BROKER_PUBLIC_KEY" &&
  test -n "$SLACK_BROKER_SIGNING_PUBLIC_KEY"' 2>/dev/null; then
  BRIDGE_SCRIPT="broker-bridge.mjs"
elif [ -f "$BRIDGE_DIR/bridge.mjs" ] && varlock run --path "$HOME/.config/" -- sh -c '
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

# --- Launch bridge in a tmux session with restart loop ---
# The tmux session stays alive independently of this script (same pattern as
# sentry-agent). If the bridge crashes, the loop restarts it after 5 seconds.
echo "Starting slack-bridge ($BRIDGE_SCRIPT) via tmux..."
tmux new-session -d -s "$BRIDGE_TMUX_SESSION" "\
  unset PKG_EXECPATH; \
  export PATH=\$HOME/.varlock/bin:\$HOME/opt/node-v22.14.0-linux-x64/bin:\$PATH; \
  export PI_SESSION_ID=$MY_UUID; \
  cd $BRIDGE_DIR; \
  while true; do \
    echo \"[\$(date -Is)] bridge: starting $BRIDGE_SCRIPT\" >> $BRIDGE_LOG_FILE; \
    varlock run --path \$HOME/.config/ -- node $BRIDGE_SCRIPT >> $BRIDGE_LOG_FILE 2>&1; \
    exit_code=\$?; \
    echo \"[\$(date -Is)] bridge: exited with code \$exit_code, restarting in 5s\" >> $BRIDGE_LOG_FILE; \
    sleep 5; \
  done"

echo "Bridge tmux session: $BRIDGE_TMUX_SESSION"
echo "Bridge logs: $BRIDGE_LOG_FILE"

# --- Verify bridge is up ---
sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7890/send -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "400" ]; then
  echo "✅ Slack bridge is up (HTTP $HTTP_CODE)"
else
  echo "⚠️  Bridge may not be ready yet (HTTP $HTTP_CODE). Check: tmux attach -t $BRIDGE_TMUX_SESSION"
fi

echo ""
echo "=== Cleanup Complete ==="
