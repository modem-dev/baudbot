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

# Start control-agent
# --session-control: enables inter-session communication (handled by control.ts extension)
pi --session-control --model "$MODEL" --skill ~/.pi/agent/skills/control-agent "/skill:control-agent"
