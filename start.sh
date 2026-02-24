#!/bin/bash
# Baudbot Agent Launcher
# Run as: sudo -u baudbot_agent ~/runtime/start.sh
#
# The agent runs entirely from deployed copies — no source repo access needed:
#   ~/.pi/agent/extensions/          ← pi extensions
#   ~/.pi/agent/skills/              ← operational skills
#   /opt/baudbot/current/slack-bridge/ ← bridge process
#   ~/runtime/bin/                   ← utility scripts
#
# To update, admin edits source and runs deploy.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/runtime-node.sh
source "$SCRIPT_DIR/bin/lib/runtime-node.sh"
# bridge-restart-policy.sh no longer needed — bridge is started by
# startup-pi.sh, not start.sh (see PR #164)
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

# ── Slack bridge cleanup (bridge is started by startup-pi.sh) ──
# The bridge needs the control-agent's session UUID (PI_SESSION_ID) to deliver
# messages to the correct socket. That UUID isn't known until pi starts and
# registers its socket. So we DON'T start the bridge here — the control-agent's
# startup-pi.sh handles it after the session is live.
#
# We DO kill any stale bridge processes from previous runs to avoid port
# conflicts when startup-pi.sh launches a fresh one.
BRIDGE_PID_FILE="$HOME/.pi/agent/slack-bridge.pid"
if [ -f "$BRIDGE_PID_FILE" ]; then
  old_pid="$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Stopping stale bridge supervisor (PID $old_pid)..."
    kill "$old_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$old_pid" 2>/dev/null || true
  fi
  rm -f "$BRIDGE_PID_FILE"
fi
# Kill the tmux session too (startup-pi.sh uses this)
tmux kill-session -t slack-bridge 2>/dev/null || true
# Force-release port 7890 in case anything survived
PORT_PIDS="$(lsof -ti :7890 2>/dev/null || true)"
if [ -n "$PORT_PIDS" ]; then
  echo "Releasing port 7890 (PIDs: $PORT_PIDS)..."
  echo "$PORT_PIDS" | xargs kill 2>/dev/null || true
  sleep 1
  PORT_PIDS="$(lsof -ti :7890 2>/dev/null || true)"
  [ -n "$PORT_PIDS" ] && echo "$PORT_PIDS" | xargs kill -9 2>/dev/null || true
fi

# Set session name (read by auto-name.ts extension)
export PI_SESSION_NAME="control-agent"

# Pick model: explicit override or auto-detect from API keys (first match wins)
if [ -n "${BAUDBOT_MODEL:-}" ]; then
  MODEL="$BAUDBOT_MODEL"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
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
