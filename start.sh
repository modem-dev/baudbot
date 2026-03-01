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
cd ~

NODE_BIN_DIR="$(bb_resolve_runtime_node_bin_dir "$HOME")"

# Set PATH
export PATH="$HOME/.varlock/bin:$NODE_BIN_DIR:$PATH"

# Work around varlock telemetry config crash by opting out at runtime.
export VARLOCK_TELEMETRY_DISABLED=1

# Validate and load secrets via varlock
varlock load --path ~/.config/ || {
  echo "❌ Environment validation failed — check ~/.config/.env against .env.schema"
  exit 1
}
set -a
# shellcheck disable=SC1090
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
      if ! fuser "$sock" &>/dev/null 2>&1; then
        rm -f "$sock"
      fi
    done
  else
    echo "  fuser not found, skipping socket cleanup (install psmisc)"
  fi
  for alias in "$SOCKET_DIR"/*.alias; do
    [ -L "$alias" ] || continue
    target=$(readlink "$alias")
    if [ ! -e "$SOCKET_DIR/$target" ] && [ ! -e "$target" ]; then
      rm -f "$alias"
    fi
  done
fi

# ── Process Group Management ──
# Kill old control-agent process group to ensure clean slate.
# This automatically terminates all spawned services (bridge, workers, etc.)
# without needing to track individual PIDs or process names.
CONTROL_PGID_FILE="$HOME/.pi/agent/control-agent.pgid"

if [ -f "$CONTROL_PGID_FILE" ]; then
  OLD_PGID=$(cat "$CONTROL_PGID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PGID" ] && kill -0 -"$OLD_PGID" 2>/dev/null; then
    echo "Terminating old control-agent process group (PGID $OLD_PGID)..."
    kill -TERM -"$OLD_PGID" 2>/dev/null || true
    # Wait up to 5s for graceful shutdown
    for _i in 1 2 3 4 5; do
      if ! kill -0 -"$OLD_PGID" 2>/dev/null; then
        echo "  Process group terminated cleanly"
        break
      fi
      sleep 1
    done
    # Force-kill any survivors
    if kill -0 -"$OLD_PGID" 2>/dev/null; then
      echo "  Force-killing stubborn processes in group $OLD_PGID..."
      kill -KILL -"$OLD_PGID" 2>/dev/null || true
      sleep 1
    fi
  fi
  rm -f "$CONTROL_PGID_FILE"
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
elif [ -f "$HOME/.pi/agent/auth.json" ] && command -v jq &>/dev/null; then
  # OAuth subscription fallback: check auth.json for credentials saved via `baudbot login` or `pi /login`
  if jq -e '."openai-codex"' "$HOME/.pi/agent/auth.json" &>/dev/null; then
    MODEL="openai-codex/gpt-5.2-codex"
  elif jq -e '.anthropic' "$HOME/.pi/agent/auth.json" &>/dev/null; then
    MODEL="anthropic/claude-opus-4-6"
  elif jq -e '.google' "$HOME/.pi/agent/auth.json" &>/dev/null; then
    MODEL="google/gemini-3-pro-preview"
  elif jq -e '."github-copilot"' "$HOME/.pi/agent/auth.json" &>/dev/null; then
    MODEL="github-copilot/claude-sonnet-4"
  else
    echo "❌ No LLM credentials found in env vars or auth.json"
    exit 1
  fi
else
  echo "❌ No LLM API key found — set ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY"
  echo "   Or use subscription login: sudo baudbot login"
  exit 1
fi

# Start control-agent.
# Save our PID as the process group ID for cleanup on next restart.
# When systemd launches start.sh (Type=simple), our PID is already the
# process group leader. `exec pi` replaces this process in-place (same PID,
# same PGID), so all child processes (bridge, workers) inherit the group.
# On restart, killing -$PGID terminates the entire tree automatically.
#
# --session-control: enables inter-session communication (handled by control.ts extension)
echo "Starting control-agent..."
echo $$ > "$CONTROL_PGID_FILE"
exec pi --session-control --model "$MODEL" --skill ~/.pi/agent/skills/control-agent "/skill:control-agent"
