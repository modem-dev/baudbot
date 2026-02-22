#!/bin/bash
# Baudbot Doctor — health check for the baudbot installation.
# Checks deps, perms, secrets, firewall, and agent status.
#
# Usage: baudbot doctor [--fix]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
# shellcheck source=bin/lib/doctor-common.sh
source "$SCRIPT_DIR/lib/doctor-common.sh"
bb_enable_strict_mode
bb_init_paths

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: baudbot doctor"
      exit 0
      ;;
  esac
done

doctor_init_counters
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=1
fi

pass() { doctor_pass "$1"; }
fail() { doctor_fail "$1"; }
warn() { doctor_warn "$1"; }

echo "Baudbot Doctor"
echo ""
if [ "$IS_ROOT" -ne 1 ]; then
  echo "ℹ Running without root: some checks may be inconclusive."
  echo "  For full accuracy, run: sudo baudbot doctor"
  echo ""
fi

# ── User ─────────────────────────────────────────────────────────────────────

echo "User:"
if id "$BAUDBOT_AGENT_USER" &>/dev/null; then
  pass "$BAUDBOT_AGENT_USER user exists"
else
  fail "$BAUDBOT_AGENT_USER user does not exist (run: baudbot setup)"
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
  if [ -f "$BAUDBOT_HOME/.varlock/config.json" ] && grep -q '"anonymousId"' "$BAUDBOT_HOME/.varlock/config.json"; then
    warn "$BAUDBOT_HOME/.varlock/config.json includes anonymousId (export VARLOCK_TELEMETRY_DISABLED=1 or remove this field)"
  fi
else
  fail "varlock not found"
fi

if command -v jq &>/dev/null; then
  pass "jq is installed"
else
  fail "jq not found (required for shell JSON parsing)"
fi

if command -v docker &>/dev/null; then
  pass "docker is available"
else
  warn "docker not found (optional, needed for container tasks)"
fi

if command -v gh &>/dev/null; then
  if sudo -u "$BAUDBOT_AGENT_USER" gh auth status &>/dev/null; then
    pass "gh cli authenticated"
  else
    warn "gh cli installed but not authenticated (run: sudo -u $BAUDBOT_AGENT_USER gh auth login)"
  fi
else
  fail "gh cli not found"
fi

# ── Secrets ──────────────────────────────────────────────────────────────────

echo ""
echo "Admin config:"

# Check for admin config/env source
ADMIN_USER="${SUDO_USER:-$(whoami)}"
ADMIN_HOME="$(bb_resolve_user_home "$ADMIN_USER" || true)"
ADMIN_CONFIG="$ADMIN_HOME/.baudbot/.env"
BACKEND_CONF="$ADMIN_HOME/.baudbot/env-store.conf"
RENDER_ENV_SCRIPT="${BAUDBOT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}/bin/render-env.sh"

ADMIN_BACKEND="file"
if [ -f "$BACKEND_CONF" ]; then
  ADMIN_BACKEND=$(grep -E '^BAUDBOT_ENV_BACKEND=' "$BACKEND_CONF" | tail -n1 | cut -d= -f2- || echo "file")
fi

if [ -n "$ADMIN_HOME" ] && [ -x "$RENDER_ENV_SCRIPT" ] && BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_CONFIG_USER="$ADMIN_USER" "$RENDER_ENV_SCRIPT" --check >/dev/null 2>&1; then
  pass "admin env source is configured (backend: $ADMIN_BACKEND)"
elif [ -n "$ADMIN_HOME" ] && [ -f "$ADMIN_CONFIG" ]; then
  pass "admin config exists ($ADMIN_CONFIG)"
else
  warn "admin env source not found (run: baudbot config, or configure: baudbot env backend ...)"
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
  if [ "$OWNER" = "$BAUDBOT_AGENT_USER" ]; then
    pass ".env owned by $BAUDBOT_AGENT_USER"
  else
    fail ".env owned by $OWNER (should be $BAUDBOT_AGENT_USER)"
  fi

  # LLM key validation: require at least one valid key, and flag malformed configured keys.
  VALID_LLM_COUNT=0

  ANTHROPIC_VALUE="$(bb_read_env_value "$ENV_FILE" ANTHROPIC_API_KEY)"
  if [ -n "$ANTHROPIC_VALUE" ]; then
    if [[ "$ANTHROPIC_VALUE" == sk-ant-* ]]; then
      VALID_LLM_COUNT=$((VALID_LLM_COUNT + 1))
    else
      fail "ANTHROPIC_API_KEY is set but malformed (must start with sk-ant-)"
    fi
  fi

  OPENAI_VALUE="$(bb_read_env_value "$ENV_FILE" OPENAI_API_KEY)"
  if [ -n "$OPENAI_VALUE" ]; then
    if [[ "$OPENAI_VALUE" == sk-* ]]; then
      VALID_LLM_COUNT=$((VALID_LLM_COUNT + 1))
    else
      fail "OPENAI_API_KEY is set but malformed (must start with sk-)"
    fi
  fi

  GEMINI_VALUE="$(bb_read_env_value "$ENV_FILE" GEMINI_API_KEY)"
  if [ -n "$GEMINI_VALUE" ]; then
    VALID_LLM_COUNT=$((VALID_LLM_COUNT + 1))
  fi

  OPENCODE_VALUE="$(bb_read_env_value "$ENV_FILE" OPENCODE_ZEN_API_KEY)"
  if [ -n "$OPENCODE_VALUE" ]; then
    VALID_LLM_COUNT=$((VALID_LLM_COUNT + 1))
  fi

  if [ "$VALID_LLM_COUNT" -gt 0 ]; then
    pass "at least one valid LLM API key is set"
  else
    fail "no valid LLM API key set (need ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY)"
  fi

  BROKER_REQUIRED_KEYS=(
    SLACK_BROKER_URL
    SLACK_BROKER_WORKSPACE_ID
    SLACK_BROKER_SERVER_PRIVATE_KEY
    SLACK_BROKER_SERVER_PUBLIC_KEY
    SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY
    SLACK_BROKER_PUBLIC_KEY
    SLACK_BROKER_SIGNING_PUBLIC_KEY
  )

  BROKER_MODE_READY=true
  for key in "${BROKER_REQUIRED_KEYS[@]}"; do
    if [ -z "$(bb_read_env_value "$ENV_FILE" "$key")" ]; then
      BROKER_MODE_READY=false
      break
    fi
  done

  SOCKET_MODE_READY=true
  for key in SLACK_BOT_TOKEN SLACK_APP_TOKEN; do
    if [ -z "$(bb_read_env_value "$ENV_FILE" "$key")" ]; then
      SOCKET_MODE_READY=false
      break
    fi
  done

  if [ "$BROKER_MODE_READY" = true ]; then
    pass "broker mode configured (SLACK_BROKER_*)"
    for key in SLACK_BOT_TOKEN SLACK_APP_TOKEN; do
      if [ -n "$(bb_read_env_value "$ENV_FILE" "$key")" ]; then
        pass "$key is set"
      else
        pass "$key not required in broker mode"
      fi
    done
  else
    for key in SLACK_BOT_TOKEN SLACK_APP_TOKEN; do
      if [ -n "$(bb_read_env_value "$ENV_FILE" "$key")" ]; then
        pass "$key is set"
      else
        warn "$key is not set"
      fi
    done

    if [ "$SOCKET_MODE_READY" = false ]; then
      warn "no Slack transport configured (set SLACK_BROKER_* for broker mode or SLACK_BOT_TOKEN+SLACK_APP_TOKEN for socket mode)"
    fi
  fi

  if grep -q '^SLACK_ALLOWED_USERS=.\+' "$ENV_FILE" 2>/dev/null; then
    pass "SLACK_ALLOWED_USERS is set"
  else
    warn "SLACK_ALLOWED_USERS is not set (all workspace members allowed)"
  fi
else
  if [ "$IS_ROOT" -ne 1 ] && [ -d "$BAUDBOT_HOME/.config" ]; then
    warn "cannot verify agent .env as non-root (run: sudo baudbot doctor)"
  else
    fail ".env not found at $ENV_FILE"
  fi
fi

# ── Runtime ──────────────────────────────────────────────────────────────────

echo ""
echo "Runtime:"

if [ -f "$BAUDBOT_HOME/runtime/start.sh" ]; then
  pass "start.sh deployed"
else
  if [ "$IS_ROOT" -ne 1 ] && [ -d "$BAUDBOT_HOME/runtime" ]; then
    warn "cannot verify start.sh as non-root (run: sudo baudbot doctor)"
  else
    fail "start.sh not found (run: baudbot deploy)"
  fi
fi

if [ -d "$BAUDBOT_HOME/.pi/agent/extensions" ]; then
  EXT_COUNT=$(find "$BAUDBOT_HOME/.pi/agent/extensions" -maxdepth 1 -name '*.ts' -o -name '*.mjs' 2>/dev/null | wc -l)
  pass "extensions deployed ($EXT_COUNT files)"
else
  if [ "$IS_ROOT" -ne 1 ] && [ -d "$BAUDBOT_HOME" ]; then
    warn "cannot verify extensions as non-root (run: sudo baudbot doctor)"
  else
    fail "extensions not deployed (run: baudbot deploy)"
  fi
fi

if [ -d "$BAUDBOT_HOME/.pi/agent/skills" ]; then
  pass "skills deployed"
else
  if [ "$IS_ROOT" -ne 1 ] && [ -d "$BAUDBOT_HOME" ]; then
    warn "cannot verify skills as non-root (run: sudo baudbot doctor)"
  else
    fail "skills not deployed (run: baudbot deploy)"
  fi
fi

BRIDGE_DIR="$BAUDBOT_CURRENT_LINK/slack-bridge"
if [ -d "$BRIDGE_DIR" ] && [ -f "$BRIDGE_DIR/bridge.mjs" ]; then
  pass "slack bridge deployed ($BRIDGE_DIR)"
else
  if [ "$IS_ROOT" -ne 1 ] && { [ -d "$BAUDBOT_CURRENT_LINK" ] || [ -e "$BAUDBOT_CURRENT_LINK" ]; }; then
    warn "cannot verify slack bridge files as non-root (run: sudo baudbot doctor)"
  else
    fail "slack bridge not deployed (expected: $BRIDGE_DIR; run: sudo baudbot update)"
  fi
fi

# ── Security ─────────────────────────────────────────────────────────────────

echo ""
echo "Security:"

# Firewall
if command -v iptables &>/dev/null && iptables -w -L BAUDBOT_OUTPUT -n &>/dev/null 2>&1; then
  RULE_COUNT=$(iptables -w -L BAUDBOT_OUTPUT -n 2>/dev/null | tail -n +3 | wc -l)
  pass "firewall active ($RULE_COUNT rules)"
else
  if command -v iptables &>/dev/null && [ "$IS_ROOT" -ne 1 ]; then
    warn "cannot verify firewall as non-root (run: sudo baudbot doctor)"
  else
    warn "firewall not active (run: baudbot setup)"
  fi
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
  if [ "$IS_ROOT" -ne 1 ] && [ -d "$BAUDBOT_HOME" ]; then
    warn "cannot verify tool-guard.ts as non-root (run: sudo baudbot doctor)"
  else
    fail "tool-guard.ts not found"
  fi
fi

# ── Agent Status ─────────────────────────────────────────────────────────────

echo ""
echo "Agent:"

if bb_has_systemd; then
  enabled_state=$(systemctl is-enabled baudbot 2>&1 || true)
  if [ "$enabled_state" = "enabled" ]; then
    pass "systemd unit enabled"

    active_state=$(systemctl is-active baudbot 2>&1 || true)
    if [ "$active_state" = "active" ]; then
      pass "agent is running (systemd)"
    elif [ "$IS_ROOT" -ne 1 ] && echo "$active_state" | grep -qiE 'access denied|not authorized|interactive authentication|required'; then
      warn "cannot verify agent runtime as non-root (run: sudo baudbot doctor)"
    else
      warn "agent is not running"
    fi
  elif [ "$IS_ROOT" -ne 1 ] && echo "$enabled_state" | grep -qiE 'access denied|not authorized|interactive authentication|required'; then
    warn "cannot verify systemd unit state as non-root (run: sudo baudbot doctor)"
  else
    warn "systemd unit not installed (run: baudbot setup)"
  fi
else
  # No systemd — check for pi process
  if pgrep -u "$BAUDBOT_AGENT_USER" -f "pi --session-control" &>/dev/null; then
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

doctor_summary_and_exit
