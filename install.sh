#!/bin/bash
# Baudbot Interactive Installer
#
# One-command setup:
#   git clone https://github.com/modem-dev/baudbot.git ~/baudbot && sudo ~/baudbot/install.sh
#
# Or if already cloned:
#   sudo ./install.sh
#
# What this does:
#   1. Detects distro, installs system prerequisites
#   2. Clones the repo (or uses existing clone)
#   3. Runs setup.sh (user, Node.js, firewall, etc.)
#   4. Walks you through secrets interactively
#   5. Deploys and launches the agent
#
# Must run as root. Tested on Ubuntu 24.04 and Arch Linux.

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
err()   { echo -e "${BOLD}${RED}✗${RESET} $1" >&2; }
ask()   { echo -en "${BOLD}${CYAN}?${RESET} $1"; }
dim()   { echo -e "${DIM}$1${RESET}"; }
header() { echo -e "\n${BOLD}── $1 ──${RESET}\n"; }

die() { err "$1"; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  die "Must run as root. Try: sudo $0"
fi

if [[ ! "$(uname -s)" =~ Linux ]]; then
  die "Baudbot requires Linux (kernel-level isolation). macOS/Windows are not supported."
fi

echo ""
echo -e "${BOLD}🤖 Baudbot Installer${RESET}"
echo ""

# ── Detect distro ────────────────────────────────────────────────────────────

header "System"

DISTRO="unknown"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "$ID" in
    ubuntu|debian) DISTRO="ubuntu" ;;
    arch|archarm)  DISTRO="arch" ;;
    *)
      if [ -n "${ID_LIKE:-}" ]; then
        case "$ID_LIKE" in
          *debian*|*ubuntu*) DISTRO="ubuntu" ;;
          *arch*)            DISTRO="arch" ;;
        esac
      fi
      ;;
  esac
fi

if [ "$DISTRO" = "unknown" ]; then
  die "Unsupported distro. Baudbot is tested on Ubuntu 24.04 and Arch Linux."
fi

info "Detected: ${BOLD}$PRETTY_NAME${RESET} ($DISTRO)"

# ── Detect admin user ────────────────────────────────────────────────────────

# If run via sudo, SUDO_USER is the real user. Otherwise ask.
ADMIN_USER="${SUDO_USER:-}"
if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = "root" ]; then
  # Try to find a non-root user with a home directory
  ADMIN_USER=""
  while IFS=: read -r username _ uid _ _ home _; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] && [ -d "$home" ] && [ "$username" != "baudbot_agent" ]; then
      ADMIN_USER="$username"
      break
    fi
  done < /etc/passwd

  if [ -z "$ADMIN_USER" ]; then
    ask "Admin username (your account, not root): "
    read -r ADMIN_USER
  else
    ask "Admin username [${ADMIN_USER}]: "
    read -r input
    if [ -n "$input" ]; then
      ADMIN_USER="$input"
    fi
  fi
fi

if ! id "$ADMIN_USER" &>/dev/null; then
  die "User '$ADMIN_USER' does not exist."
fi

ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
info "Admin user: ${BOLD}$ADMIN_USER${RESET} ($ADMIN_HOME)"

# ── Install prerequisites ────────────────────────────────────────────────────

header "Prerequisites"

install_prereqs_ubuntu() {
  # Wait for unattended-upgrades (common on fresh VMs)
  if pgrep -x 'apt|apt-get|dpkg|unattended-upgrade' >/dev/null 2>&1; then
    info "Waiting for background apt to finish..."
    for _ in $(seq 1 60); do
      if ! pgrep -x 'apt|apt-get|dpkg|unattended-upgrade' >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  fi
  apt-get update -qq
  apt-get install -y -qq git curl tmux iptables docker.io sudo 2>&1 | tail -3
}

install_prereqs_arch() {
  pacman -Syu --noconfirm --needed git curl tmux iptables docker sudo 2>&1 | tail -5
}

info "Installing: git, curl, tmux, iptables, docker, sudo"
"install_prereqs_$DISTRO"
info "Prerequisites installed"

# ── Clone or locate repo ────────────────────────────────────────────────────

header "Source"

REPO_DIR="$ADMIN_HOME/baudbot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup.sh" ] && [ -f "$SCRIPT_DIR/bin/deploy.sh" ]; then
  # Running from an existing clone
  REPO_DIR="$SCRIPT_DIR"
  info "Using existing clone: $REPO_DIR"
else
  # Need to clone
  if [ -d "$REPO_DIR/.git" ]; then
    info "Repo already exists at $REPO_DIR, pulling latest..."
    sudo -u "$ADMIN_USER" git -C "$REPO_DIR" pull --ff-only 2>&1 | tail -1
  else
    REPO_URL="https://github.com/modem-dev/baudbot.git"
    info "Cloning $REPO_URL → $REPO_DIR"
    sudo -u "$ADMIN_USER" git clone "$REPO_URL" "$REPO_DIR" 2>&1 | tail -1
  fi
fi

if [ ! -f "$REPO_DIR/setup.sh" ]; then
  die "setup.sh not found in $REPO_DIR — bad clone?"
fi

info "Source ready: $REPO_DIR"

# ── Run setup.sh ─────────────────────────────────────────────────────────────

header "Setup"

info "Running setup.sh (user, Node.js, firewall, permissions)..."
info "This takes 1–2 minutes."
echo ""
bash "$REPO_DIR/setup.sh" "$ADMIN_USER"
echo ""
info "Core setup complete"

# ── Interactive secrets ──────────────────────────────────────────────────────

header "Secrets"

BAUDBOT_HOME="/home/baudbot_agent"
ENV_FILE="$BAUDBOT_HOME/.config/.env"

echo -e "Baudbot needs API keys to talk to services. You'll be prompted for each one."
echo -e "Press ${BOLD}Enter${RESET} to skip optional values. You can always edit later:"
echo -e "  ${DIM}$ENV_FILE${RESET}"
echo ""

# Accumulate env vars
declare -A ENV_VARS

# prompt_secret KEY "description" "url" [required] [prefix]
prompt_secret() {
  local key="$1" desc="$2" url="${3:-}" required="${4:-}" prefix="${5:-}"
  local label=""
  if [ "$required" = "required" ]; then
    label="${RED}*${RESET} "
  fi

  if [ -n "$url" ]; then
    dim "  $url"
  fi
  ask "${label}${desc}: "
  read -r value

  # Validate prefix if provided (prefix can be "a|b" for alternatives)
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

# Always set these
ENV_VARS[BAUDBOT_AGENT_USER]="baudbot_agent"
ENV_VARS[BAUDBOT_AGENT_HOME]="$BAUDBOT_HOME"
ENV_VARS[BAUDBOT_SOURCE_DIR]="$REPO_DIR"

# ── Write .env ───────────────────────────────────────────────────────────────

header "Configuration"

# Build .env content
ENV_CONTENT="# Baudbot agent configuration
# Generated by install.sh on $(date -Iseconds)
# Edit with: sudo -u baudbot_agent vim $ENV_FILE
"

# Write in a sensible order
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

# Write as agent user with correct permissions
echo "$ENV_CONTENT" > "$ENV_FILE"
chown baudbot_agent:baudbot_agent "$ENV_FILE"
chmod 600 "$ENV_FILE"

info "Wrote $(grep -c '=' "$ENV_FILE") variables to $ENV_FILE"

# ── Launch ───────────────────────────────────────────────────────────────────

header "Launch"

# Check if we have the minimum required secrets
MISSING=""
HAS_LLM=false
for k in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_ZEN_API_KEY; do
  if [ -n "${ENV_VARS[$k]:-}" ]; then HAS_LLM=true; break; fi
done
if [ "$HAS_LLM" = false ]; then
  MISSING+="  - LLM key (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY)\n"
fi
for key in GITHUB_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS; do
  if [ -z "${ENV_VARS[$key]:-}" ]; then
    MISSING+="  - $key\n"
  fi
done

if [ -n "$MISSING" ]; then
  warn "Missing required secrets — skipping launch:"
  echo -e "$MISSING"
  echo -e "Add them to ${BOLD}$ENV_FILE${RESET} and start manually:"
  echo -e "  ${DIM}sudo -u baudbot_agent ~/runtime/start.sh${RESET}"
  echo ""
else
  ask "Start the agent now? [Y/n]: "
  read -r launch
  if [ -z "$launch" ] || [[ "$launch" =~ ^[Yy] ]]; then
    info "Launching agent..."
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
      systemctl start baudbot 2>/dev/null || true
      sleep 2
      if systemctl is-active baudbot &>/dev/null 2>&1; then
        info "Agent is running ✓"
      else
        warn "Agent didn't start — check: baudbot logs"
      fi
    else
      sudo -u baudbot_agent tmux new-session -d -s baudbot "$BAUDBOT_HOME/runtime/start.sh" 2>/dev/null || true
      sleep 2
      if sudo -u baudbot_agent tmux has-session -t baudbot 2>/dev/null; then
        info "Agent is running ✓"
      else
        warn "Agent didn't start — try: baudbot start --direct"
      fi
    fi
  else
    info "Skipped. Start later with:"
    echo -e "  ${DIM}sudo baudbot start${RESET}"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────

header "Done"

SSH_PUB="$BAUDBOT_HOME/.ssh/id_ed25519.pub"

echo -e "🐝 ${BOLD}Baudbot is installed.${RESET}"
echo ""
echo -e "  ${BOLD}Start agent:${RESET}     sudo baudbot start"
echo -e "  ${BOLD}Agent status:${RESET}    sudo baudbot status"
echo -e "  ${BOLD}View logs:${RESET}       sudo baudbot logs"
echo -e "  ${BOLD}Edit secrets:${RESET}    sudo -u baudbot_agent vim $ENV_FILE"
echo -e "  ${BOLD}Deploy changes:${RESET}  sudo baudbot deploy"
echo -e "  ${BOLD}Health check:${RESET}    sudo baudbot doctor"
echo -e "  ${BOLD}Security audit:${RESET}  sudo baudbot audit"
echo ""
if [ -f "$SSH_PUB" ]; then
  echo -e "  ${YELLOW}⚠${RESET}  Add the agent's SSH key to GitHub:"
  echo -e "     $(cat "$SSH_PUB")"
  echo -e "     ${DIM}https://github.com/settings/keys${RESET}"
  echo ""
fi
echo -e "  ${DIM}Full configuration reference: $REPO_DIR/CONFIGURATION.md${RESET}"
echo ""
