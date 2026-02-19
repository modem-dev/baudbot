#!/bin/bash
# Baudbot Agent Launcher
# Run as: sudo -u baudbot_agent ~/runtime/start.sh
#
# The agent runs entirely from deployed copies — no source repo access needed:
#   ~/.pi/agent/extensions/  ← pi extensions
#   ~/.pi/agent/skills/      ← operational skills
#   ~/runtime/slack-bridge/  ← bridge process
#   ~/runtime/bin/           ← utility scripts
#
# To update, admin edits source and runs deploy.sh.

set -euo pipefail
cd ~

# Set PATH
export PATH="$HOME/.varlock/bin:$HOME/opt/node-v22.14.0-linux-x64/bin:$PATH"

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

# Start Slack bridge in the background (before pi, so it's ready for messages).
# The bridge resolves the pi session socket lazily — it will wait for the
# control-agent to come up and create its socket before forwarding messages.
if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_APP_TOKEN:-}" ]; then
  # Kill any existing bridge
  tmux kill-session -t slack-bridge 2>/dev/null || true
  echo "Starting Slack bridge..."
  tmux new-session -d -s slack-bridge \
    "export PATH=$HOME/.varlock/bin:$HOME/opt/node-v22.14.0-linux-x64/bin:\$PATH && \
     cd ~/runtime/slack-bridge && \
     while true; do \
       varlock run --path ~/.config/ -- node bridge.mjs; \
       echo '⚠️  Bridge exited (\$?), restarting in 5s...'; \
       sleep 5; \
     done"
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
