#!/bin/bash
# Baudbot Config — interactive secrets and configuration setup.
# Writes to ~/.baudbot/.env (admin-owned). Deploy copies to agent runtime.
#
# Usage: baudbot config
#        sudo baudbot config        (when run via install.sh)
#
# Can be re-run to update existing config. Existing values shown as defaults.

set -euo pipefail

# ── Formatting ───────────────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()  { echo -e "${BOLD}${GREEN}▸${RESET} $1"; }
warn()  { echo -e "${BOLD}${YELLOW}▸${RESET} $1"; }
ask()   { echo -en "${BOLD}${CYAN}?${RESET} $1"; }
dim()   { echo -e "${DIM}$1${RESET}"; }

# ── Determine config directory ───────────────────────────────────────────────

# If run as root via sudo, write to the admin user's ~/.baudbot/
# If run as a normal user, write to their own ~/.baudbot/
# BAUDBOT_CONFIG_USER env var overrides detection (used by install.sh)
if [ -n "${BAUDBOT_CONFIG_USER:-}" ]; then
  CONFIG_USER="$BAUDBOT_CONFIG_USER"
elif [ "$(id -u)" -eq 0 ]; then
  CONFIG_USER="${SUDO_USER:-root}"
  if [ "$CONFIG_USER" = "root" ]; then
    echo "Run as: sudo baudbot config (not as root directly)"
    exit 1
  fi
else
  CONFIG_USER="$(whoami)"
fi

if [ "$CONFIG_USER" = "$(whoami)" ] && [ -n "$HOME" ]; then
  CONFIG_HOME="$HOME"
else
  CONFIG_HOME=$(getent passwd "$CONFIG_USER" | cut -d: -f6)
fi

if [ -z "$CONFIG_HOME" ]; then
  echo "❌ Could not resolve home directory for user '$CONFIG_USER'"
  exit 1
fi

CONFIG_DIR="$CONFIG_HOME/.baudbot"
CONFIG_FILE="$CONFIG_DIR/.env"

mkdir -p "$CONFIG_DIR"
# Ensure owned by the admin user (not root)
if [ "$(id -u)" -eq 0 ]; then
  chown "$CONFIG_USER:$CONFIG_USER" "$CONFIG_DIR"
fi

# ── Load existing config ─────────────────────────────────────────────────────

declare -A ENV_VARS
declare -A EXISTING

if [ -f "$CONFIG_FILE" ]; then
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [ -z "$key" ] && continue
    EXISTING[$key]="$value"
  done < "$CONFIG_FILE"
fi

# ── Prompting ────────────────────────────────────────────────────────────────

# prompt_secret KEY "description" "url" [required] [prefix]
# If an existing value is set, shows [****] and allows Enter to keep it.
prompt_secret() {
  local key="$1" desc="$2" url="${3:-}" required="${4:-}" prefix="${5:-}"
  local label="" existing="${EXISTING[$key]:-}"

  if [ "$required" = "required" ]; then
    label="${RED}*${RESET} "
  fi

  if [ -n "$url" ]; then
    dim "  $url"
  fi

  if [ -n "$existing" ]; then
    # Show masked existing value
    local masked="${existing:0:4}****"
    ask "${label}${desc} [${masked}]: "
  else
    ask "${label}${desc}: "
  fi
  read -r value

  # Empty input with existing value = keep existing
  if [ -z "$value" ] && [ -n "$existing" ]; then
    ENV_VARS[$key]="$existing"
    return
  fi

  # Validate prefix if provided
  if [ -n "$value" ] && [ -n "$prefix" ]; then
    local match=false
    IFS='|' read -ra prefixes <<< "$prefix"
    for p in "${prefixes[@]}"; do
      if [[ "$value" == "$p"* ]]; then
        match=true
        break
      fi
    done
    if [ "$match" = false ]; then
      warn "Expected prefix '${prefix}' — saved anyway"
    fi
  fi

  # Warn if required and empty
  if [ -z "$value" ] && [ "$required" = "required" ]; then
    warn "Skipped (required — agent won't fully work without this)"
  fi

  if [ -n "$value" ]; then
    ENV_VARS[$key]="$value"
  fi
}

# ── Collect secrets ──────────────────────────────────────────────────────────

echo ""
if [ -f "$CONFIG_FILE" ]; then
  echo -e "Updating config in ${BOLD}$CONFIG_FILE${RESET}"
  echo -e "Press ${BOLD}Enter${RESET} to keep existing values."
else
  echo -e "Baudbot needs API keys to talk to services."
  echo -e "Press ${BOLD}Enter${RESET} to skip optional values."
fi
echo -e "  ${DIM}$CONFIG_FILE${RESET}"
echo ""

# -- Required --
echo -e "${BOLD}Required${RESET} ${DIM}(agent won't start without these)${RESET}"
echo ""

echo -e "${BOLD}LLM provider${RESET} ${DIM}(set at least one)${RESET}"
echo ""

prompt_secret "ANTHROPIC_API_KEY" \
  "Anthropic API key" \
  "https://console.anthropic.com/settings/keys" \
  "" \
  "sk-ant-"

prompt_secret "OPENAI_API_KEY" \
  "OpenAI API key" \
  "https://platform.openai.com/api-keys" \
  "" \
  "sk-"

prompt_secret "GEMINI_API_KEY" \
  "Google Gemini API key" \
  "https://aistudio.google.com/apikey"

prompt_secret "OPENCODE_ZEN_API_KEY" \
  "OpenCode Zen API key (multi-provider router)" \
  "https://opencode.ai"

HAS_LLM_KEY=false
for k in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_ZEN_API_KEY; do
  if [ -n "${ENV_VARS[$k]:-}" ]; then HAS_LLM_KEY=true; break; fi
done
if [ "$HAS_LLM_KEY" = false ]; then
  warn "No LLM key set — agent needs at least one to work"
fi

echo ""

prompt_secret "GITHUB_TOKEN" \
  "GitHub personal access token" \
  "https://github.com/settings/tokens" \
  "required" \
  "ghp_|github_pat_"

prompt_secret "SLACK_BOT_TOKEN" \
  "Slack bot token" \
  "https://api.slack.com/apps → OAuth & Permissions" \
  "required" \
  "xoxb-"

prompt_secret "SLACK_APP_TOKEN" \
  "Slack app-level token (Socket Mode)" \
  "https://api.slack.com/apps → Basic Information → App-Level Tokens" \
  "required" \
  "xapp-"

prompt_secret "SLACK_ALLOWED_USERS" \
  "Slack user IDs (comma-separated)" \
  "Click your Slack profile → ··· → Copy member ID" \
  "required" \
  "U"

echo ""

# -- Optional --
echo -e "${BOLD}Optional${RESET} ${DIM}(press Enter to skip)${RESET}"
echo ""

prompt_secret "AGENTMAIL_API_KEY" \
  "AgentMail API key" \
  "https://app.agentmail.to"

prompt_secret "BAUDBOT_EMAIL" \
  "Agent email address (e.g. agent@agentmail.to)"

if [ -n "${ENV_VARS[AGENTMAIL_API_KEY]:-}" ]; then
  prompt_secret "BAUDBOT_SECRET" \
    "Email auth secret (or press Enter to auto-generate)"
  if [ -z "${ENV_VARS[BAUDBOT_SECRET]:-}" ]; then
    ENV_VARS[BAUDBOT_SECRET]="$(openssl rand -hex 32)"
    dim "  Auto-generated: ${ENV_VARS[BAUDBOT_SECRET]}"
  fi

  prompt_secret "BAUDBOT_ALLOWED_EMAILS" \
    "Allowed sender emails (comma-separated)"
fi

prompt_secret "SENTRY_AUTH_TOKEN" \
  "Sentry API token" \
  "https://sentry.io/settings/account/api/auth-tokens/"

if [ -n "${ENV_VARS[SENTRY_AUTH_TOKEN]:-}" ]; then
  prompt_secret "SENTRY_ORG" "Sentry org slug"
  prompt_secret "SENTRY_CHANNEL_ID" "Slack channel ID for Sentry alerts" "" "" "C"
fi

prompt_secret "KERNEL_API_KEY" \
  "Kernel cloud browser API key" \
  "https://kernel.computer"

# ── Auto-set values ──────────────────────────────────────────────────────────

# These are set automatically based on the system state
ENV_VARS[BAUDBOT_AGENT_USER]="baudbot_agent"

if id baudbot_agent &>/dev/null; then
  ENV_VARS[BAUDBOT_AGENT_HOME]=$(getent passwd baudbot_agent | cut -d: -f6)
else
  ENV_VARS[BAUDBOT_AGENT_HOME]="/home/baudbot_agent"
fi

# Source dir: resolve from this script's location, or keep existing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup.sh" ]; then
  ENV_VARS[BAUDBOT_SOURCE_DIR]="$SCRIPT_DIR"
elif [ -n "${EXISTING[BAUDBOT_SOURCE_DIR]:-}" ]; then
  ENV_VARS[BAUDBOT_SOURCE_DIR]="${EXISTING[BAUDBOT_SOURCE_DIR]}"
fi

# ── Write config ─────────────────────────────────────────────────────────────

ENV_CONTENT="# Baudbot configuration
# Generated by baudbot config on $(date -Iseconds)
# Re-run: baudbot config
# Deploy: baudbot deploy
"

ordered_keys=(
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  GEMINI_API_KEY
  OPENCODE_ZEN_API_KEY
  GITHUB_TOKEN
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  SLACK_ALLOWED_USERS
  AGENTMAIL_API_KEY
  BAUDBOT_EMAIL
  BAUDBOT_SECRET
  BAUDBOT_ALLOWED_EMAILS
  SENTRY_AUTH_TOKEN
  SENTRY_ORG
  SENTRY_CHANNEL_ID
  KERNEL_API_KEY
  BAUDBOT_AGENT_USER
  BAUDBOT_AGENT_HOME
  BAUDBOT_SOURCE_DIR
)

for key in "${ordered_keys[@]}"; do
  if [ -n "${ENV_VARS[$key]:-}" ]; then
    ENV_CONTENT+="${key}=${ENV_VARS[$key]}"$'\n'
  fi
done

echo "$ENV_CONTENT" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
# Ensure owned by admin user
if [ "$(id -u)" -eq 0 ]; then
  chown "$CONFIG_USER:$CONFIG_USER" "$CONFIG_FILE"
fi

VAR_COUNT=$(grep -c '=' "$CONFIG_FILE")
info "Wrote $VAR_COUNT variables to $CONFIG_FILE"
echo ""
echo -e "Next: ${BOLD}sudo baudbot deploy${RESET} to push config to the agent"
echo ""
