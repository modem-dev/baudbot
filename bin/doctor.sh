#!/bin/bash
# Baudbot Doctor — health check for the baudbot installation.
# Checks deps, perms, secrets, firewall, and agent status.
#
# Usage: baudbot doctor [--fix]

set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: baudbot doctor"
      exit 0
      ;;
  esac
done

BAUDBOT_HOME="/home/baudbot_agent"
PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠ $1"; WARN=$((WARN + 1)); }

echo "Baudbot Doctor"
echo ""

# ── User ─────────────────────────────────────────────────────────────────────

echo "User:"
if id baudbot_agent &>/dev/null; then
  pass "baudbot_agent user exists"
else
  fail "baudbot_agent user does not exist (run: baudbot setup)"
fi

# ── Dependencies ─────────────────────────────────────────────────────────────

echo ""
echo "Dependencies:"

NODE_BIN="$BAUDBOT_HOME/opt/node-v22.14.0-linux-x64/bin/node"
if [ -x "$NODE_BIN" ]; then
  NODE_VER=$("$NODE_BIN" --version 2>/dev/null || echo "unknown")
  pass "Node.js $NODE_VER"
else
  fail "Node.js not found at $NODE_BIN"
fi

PI_BIN="$BAUDBOT_HOME/opt/node-v22.14.0-linux-x64/bin/pi"
if [ -x "$PI_BIN" ] || [ -L "$PI_BIN" ]; then
  pass "pi is installed"
else
  fail "pi not found at $PI_BIN"
fi

if command -v varlock &>/dev/null || [ -x "$BAUDBOT_HOME/.varlock/bin/varlock" ]; then
  pass "varlock is installed"
else
  fail "varlock not found"
fi

if command -v docker &>/dev/null; then
  pass "docker is available"
else
  warn "docker not found (optional, needed for container tasks)"
fi

# ── Secrets ──────────────────────────────────────────────────────────────────

echo ""
echo "Admin config:"

# Check for admin config dir
ADMIN_USER="${SUDO_USER:-$(whoami)}"
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6 2>/dev/null || echo "")
ADMIN_CONFIG="$ADMIN_HOME/.baudbot/.env"

if [ -n "$ADMIN_HOME" ] && [ -f "$ADMIN_CONFIG" ]; then
  pass "admin config exists ($ADMIN_CONFIG)"
else
  warn "admin config not found at $ADMIN_CONFIG (run: baudbot config)"
fi

echo ""
echo "Agent secrets:"

ENV_FILE="$BAUDBOT_HOME/.config/.env"
if [ -f "$ENV_FILE" ]; then
  PERMS=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "unknown")
  OWNER=$(stat -c '%U' "$ENV_FILE" 2>/dev/null || echo "unknown")
  if [ "$PERMS" = "600" ]; then
    pass ".env has 600 permissions"
  else
    fail ".env has $PERMS permissions (should be 600)"
  fi
  if [ "$OWNER" = "baudbot_agent" ]; then
    pass ".env owned by baudbot_agent"
  else
    fail ".env owned by $OWNER (should be baudbot_agent)"
  fi

  # Check for at least one LLM key
  HAS_LLM=false
  for key in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_ZEN_API_KEY; do
    if grep -q "^${key}=.\+" "$ENV_FILE" 2>/dev/null; then
      HAS_LLM=true
      break
    fi
  done
  if [ "$HAS_LLM" = true ]; then
    pass "at least one LLM API key is set"
  else
    fail "no LLM API key set (need ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY)"
  fi

  # Check required keys
  for key in GITHUB_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS; do
    if grep -q "^${key}=.\+" "$ENV_FILE" 2>/dev/null; then
      pass "$key is set"
    else
      warn "$key is not set"
    fi
  done
else
  fail ".env not found at $ENV_FILE"
fi

# ── Runtime ──────────────────────────────────────────────────────────────────

echo ""
echo "Runtime:"

if [ -f "$BAUDBOT_HOME/runtime/start.sh" ]; then
  pass "start.sh deployed"
else
  fail "start.sh not found (run: baudbot deploy)"
fi

if [ -d "$BAUDBOT_HOME/.pi/agent/extensions" ]; then
  EXT_COUNT=$(find "$BAUDBOT_HOME/.pi/agent/extensions" -maxdepth 1 -name '*.ts' -o -name '*.mjs' 2>/dev/null | wc -l)
  pass "extensions deployed ($EXT_COUNT files)"
else
  fail "extensions not deployed (run: baudbot deploy)"
fi

if [ -d "$BAUDBOT_HOME/.pi/agent/skills" ]; then
  pass "skills deployed"
else
  fail "skills not deployed (run: baudbot deploy)"
fi

if [ -d "$BAUDBOT_HOME/runtime/slack-bridge" ] && [ -f "$BAUDBOT_HOME/runtime/slack-bridge/bridge.mjs" ]; then
  pass "slack bridge deployed"
else
  fail "slack bridge not deployed (run: baudbot deploy)"
fi

# ── Security ─────────────────────────────────────────────────────────────────

echo ""
echo "Security:"

# Firewall
if command -v iptables &>/dev/null && iptables -w -L BAUDBOT_OUTPUT -n &>/dev/null 2>&1; then
  RULE_COUNT=$(iptables -w -L BAUDBOT_OUTPUT -n 2>/dev/null | tail -n +3 | wc -l)
  pass "firewall active ($RULE_COUNT rules)"
else
  warn "firewall not active (run: baudbot setup)"
fi

# /proc hidepid
if mount | grep -q 'hidepid=2'; then
  pass "/proc hidepid=2 active"
else
  warn "/proc hidepid not active"
fi

# Safe bash wrapper
if [ -f /usr/local/bin/baudbot-safe-bash ]; then
  if [ "$(stat -c '%U' /usr/local/bin/baudbot-safe-bash)" = "root" ]; then
    pass "baudbot-safe-bash installed (root-owned)"
  else
    fail "baudbot-safe-bash not root-owned"
  fi
else
  warn "baudbot-safe-bash not installed"
fi

# Tool-guard read-only
TOOL_GUARD="$BAUDBOT_HOME/.pi/agent/extensions/tool-guard.ts"
if [ -f "$TOOL_GUARD" ]; then
  if [ ! -w "$TOOL_GUARD" ] 2>/dev/null; then
    pass "tool-guard.ts is read-only"
  else
    # Check if writable by agent
    PERMS=$(stat -c '%a' "$TOOL_GUARD" 2>/dev/null || echo "unknown")
    if echo "$PERMS" | grep -qE '^[0-4]'; then
      pass "tool-guard.ts is read-only"
    else
      warn "tool-guard.ts may be writable (perms: $PERMS)"
    fi
  fi
else
  fail "tool-guard.ts not found"
fi

# ── Agent Status ─────────────────────────────────────────────────────────────

echo ""
echo "Agent:"

if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
  if systemctl is-enabled baudbot &>/dev/null 2>&1; then
    pass "systemd unit enabled"
    if systemctl is-active baudbot &>/dev/null 2>&1; then
      pass "agent is running (systemd)"
    else
      warn "agent is not running"
    fi
  else
    warn "systemd unit not installed (run: baudbot setup)"
  fi
else
  # No systemd — check for pi process
  if pgrep -u baudbot_agent -f "pi --session-control" &>/dev/null; then
    pass "agent is running (direct mode)"
  else
    warn "agent is not running"
  fi
fi

# ── Runtime Health ────────────────────────────────────────────────────────────

echo ""
echo "Runtime health:"

# Slack bridge
if curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7890/send -H 'Content-Type: application/json' -d '{}' 2>/dev/null | grep -q "400"; then
  pass "slack bridge responding (port 7890)"
else
  warn "slack bridge not responding on port 7890"
fi

# Disk usage
DISK_PCT=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [ -n "$DISK_PCT" ]; then
  if [ "$DISK_PCT" -ge 90 ]; then
    fail "disk usage at ${DISK_PCT}% (critical)"
  elif [ "$DISK_PCT" -ge 80 ]; then
    warn "disk usage at ${DISK_PCT}%"
  else
    pass "disk usage at ${DISK_PCT}%"
  fi
fi

# Stale session sockets
SOCKET_DIR="$BAUDBOT_HOME/.pi/session-control"
if [ -d "$SOCKET_DIR" ]; then
  STALE_SOCKS=0
  if command -v fuser &>/dev/null; then
    for sock in "$SOCKET_DIR"/*.sock; do
      [ -e "$sock" ] || continue
      if ! fuser "$sock" &>/dev/null 2>&1; then
        STALE_SOCKS=$((STALE_SOCKS + 1))
      fi
    done
    if [ "$STALE_SOCKS" -gt 0 ]; then
      warn "$STALE_SOCKS stale session socket(s) in $SOCKET_DIR"
    else
      pass "no stale session sockets"
    fi
  else
    warn "fuser not installed; skipping stale socket check"
  fi
fi


# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────"
echo "  $PASS passed, $FAIL failed, $WARN warnings"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Fix failures before starting the agent."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "Warnings are non-blocking but should be reviewed."
  exit 0
else
  echo ""
  echo "All checks passed."
  exit 0
fi
