#!/bin/bash
# Baudbot Interactive Installer
#
# One-command setup (bootstrap CLI):
#   curl -fsSL https://raw.githubusercontent.com/modem-dev/baudbot/main/bootstrap.sh | bash
#   baudbot install
#
# Or if you prefer source checkout first:
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

EXPERIMENTAL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --experimental)
      EXPERIMENTAL=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--experimental]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--experimental]"
      exit 1
      ;;
  esac
done

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
if [ "$EXPERIMENTAL" -eq 1 ]; then
  echo -e "${YELLOW}Experimental mode enabled: optional risky integrations may be installed.${RESET}"
fi
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

apt_background_procs_ubuntu() {
  # Ignore unattended-upgrade-shutdown --wait-for-signal. It can remain active
  # with no apt/dpkg lock contention and causes false waits on fresh Ubuntu VMs.
  pgrep -f -a '(apt.systemd.daily|apt-get|dpkg|unattended-upgrade)' 2>/dev/null \
    | grep -v 'unattended-upgrade-shutdown --wait-for-signal' || true
}

install_prereqs_ubuntu() {
  # Wait for unattended-upgrades (common on fresh VMs)
  if [ -n "$(apt_background_procs_ubuntu)" ]; then
    info "Waiting for background apt to finish..."
    for _ in $(seq 1 60); do
      if [ -z "$(apt_background_procs_ubuntu)" ]; then
        break
      fi
      sleep 2
    done
  fi

  for attempt in $(seq 1 5); do
    if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq \
      && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq git curl tmux iptables docker.io gh sudo 2>&1 | tail -3; then
      return 0
    fi

    if [ "$attempt" -eq 5 ]; then
      err "apt failed after $attempt attempts"
      apt_background_procs_ubuntu >&2 || true
      return 1
    fi

    warn "apt busy (attempt $attempt/5), retrying in 5s..."
    sleep 5
  done
}

install_prereqs_arch() {
  pacman -Syu --noconfirm --needed git curl tmux iptables docker github-cli sudo 2>&1 | tail -5
}

info "Installing: git, curl, tmux, iptables, docker, gh, sudo"
"install_prereqs_$DISTRO"
info "Prerequisites installed"

# ── Clone or locate repo ────────────────────────────────────────────────────

header "Source"

REPO_DIR="${BAUDBOT_REPO_DIR:-$ADMIN_HOME/baudbot}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup.sh" ] && [ -f "$SCRIPT_DIR/bin/deploy.sh" ]; then
  # Running from an existing checkout/snapshot
  REPO_DIR="$SCRIPT_DIR"
  info "Using existing source: $REPO_DIR"
else
  # Need to locate or clone source
  if [ -d "$REPO_DIR/.git" ]; then
    if sudo -u "$ADMIN_USER" git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
      info "Repo already exists at $REPO_DIR, pulling latest..."
      sudo -u "$ADMIN_USER" git -C "$REPO_DIR" pull --ff-only 2>&1 | tail -1
    elif [ -f "$REPO_DIR/setup.sh" ] && [ -f "$REPO_DIR/bin/deploy.sh" ]; then
      info "Repo exists at $REPO_DIR (no origin remote), using local source snapshot"
    else
      die "Repo at $REPO_DIR has no origin and missing setup files"
    fi
  elif [ -f "$REPO_DIR/setup.sh" ] && [ -f "$REPO_DIR/bin/deploy.sh" ]; then
    info "Using local source snapshot: $REPO_DIR"
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

if [ "$EXPERIMENTAL" -eq 1 ]; then
  BAUDBOT_PI_VERSION="${BAUDBOT_PI_VERSION:-}" bash "$REPO_DIR/setup.sh" --experimental "$ADMIN_USER"
else
  BAUDBOT_PI_VERSION="${BAUDBOT_PI_VERSION:-}" bash "$REPO_DIR/setup.sh" "$ADMIN_USER"
fi

echo ""
info "Core setup complete"

# ── Configure secrets ────────────────────────────────────────────────────────

header "Secrets"

BAUDBOT_HOME="/home/baudbot_agent"
ENV_FILE="$BAUDBOT_HOME/.config/.env"

# Run baudbot config to collect secrets into ~/.baudbot/.env on the admin user.
# config.sh handles prompting, validation, and writing to the admin config dir.
BAUDBOT_CONFIG_USER="$ADMIN_USER" BAUDBOT_EXPERIMENTAL="$EXPERIMENTAL" bash "$REPO_DIR/bin/config.sh"

# Publish and deploy the initial git-free release from the local checkout.
# This also copies ~/.baudbot/.env → agent's ~/.config/.env with correct perms.
header "Deploy"
BOOTSTRAP_BRANCH=$(sudo -u "$ADMIN_USER" git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
BAUDBOT_ROOT="$REPO_DIR" BAUDBOT_CONFIG_USER="$ADMIN_USER" BAUDBOT_EXPERIMENTAL="$EXPERIMENTAL" \
  bash "$REPO_DIR/bin/update-release.sh" --repo "$REPO_DIR" --branch "$BOOTSTRAP_BRANCH" --skip-preflight --skip-restart

# ── Launch ───────────────────────────────────────────────────────────────────

header "Launch"

# Check if we have the minimum required secrets (read from deployed .env)
MISSING=""
HAS_LLM=false
if [ -f "$ENV_FILE" ]; then
  for k in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_ZEN_API_KEY; do
    if grep -q "^${k}=.\+" "$ENV_FILE" 2>/dev/null; then HAS_LLM=true; break; fi
  done
fi
if [ "$HAS_LLM" = false ]; then
  MISSING+="  - LLM key (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY)\n"
fi
HAS_SOCKET=false
HAS_BROKER=false

if grep -q '^SLACK_BOT_TOKEN=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_APP_TOKEN=.\+' "$ENV_FILE" 2>/dev/null; then
  HAS_SOCKET=true
fi

if grep -q '^SLACK_BROKER_URL=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_BROKER_WORKSPACE_ID=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_BROKER_SERVER_PRIVATE_KEY=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_BROKER_SERVER_PUBLIC_KEY=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_BROKER_PUBLIC_KEY=.\+' "$ENV_FILE" 2>/dev/null \
  && grep -q '^SLACK_BROKER_SIGNING_PUBLIC_KEY=.\+' "$ENV_FILE" 2>/dev/null; then
  HAS_BROKER=true
fi

if [ "$HAS_SOCKET" = false ] && [ "$HAS_BROKER" = false ]; then
  MISSING+="  - Slack integration (either SLACK_BOT_TOKEN + SLACK_APP_TOKEN, or broker registration via 'sudo baudbot broker register')\n"
fi

if ! grep -q '^SLACK_ALLOWED_USERS=.\+' "$ENV_FILE" 2>/dev/null; then
  warn "SLACK_ALLOWED_USERS not set — all workspace members will be allowed"
fi

if [ -n "$MISSING" ]; then
  warn "Missing required secrets — skipping launch:"
  echo -e "$MISSING"
  echo -e "Add them with ${BOLD}baudbot config${RESET} and deploy with ${BOLD}baudbot deploy${RESET}"
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
echo -e "  ${BOLD}Edit secrets:${RESET}    sudo baudbot config && sudo baudbot deploy"
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
echo -e "  ${YELLOW}⚠${RESET}  Authenticate GitHub CLI:"
echo -e "     sudo -u baudbot_agent gh auth login"
echo ""
echo -e "  ${DIM}Full configuration reference: $REPO_DIR/CONFIGURATION.md${RESET}"
echo ""
