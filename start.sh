#!/bin/bash
# Hornet Agent Launcher
# Run as: sudo -u hornet_agent /home/hornet_agent/hornet/start.sh
#
# Architecture: ~/hornet/ is the read-only source repo (admin-managed).
# The agent runs from deployed copies:
#   ~/.pi/agent/extensions/  ← pi extensions
#   ~/.pi/agent/skills/      ← operational skills
#   ~/runtime/slack-bridge/  ← bridge process
#
# To update runtime files, admin edits ~/hornet/ and runs bin/deploy.sh.

set -euo pipefail
cd ~

# Set PATH
export PATH="$HOME/opt/node-v22.14.0-linux-x64/bin:$PATH"

# Load secrets
set -a
source ~/.config/.env
set +a

# Harden file permissions (pi defaults are too permissive)
umask 077
~/hornet/bin/harden-permissions.sh

# Redact any secrets that leaked into session logs
~/hornet/bin/redact-logs.sh 2>/dev/null || true

# Set session name (read by auto-name.ts extension)
export PI_SESSION_NAME="control-agent"

# Start control-agent
# --session-control: enables inter-session communication (handled by control.ts extension)
pi --session-control --skill ~/.pi/agent/skills/control-agent "/skill:control-agent"
