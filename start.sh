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

# systemd's PrivateTmp=yes hides /tmp from outside the service.
# Point tmux at a visible directory so baudbot attach/sessions work.
export TMUX_TMPDIR="$HOME/.tmux-sock"
mkdir -p "$TMUX_TMPDIR"
chmod 700 "$TMUX_TMPDIR"

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

# Redact any secrets that leaked into session logs
~/runtime/bin/redact-logs.sh 2>/dev/null || true

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

# Start the slack-bridge in the background.
# It waits for the control-agent socket to appear, then connects.
_start_bridge() {
  local socket_dir="$HOME/.pi/session-control"
  local timeout=60
  local elapsed=0

  echo "bridge: waiting for control-agent socket..."
  while [ $elapsed -lt $timeout ]; do
    local alias_file="$socket_dir/control-agent.alias"
    if [ -L "$alias_file" ]; then
      local target
      target=$(readlink "$alias_file")
      local uuid="${target%.sock}"
      echo "bridge: found control-agent ($uuid)"

      # Kill existing bridge if any
      tmux kill-session -t slack-bridge 2>/dev/null || true
      sleep 1

      tmux new-session -d -s slack-bridge \
        "export PATH=\$HOME/.varlock/bin:\$HOME/opt/node-v22.14.0-linux-x64/bin:\$PATH && export PI_SESSION_ID=$uuid && cd ~/runtime/slack-bridge && exec varlock run --path ~/.config/ -- node bridge.mjs"

      sleep 3
      local http_code
      http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7890/send -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo "000")
      if [ "$http_code" = "400" ]; then
        echo "bridge: up ✓"
      else
        echo "bridge: started but health check returned HTTP $http_code"
      fi
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "bridge: timed out waiting for control-agent socket (${timeout}s)"
}
_start_bridge &

# Start control-agent
# --session-control: enables inter-session communication (handled by control.ts extension)
pi --session-control --model "$MODEL" --skill ~/.pi/agent/skills/control-agent "/skill:control-agent"
