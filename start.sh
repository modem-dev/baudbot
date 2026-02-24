#!/bin/bash
# Baudbot Agent Launcher
# Run as: sudo -u baudbot_agent ~/runtime/start.sh
#
# The agent runs entirely from deployed copies — no source repo access needed:
#   ~/.pi/agent/extensions/          ← pi extensions
#   ~/.pi/agent/skills/              ← operational skills
#   /opt/baudbot/current/broker-gateway/ ← bridge process
#   ~/runtime/bin/                   ← utility scripts
#
# To update, admin edits source and runs deploy.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/runtime-node.sh
source "$SCRIPT_DIR/bin/lib/runtime-node.sh"
# shellcheck source=bin/lib/bridge-restart-policy.sh
source "$SCRIPT_DIR/bin/lib/bridge-restart-policy.sh"
cd ~

NODE_BIN_DIR="$(bb_resolve_runtime_node_bin_dir "$HOME")"

# Set PATH
export PATH="$HOME/.varlock/bin:$NODE_BIN_DIR:$PATH"

# Work around varlock telemetry config crash by opting out at runtime.
# This avoids loading anonymousId from user config and keeps startup deterministic.
export VARLOCK_TELEMETRY_DISABLED=1

# Validate and load secrets via varlock
varlock load --path ~/.config/ || {
  echo "❌ Environment validation failed — check ~/.config/.env against .env.schema"
  exit 1
}
set -a
# shellcheck disable=SC1090  # path is dynamic (agent home)
source ~/.config/.env
set +a

# Harden file permissions (pi defaults are too permissive)
umask 077
~/runtime/bin/harden-permissions.sh

# Prune old session logs to limit transcript retention window
~/runtime/bin/prune-session-logs.sh --days 14 2>/dev/null || true

# Redact any secrets that leaked into retained session logs
~/runtime/bin/redact-logs.sh 2>/dev/null || true

# Verify deployed runtime integrity against deploy manifest.
# Modes: off | warn | strict (default: warn)
INTEGRITY_MODE="${BAUDBOT_STARTUP_INTEGRITY_MODE:-warn}"
if [ -x "$HOME/runtime/bin/verify-manifest.sh" ]; then
  if ! BAUDBOT_STARTUP_INTEGRITY_MODE="$INTEGRITY_MODE" "$HOME/runtime/bin/verify-manifest.sh"; then
    echo "❌ Startup integrity verification failed (mode: $INTEGRITY_MODE). Refusing to start."
    exit 1
  fi
else
  echo "⚠️  Startup integrity verifier missing at ~/runtime/bin/verify-manifest.sh"
fi

# Clean stale session sockets from previous runs
SOCKET_DIR="$HOME/.pi/session-control"
if [ -d "$SOCKET_DIR" ]; then
  echo "Cleaning stale session sockets..."
  if command -v fuser &>/dev/null; then
    for sock in "$SOCKET_DIR"/*.sock; do
      [ -e "$sock" ] || continue
      # If no process has the socket open, it's stale
      if ! fuser "$sock" &>/dev/null 2>&1; then
        rm -f "$sock"
      fi
    done
  else
    echo "  fuser not found, skipping socket cleanup (install psmisc)"
  fi
  # Clean broken alias symlinks
  for alias in "$SOCKET_DIR"/*.alias; do
    [ -L "$alias" ] || continue
    target=$(readlink "$alias")
    if [ ! -e "$SOCKET_DIR/$target" ] && [ ! -e "$target" ]; then
      rm -f "$alias"
    fi
  done
fi

# Start Broker gateway in the background (before pi, so it's ready for messages).
# Broker pull mode has priority when SLACK_BROKER_* keys are configured.
# Otherwise fallback to direct Slack Socket Mode.
BRIDGE_SCRIPT=""
if [ -n "${SLACK_BROKER_URL:-}" ] \
  && [ -n "${SLACK_BROKER_WORKSPACE_ID:-}" ] \
  && [ -n "${SLACK_BROKER_SERVER_PRIVATE_KEY:-}" ] \
  && [ -n "${SLACK_BROKER_SERVER_PUBLIC_KEY:-}" ] \
  && [ -n "${SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY:-}" ] \
  && [ -n "${SLACK_BROKER_PUBLIC_KEY:-}" ] \
  && [ -n "${SLACK_BROKER_SIGNING_PUBLIC_KEY:-}" ]; then
  BRIDGE_SCRIPT="broker-bridge.mjs"
elif [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_APP_TOKEN:-}" ]; then
  BRIDGE_SCRIPT="bridge.mjs"
fi

if [ -n "$BRIDGE_SCRIPT" ]; then
  RELEASE_BRIDGE="/opt/baudbot/current/broker-gateway"
  BRIDGE_LOG_DIR="$HOME/.pi/agent/logs"
  BRIDGE_LOG_FILE="$BRIDGE_LOG_DIR/broker-gateway.log"
  BRIDGE_STATUS_FILE="$HOME/.pi/agent/broker-gateway-supervisor.json"
  BRIDGE_PID_FILE="$HOME/.pi/agent/broker-gateway.pid"

  mkdir -p "$BRIDGE_LOG_DIR"

  # Stop any previous bridge process tracked by pid file.
  if [ -f "$BRIDGE_PID_FILE" ]; then
    old_pid="$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$old_pid" 2>/dev/null || true
    fi
    rm -f "$BRIDGE_PID_FILE"
  fi

  echo "Starting Broker gateway ($BRIDGE_SCRIPT)... logs: $BRIDGE_LOG_FILE"
  (
    export PATH="$HOME/.varlock/bin:$NODE_BIN_DIR:$PATH"
    cd "$RELEASE_BRIDGE"
    bb_bridge_supervise "$BRIDGE_LOG_FILE" "$BRIDGE_STATUS_FILE" "$BRIDGE_SCRIPT" \
      varlock run --path ~/.config/ -- node "$BRIDGE_SCRIPT"
  ) &
  # Intentionally track the supervisor subshell PID (not per-restart node child PID)
  # so a single kill stops the entire bridge restart loop.
  echo $! > "$BRIDGE_PID_FILE"
  chmod 600 "$BRIDGE_PID_FILE"
fi

# Set session name (read by auto-name.ts extension)
export PI_SESSION_NAME="control-agent"

# Pick model based on available API keys (first match wins)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MODEL="anthropic/claude-opus-4-6"
elif [ -n "${OPENAI_API_KEY:-}" ]; then
  MODEL="openai/gpt-5.2-codex"
elif [ -n "${GEMINI_API_KEY:-}" ]; then
  MODEL="google/gemini-3-pro-preview"
elif [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
  MODEL="opencode-zen/claude-opus-4-6"
else
  echo "❌ No LLM API key found — set ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY"
  exit 1
fi

# Start control-agent
# --session-control: enables inter-session communication (handled by control.ts extension)
pi --session-control --model "$MODEL" --skill ~/.pi/agent/skills/control-agent "/skill:control-agent"
