#!/bin/bash
# Baudbot Control Plane launcher
# Run as admin (NOT as baudbot_agent) — the agent must not reach this server.
#
# Usage:
#   ~/baudbot/bin/control-plane.sh              # foreground
#   ~/baudbot/bin/control-plane.sh &            # background
#   tmux new-window -n cp '~/baudbot/bin/control-plane.sh'  # tmux pane
#
# Env vars (set in ~/.bashrc, export before running, or in a .env):
#   BAUDBOT_CP_TOKEN   — bearer token (recommended)
#   BAUDBOT_CP_PORT    — override port (default: 28800)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CP_DIR="$REPO_DIR/control-plane"

# Don't allow running as the agent user
AGENT_USER="${BAUDBOT_AGENT_USER:-baudbot_agent}"
if [ "$(whoami)" = "$AGENT_USER" ]; then
  echo "❌ Control plane must NOT run as $AGENT_USER"
  echo "   Run as your admin user instead."
  exit 1
fi

# Ensure deps are installed
if [ ! -d "$CP_DIR/node_modules" ]; then
  echo "📦 Installing control-plane dependencies..."
  (cd "$CP_DIR" && npm install --omit=dev)
fi

echo "🔧 Starting baudbot control plane..."
exec node "$CP_DIR/server.mjs"
