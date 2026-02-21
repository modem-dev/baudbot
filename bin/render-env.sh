#!/bin/bash
# Render baudbot env from configured source backend.
#
# Backends (admin-scoped):
# - file (default): ~/.baudbot/.env
# - command: execute BAUDBOT_ENV_COMMAND from ~/.baudbot/env-store.conf

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  render-env.sh [--get KEY|--backend|--check]

Options:
  --get KEY   Print value for KEY from rendered env
  --backend   Print active backend (file|command)
  --check     Validate backend/source accessibility
EOF
}

resolve_user_home() {
  local user="$1"
  local passwd_line=""

  [ -n "$user" ] || return 1

  passwd_line="$(getent passwd "$user" 2>/dev/null || true)"
  if [ -n "$passwd_line" ]; then
    echo "$passwd_line" | cut -d: -f6
    return 0
  fi

  if [ -d "/home/$user" ]; then
    echo "/home/$user"
    return 0
  fi

  return 1
}

ADMIN_USER=""
if [ -n "${BAUDBOT_CONFIG_USER:-}" ]; then
  ADMIN_USER="$BAUDBOT_CONFIG_USER"
elif [ "$(id -u)" -eq 0 ]; then
  ADMIN_USER="${SUDO_USER:-root}"
else
  ADMIN_USER="$(whoami)"
fi

ADMIN_HOME="${BAUDBOT_ADMIN_HOME:-$(resolve_user_home "$ADMIN_USER" || true)}"
if [ -z "$ADMIN_HOME" ]; then
  echo "❌ Could not resolve admin home for user '$ADMIN_USER'" >&2
  exit 1
fi

ADMIN_DIR="$ADMIN_HOME/.baudbot"
ENV_FILE="$ADMIN_DIR/.env"
BACKEND_CONF="$ADMIN_DIR/env-store.conf"

BACKEND="${BAUDBOT_ENV_BACKEND:-file}"
BACKEND_COMMAND="${BAUDBOT_ENV_COMMAND:-}"

if [ -f "$BACKEND_CONF" ]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [ -z "$key" ] && continue
    case "$key" in
      BAUDBOT_ENV_BACKEND) BACKEND="$value" ;;
      BAUDBOT_ENV_COMMAND) BACKEND_COMMAND="$value" ;;
    esac
  done < "$BACKEND_CONF"
fi

render_stream() {
  case "$BACKEND" in
    file)
      if [ ! -f "$ENV_FILE" ]; then
        echo "❌ env file backend selected but not found: $ENV_FILE" >&2
        return 1
      fi
      cat "$ENV_FILE"
      ;;
    command)
      if [ -z "$BACKEND_COMMAND" ]; then
        echo "❌ command backend selected but BAUDBOT_ENV_COMMAND is empty" >&2
        return 1
      fi
      bash -lc "$BACKEND_COMMAND"
      ;;
    *)
      echo "❌ unsupported env backend: $BACKEND" >&2
      return 1
      ;;
  esac
}

get_value() {
  local key="$1"
  render_stream | grep -E "^${key}=" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

case "${1:-}" in
  --get)
    key="${2:-}"
    [ -n "$key" ] || { usage >&2; exit 1; }
    get_value "$key"
    ;;
  --backend)
    echo "$BACKEND"
    ;;
  --check)
    render_stream >/dev/null
    ;;
  --help|-h)
    usage
    ;;
  "")
    render_stream
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
