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
ask()   { echo -en "${BOLD}${CYAN}?${RESET} $1" >&2; }
dim()   { echo -e "${DIM}$1${RESET}"; }

# ── UI helpers (gum when available, fallback to bash) ───────────────────────

USE_GUM=0
BAUDBOT_TRY_INSTALL_GUM="${BAUDBOT_TRY_INSTALL_GUM:-1}"

is_interactive_tty() {
  [ -t 0 ] && [ -t 1 ]
}

detect_distro() {
  local distro="unknown"
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) distro="ubuntu" ;;
      arch|archarm) distro="arch" ;;
      *)
        if [ -n "${ID_LIKE:-}" ]; then
          case "$ID_LIKE" in
            *debian*|*ubuntu*) distro="ubuntu" ;;
            *arch*) distro="arch" ;;
          esac
        fi
        ;;
    esac
  fi
  echo "$distro"
}

try_install_gum() {
  [ "$BAUDBOT_TRY_INSTALL_GUM" = "1" ] || return 1
  is_interactive_tty || return 1

  if command -v gum >/dev/null 2>&1; then
    return 0
  fi

  local distro
  distro="$(detect_distro)"

  if [ "$distro" = "arch" ] && command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm --needed gum >/dev/null 2>&1 || true
  elif [ "$distro" = "ubuntu" ] && command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq gum >/dev/null 2>&1 || true
  fi

  command -v gum >/dev/null 2>&1
}

init_ui() {
  if ! is_interactive_tty; then
    return
  fi

  if command -v gum >/dev/null 2>&1; then
    USE_GUM=1
    return
  fi

  if try_install_gum; then
    USE_GUM=1
    info "Using gum for interactive prompts"
  fi
}

ui_confirm() {
  local prompt="$1" default_yes="${2:-false}"
  if [ "$USE_GUM" -eq 1 ]; then
    if [ "$default_yes" = "true" ]; then
      gum confirm --default=true "$prompt"
    else
      gum confirm --default=false "$prompt"
    fi
    return $?
  fi

  local suffix="[y/N]"
  if [ "$default_yes" = "true" ]; then
    suffix="[Y/n]"
  fi

  local answer=""
  read -r -p "$prompt $suffix: " answer
  if [ -z "$answer" ]; then
    [ "$default_yes" = "true" ]
    return $?
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

ui_choose() {
  local prompt="$1"
  shift
  local options=("$@")

  if [ "$USE_GUM" -eq 1 ]; then
    gum choose --header "$prompt" "${options[@]}"
    return $?
  fi

  echo "$prompt" >&2
  local choice=""
  local PS3="Enter choice [1-${#options[@]}]: "
  select choice in "${options[@]}"; do
    if [ -n "$choice" ]; then
      printf '%s\n' "$choice"
      return 0
    fi
    echo "Invalid choice" >&2
  done
}

ui_input() {
  local prompt="$1" default_value="${2:-}" sensitive="${3:-false}"

  if [ "$USE_GUM" -eq 1 ]; then
    local cmd=(gum input --prompt "$prompt ")
    if [ -n "$default_value" ]; then
      cmd+=(--value "$default_value")
    fi
    if [ "$sensitive" = "true" ]; then
      cmd+=(--password)
    fi
    "${cmd[@]}"
    return $?
  fi

  local value=""
  if [ "$sensitive" = "true" ] && [ -t 0 ]; then
    if [ -n "$default_value" ]; then
      ask "$prompt [$default_value]: "
    else
      ask "$prompt: "
    fi
    read -rs value
    echo "" >&2
  else
    if [ -n "$default_value" ]; then
      ask "$prompt [$default_value]: "
    else
      ask "$prompt: "
    fi
    read -r value
  fi

  if [ -z "$value" ] && [ -n "$default_value" ]; then
    value="$default_value"
  fi

  printf '%s\n' "$value"
}

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

# Start with existing values so unprompted keys are preserved.
for key in "${!EXISTING[@]}"; do
  ENV_VARS[$key]="${EXISTING[$key]}"
done

init_ui

# ── Prompting ────────────────────────────────────────────────────────────────

clear_keys() {
  for key in "$@"; do
    unset "ENV_VARS[$key]"
  done
}

# prompt_secret KEY "description" "url" [required] [prefix] [sensitive]
# If an existing value is set, shows [****] and allows Enter to keep it.
# sensitive defaults to "true" — input is hidden. Pass "false" for visible input.
prompt_secret() {
  local key="$1" desc="$2" url="${3:-}" required="${4:-}" prefix="${5:-}" sensitive="${6:-true}"
  local label="" existing="${ENV_VARS[$key]:-}" value=""

  if [ "$required" = "required" ]; then
    label="${RED}*${RESET} "
  fi

  if [ -n "$url" ]; then
    dim "  $url"
  fi

  if [ -n "$existing" ]; then
    local masked="${existing:0:4}****"
    dim "  Existing: ${masked} (press Enter to keep)"
  fi

  value="$(ui_input "${label}${desc}" "" "$sensitive")"

  # Empty input with existing value = keep existing
  if [ -z "$value" ] && [ -n "$existing" ]; then
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
    return
  fi

  if [ -n "$value" ]; then
    ENV_VARS[$key]="$value"
  elif [ -z "$existing" ]; then
    unset "ENV_VARS[$key]"
  fi
}

# ── Collect secrets ──────────────────────────────────────────────────────────

echo ""
if [ -f "$CONFIG_FILE" ]; then
  echo -e "Updating config in ${BOLD}$CONFIG_FILE${RESET}"
  echo -e "Press ${BOLD}Enter${RESET} to keep existing values where shown."
else
  echo -e "Baudbot needs API keys to talk to services."
  echo -e "Press ${BOLD}Enter${RESET} to skip optional values."
fi
echo -e "  ${DIM}$CONFIG_FILE${RESET}"
echo ""

# -- Required --
echo -e "${BOLD}Required${RESET} ${DIM}(agent won't start without these)${RESET}"
echo ""

# LLM provider picker
echo -e "${BOLD}LLM provider${RESET}"
LLM_CHOICE="$(ui_choose "Choose your primary LLM provider:" \
  "Anthropic" \
  "OpenAI" \
  "Gemini" \
  "OpenCode Zen")"

# Clear other provider keys so choice is explicit and deterministic.
clear_keys ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_ZEN_API_KEY

case "$LLM_CHOICE" in
  "Anthropic")
    prompt_secret "ANTHROPIC_API_KEY" \
      "Anthropic API key" \
      "https://console.anthropic.com/settings/keys" \
      "required" \
      "sk-ant-"
    ;;
  "OpenAI")
    prompt_secret "OPENAI_API_KEY" \
      "OpenAI API key" \
      "https://platform.openai.com/api-keys" \
      "required" \
      "sk-"
    ;;
  "Gemini")
    prompt_secret "GEMINI_API_KEY" \
      "Google Gemini API key" \
      "https://aistudio.google.com/apikey" \
      "required"
    ;;
  "OpenCode Zen")
    prompt_secret "OPENCODE_ZEN_API_KEY" \
      "OpenCode Zen API key (multi-provider router)" \
      "https://opencode.ai" \
      "required"
    ;;
esac

SELECTED_LLM_KEY=""
case "$LLM_CHOICE" in
  "Anthropic") SELECTED_LLM_KEY="ANTHROPIC_API_KEY" ;;
  "OpenAI") SELECTED_LLM_KEY="OPENAI_API_KEY" ;;
  "Gemini") SELECTED_LLM_KEY="GEMINI_API_KEY" ;;
  "OpenCode Zen") SELECTED_LLM_KEY="OPENCODE_ZEN_API_KEY" ;;
esac

if [ -z "${ENV_VARS[$SELECTED_LLM_KEY]:-}" ]; then
  echo "❌ $SELECTED_LLM_KEY is required for selected provider '$LLM_CHOICE'"
  exit 1
fi

echo ""

# Slack integration mode picker
echo -e "${BOLD}Slack integration${RESET}"
SLACK_CHOICE="$(ui_choose "Choose Slack integration mode:" \
  "Use baudbot.ai Slack integration (easy)" \
  "Use your own Slack integration (advanced)")"

if [ "$SLACK_CHOICE" = "Use baudbot.ai Slack integration (easy)" ]; then
  dim "  We'll set up broker registration after install via: sudo baudbot broker register"
  clear_keys SLACK_BOT_TOKEN SLACK_APP_TOKEN
  prompt_secret "SLACK_ALLOWED_USERS" \
    "Slack user IDs (comma-separated; optional — allow all if empty)" \
    "Click your Slack profile → ··· → Copy member ID" \
    "" \
    "U" \
    "false"
else
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
    "Slack user IDs (comma-separated; optional — allow all if empty)" \
    "Click your Slack profile → ··· → Copy member ID" \
    "" \
    "U" \
    "false"
fi

echo ""
# -- Optional --
echo -e "${BOLD}Optional integrations${RESET} ${DIM}(you can enable these later)${RESET}"
echo ""

# Browser / Kernel
HAS_KERNEL=false
if [ -n "${ENV_VARS[KERNEL_API_KEY]:-}" ]; then HAS_KERNEL=true; fi
if ui_confirm "Set up Browser Integration (via Kernel)?" "$HAS_KERNEL"; then
  prompt_secret "KERNEL_API_KEY" \
    "Kernel cloud browser API key" \
    "https://kernel.computer"
  if [ -n "${ENV_VARS[KERNEL_API_KEY]:-}" ]; then HAS_KERNEL=true; fi
else
  clear_keys KERNEL_API_KEY
  HAS_KERNEL=false
fi

echo ""

# Sentry
HAS_SENTRY=false
if [ -n "${ENV_VARS[SENTRY_AUTH_TOKEN]:-}" ]; then HAS_SENTRY=true; fi
if ui_confirm "Set up Sentry Integration?" "$HAS_SENTRY"; then
  prompt_secret "SENTRY_AUTH_TOKEN" \
    "Sentry API token" \
    "https://sentry.io/settings/account/api/auth-tokens/"

  if [ -n "${ENV_VARS[SENTRY_AUTH_TOKEN]:-}" ]; then
    prompt_secret "SENTRY_ORG" "Sentry org slug" "" "" "" "false"
    prompt_secret "SENTRY_CHANNEL_ID" "Slack channel ID for Sentry alerts" "" "" "C" "false"
    HAS_SENTRY=true
  else
    clear_keys SENTRY_ORG SENTRY_CHANNEL_ID
    HAS_SENTRY=false
  fi
else
  clear_keys SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_CHANNEL_ID
  HAS_SENTRY=false
fi

echo ""

# Email / AgentMail
HAS_EMAIL=false
if [ -n "${ENV_VARS[AGENTMAIL_API_KEY]:-}" ] || [ -n "${ENV_VARS[BAUDBOT_EMAIL]:-}" ]; then HAS_EMAIL=true; fi
if ui_confirm "Set up Email Integration (via AgentMail)?" "$HAS_EMAIL"; then
  prompt_secret "AGENTMAIL_API_KEY" \
    "AgentMail API key" \
    "https://app.agentmail.to"

  prompt_secret "BAUDBOT_EMAIL" \
    "Agent email address (e.g. agent@agentmail.to)" \
    "" "" "" "false"

  if [ -n "${ENV_VARS[AGENTMAIL_API_KEY]:-}" ]; then
    prompt_secret "BAUDBOT_SECRET" \
      "Email auth secret (or press Enter to auto-generate)"
    if [ -z "${ENV_VARS[BAUDBOT_SECRET]:-}" ]; then
      ENV_VARS[BAUDBOT_SECRET]="$(openssl rand -hex 32)"
      dim "  Auto-generated BAUDBOT_SECRET"
    fi

    prompt_secret "BAUDBOT_ALLOWED_EMAILS" \
      "Allowed sender emails (comma-separated)" \
      "" "" "" "false"
    HAS_EMAIL=true
  else
    clear_keys BAUDBOT_SECRET BAUDBOT_ALLOWED_EMAILS
    HAS_EMAIL=false
  fi
else
  clear_keys AGENTMAIL_API_KEY BAUDBOT_EMAIL BAUDBOT_SECRET BAUDBOT_ALLOWED_EMAILS
  HAS_EMAIL=false
fi

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
elif [ -n "${ENV_VARS[BAUDBOT_SOURCE_DIR]:-}" ]; then
  ENV_VARS[BAUDBOT_SOURCE_DIR]="${ENV_VARS[BAUDBOT_SOURCE_DIR]}"
fi

# ── Validation ───────────────────────────────────────────────────────────────

if [ "$LLM_CHOICE" = "Anthropic" ] && [ -z "${ENV_VARS[ANTHROPIC_API_KEY]:-}" ]; then
  warn "Anthropic selected but ANTHROPIC_API_KEY is empty"
fi
if [ "$LLM_CHOICE" = "OpenAI" ] && [ -z "${ENV_VARS[OPENAI_API_KEY]:-}" ]; then
  warn "OpenAI selected but OPENAI_API_KEY is empty"
fi
if [ "$LLM_CHOICE" = "Gemini" ] && [ -z "${ENV_VARS[GEMINI_API_KEY]:-}" ]; then
  warn "Gemini selected but GEMINI_API_KEY is empty"
fi
if [ "$LLM_CHOICE" = "OpenCode Zen" ] && [ -z "${ENV_VARS[OPENCODE_ZEN_API_KEY]:-}" ]; then
  warn "OpenCode Zen selected but OPENCODE_ZEN_API_KEY is empty"
fi

if [ -z "${ENV_VARS[SLACK_ALLOWED_USERS]:-}" ]; then
  warn "SLACK_ALLOWED_USERS not set — all workspace members will be allowed"
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
  LINEAR_API_KEY
  SLACK_BROKER_URL
  SLACK_BROKER_WORKSPACE_ID
  SLACK_BROKER_SERVER_PRIVATE_KEY
  SLACK_BROKER_SERVER_PUBLIC_KEY
  SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY
  SLACK_BROKER_SERVER_SIGNING_PUBLIC_KEY
  SLACK_BROKER_PUBLIC_KEY
  SLACK_BROKER_SIGNING_PUBLIC_KEY
  SLACK_BROKER_POLL_INTERVAL_MS
  SLACK_BROKER_MAX_MESSAGES
  SLACK_BROKER_DEDUPE_TTL_MS
  BAUDBOT_AGENT_USER
  BAUDBOT_AGENT_HOME
  BAUDBOT_SOURCE_DIR
  BRIDGE_API_PORT
  PI_SESSION_ID
)

declare -A WRITTEN
for key in "${ordered_keys[@]}"; do
  if [ -n "${ENV_VARS[$key]:-}" ]; then
    ENV_CONTENT+="${key}=${ENV_VARS[$key]}"$'\n'
    WRITTEN[$key]=1
  fi
done

# Preserve unknown keys that may come from future versions/custom setups.
for key in "${!ENV_VARS[@]}"; do
  if [ -n "${WRITTEN[$key]:-}" ]; then
    continue
  fi
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
echo -e "${BOLD}Summary${RESET}"
echo -e "  LLM provider: ${BOLD}${LLM_CHOICE}${RESET}"
echo -e "  Slack mode:   ${BOLD}${SLACK_CHOICE}${RESET}"
if [ "$SLACK_CHOICE" = "Use baudbot.ai Slack integration (easy)" ]; then
  echo -e "  ${DIM}Next: run 'sudo baudbot broker register' after install${RESET}"
fi
echo -e "  Browser (Kernel): $( [ "$HAS_KERNEL" = true ] && echo "enabled" || echo "disabled" )"
echo -e "  Sentry:           $( [ "$HAS_SENTRY" = true ] && echo "enabled" || echo "disabled" )"
echo -e "  Email:            $( [ "$HAS_EMAIL" = true ] && echo "enabled" || echo "disabled" )"
echo ""
echo -e "Next: ${BOLD}sudo baudbot deploy${RESET} to push config to the agent"
echo ""