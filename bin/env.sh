#!/bin/bash
# Baudbot env helper
#
# Usage:
#   baudbot env set KEY [VALUE] [--restart]
#   baudbot env unset KEY [--restart]
#   baudbot env get KEY [--admin|--runtime]
#   baudbot env sync [--restart]
#   baudbot env backend show|set-file|set-command "<command>"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
bb_enable_strict_mode

RENDER_SCRIPT="$SCRIPT_DIR/render-env.sh"

usage() {
  cat <<'EOF'
Usage:
  baudbot env set KEY [VALUE] [--restart]
  baudbot env unset KEY [--restart]
  baudbot env get KEY [--admin|--runtime]
  baudbot env sync [--restart]
  baudbot env backend show
  baudbot env backend set-file
  baudbot env backend set-command "<command>"

Notes:
  - set/unset work on file backend only
  - backend set-command lets you source env from an external command
  - sync writes rendered source env to agent runtime (~/.config/.env)
EOF
}

validate_key_name() {
  local key="$1"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

warn_prefix_if_needed() {
  local key="$1" value="$2"
  case "$key" in
    ANTHROPIC_API_KEY)
      [[ "$value" == sk-ant-* ]] || echo "⚠️  ANTHROPIC_API_KEY should start with sk-ant-" >&2
      ;;
    OPENAI_API_KEY)
      [[ "$value" == sk-* ]] || echo "⚠️  OPENAI_API_KEY should start with sk-" >&2
      ;;
  esac
}

upsert_env_value() {
  local file="$1" key="$2" value="$3" tmp=""
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    grep -v -E "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

unset_env_value() {
  local file="$1" key="$2" tmp=""
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    grep -v -E "^${key}=" "$file" > "$tmp" || true
  fi
  mv "$tmp" "$file"
}

set_secure_perms() {
  local file="$1" owner="$2"
  chmod 600 "$file"
  if [ -n "$owner" ]; then
    chown "$owner:$owner" "$file"
  fi
}

ADMIN_USER=""
if [ "$(id -u)" -eq 0 ]; then
  ADMIN_USER="${SUDO_USER:-root}"
else
  ADMIN_USER="$(whoami)"
fi

ADMIN_HOME="${BAUDBOT_ADMIN_HOME:-$(bb_resolve_user_home "$ADMIN_USER" || true)}"
if [ -z "$ADMIN_HOME" ]; then
  echo "❌ Could not resolve home directory for admin user '$ADMIN_USER'"
  exit 1
fi

ADMIN_DIR="$ADMIN_HOME/.baudbot"
ADMIN_ENV_FILE="$ADMIN_DIR/.env"
BACKEND_CONF="$ADMIN_DIR/env-store.conf"

AGENT_USER="${BAUDBOT_AGENT_USER:-baudbot_agent}"
AGENT_HOME="${BAUDBOT_AGENT_HOME:-$(bb_resolve_user_home "$AGENT_USER" || true)}"
RUNTIME_ENV_FILE=""
if [ -n "$AGENT_HOME" ]; then
  RUNTIME_ENV_FILE="$AGENT_HOME/.config/.env"
fi

get_backend() {
  if [ -x "$RENDER_SCRIPT" ]; then
    BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_CONFIG_USER="$ADMIN_USER" "$RENDER_SCRIPT" --backend
    return 0
  fi
  echo "file"
}

set_backend_file() {
  mkdir -p "$ADMIN_DIR"
  cat > "$BACKEND_CONF" <<EOF
BAUDBOT_ENV_BACKEND=file
EOF
  if [ "$(id -u)" -eq 0 ]; then
    set_secure_perms "$BACKEND_CONF" "$ADMIN_USER"
  else
    chmod 600 "$BACKEND_CONF"
  fi
  echo "✓ env backend set to file ($ADMIN_ENV_FILE)"
}

set_backend_command() {
  local cmd="$1"
  [ -n "$cmd" ] || { echo "❌ Missing command"; exit 1; }
  mkdir -p "$ADMIN_DIR"
  cat > "$BACKEND_CONF" <<EOF
BAUDBOT_ENV_BACKEND=command
BAUDBOT_ENV_COMMAND=$cmd
EOF
  if [ "$(id -u)" -eq 0 ]; then
    set_secure_perms "$BACKEND_CONF" "$ADMIN_USER"
  else
    chmod 600 "$BACKEND_CONF"
  fi
  echo "✓ env backend set to command"
}

render_get_admin() {
  local key="$1"
  BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_CONFIG_USER="$ADMIN_USER" "$RENDER_SCRIPT" --get "$key"
}

sync_runtime() {
  local restart="$1"
  bb_require_root "baudbot env sync"

  [ -x "$RENDER_SCRIPT" ] || { echo "❌ Missing renderer: $RENDER_SCRIPT"; exit 1; }
  [ -n "$RUNTIME_ENV_FILE" ] || { echo "❌ Could not resolve runtime env path"; exit 1; }

  BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_CONFIG_USER="$ADMIN_USER" "$RENDER_SCRIPT" --check

  mkdir -p "$(dirname "$RUNTIME_ENV_FILE")"
  BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_CONFIG_USER="$ADMIN_USER" "$RENDER_SCRIPT" > "$RUNTIME_ENV_FILE"
  set_secure_perms "$RUNTIME_ENV_FILE" "$AGENT_USER"
  echo "✓ synced runtime env to $RUNTIME_ENV_FILE"

  if [ "$restart" = "true" ]; then
    bb_restart_systemd_service_or_die baudbot
    echo "✓ restarted baudbot service"
  else
    echo "Next step: sudo baudbot restart"
  fi
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 1; }
shift || true

case "$cmd" in
  set)
    KEY="${1:-}"
    VALUE="${2:-}"
    RESTART="false"

    [ -n "$KEY" ] || { echo "❌ Missing KEY"; usage; exit 1; }
    validate_key_name "$KEY" || { echo "❌ Invalid KEY format: $KEY"; exit 1; }

    BACKEND="$(get_backend)"
    if [ "$BACKEND" != "file" ]; then
      echo "❌ set is only supported on file backend (current: $BACKEND)"
      echo "   Use: baudbot env backend set-file"
      exit 1
    fi

    if [ "$VALUE" = "--restart" ]; then
      VALUE=""
      RESTART="true"
    fi
    if [ "${3:-}" = "--restart" ]; then
      RESTART="true"
    fi

    if [ -z "$VALUE" ]; then
      if [ -t 0 ]; then
        read -r -s -p "Enter value for $KEY: " VALUE
        echo ""
      else
        echo "❌ Missing VALUE"
        usage
        exit 1
      fi
    fi

    [[ "$VALUE" == *$'\n'* ]] && { echo "❌ VALUE cannot contain newlines"; exit 1; }

    warn_prefix_if_needed "$KEY" "$VALUE"

    upsert_env_value "$ADMIN_ENV_FILE" "$KEY" "$VALUE"
    if [ "$(id -u)" -eq 0 ]; then
      set_secure_perms "$ADMIN_ENV_FILE" "$ADMIN_USER"
    else
      chmod 600 "$ADMIN_ENV_FILE"
    fi
    echo "✓ updated $ADMIN_ENV_FILE"

    if [ "$(id -u)" -eq 0 ] && [ -n "$RUNTIME_ENV_FILE" ] && [ -f "$RUNTIME_ENV_FILE" ]; then
      upsert_env_value "$RUNTIME_ENV_FILE" "$KEY" "$VALUE"
      set_secure_perms "$RUNTIME_ENV_FILE" "$AGENT_USER"
      echo "✓ mirrored to $RUNTIME_ENV_FILE"
    fi

    if [ "$RESTART" = "true" ]; then
      bb_require_root "baudbot env set --restart"
      bb_restart_systemd_service_or_die baudbot
      echo "✓ restarted baudbot service"
    else
      echo "Next step: sudo baudbot restart"
    fi
    ;;

  unset)
    KEY="${1:-}"
    RESTART="${2:-}"

    [ -n "$KEY" ] || { echo "❌ Missing KEY"; usage; exit 1; }
    validate_key_name "$KEY" || { echo "❌ Invalid KEY format: $KEY"; exit 1; }

    BACKEND="$(get_backend)"
    if [ "$BACKEND" != "file" ]; then
      echo "❌ unset is only supported on file backend (current: $BACKEND)"
      echo "   Use: baudbot env backend set-file"
      exit 1
    fi

    unset_env_value "$ADMIN_ENV_FILE" "$KEY"
    if [ "$(id -u)" -eq 0 ]; then
      set_secure_perms "$ADMIN_ENV_FILE" "$ADMIN_USER"
    else
      chmod 600 "$ADMIN_ENV_FILE"
    fi
    echo "✓ removed $KEY from $ADMIN_ENV_FILE"

    if [ "$(id -u)" -eq 0 ] && [ -n "$RUNTIME_ENV_FILE" ] && [ -f "$RUNTIME_ENV_FILE" ]; then
      unset_env_value "$RUNTIME_ENV_FILE" "$KEY"
      set_secure_perms "$RUNTIME_ENV_FILE" "$AGENT_USER"
      echo "✓ mirrored removal to $RUNTIME_ENV_FILE"
    fi

    if [ "$RESTART" = "--restart" ]; then
      bb_require_root "baudbot env unset --restart"
      bb_restart_systemd_service_or_die baudbot
      echo "✓ restarted baudbot service"
    else
      echo "Next step: sudo baudbot restart"
    fi
    ;;

  get)
    KEY="${1:-}"
    TARGET="${2:---admin}"

    [ -n "$KEY" ] || { echo "❌ Missing KEY"; usage; exit 1; }
    validate_key_name "$KEY" || { echo "❌ Invalid KEY format: $KEY"; exit 1; }

    case "$TARGET" in
      --admin)
        render_get_admin "$KEY"
        ;;
      --runtime)
        [ -n "$RUNTIME_ENV_FILE" ] || exit 0
        bb_read_env_value "$RUNTIME_ENV_FILE" "$KEY"
        ;;
      *)
        echo "❌ Unknown target: $TARGET"
        usage
        exit 1
        ;;
    esac
    ;;

  sync)
    RESTART="false"
    if [ "${1:-}" = "--restart" ]; then
      RESTART="true"
    fi
    sync_runtime "$RESTART"
    ;;

  backend)
    sub="${1:-}"
    case "$sub" in
      show)
        backend="$(get_backend)"
        echo "$backend"
        if [ "$backend" = "file" ]; then
          echo "source: $ADMIN_ENV_FILE"
        else
          echo "config: $BACKEND_CONF"
        fi
        ;;
      set-file)
        set_backend_file
        ;;
      set-command)
        shift
        set_backend_command "${1:-}"
        ;;
      *)
        echo "❌ Unknown backend subcommand: $sub"
        usage
        exit 1
        ;;
    esac
    ;;

  --help|-h|help)
    usage
    ;;

  *)
    echo "❌ Unknown env subcommand: $cmd"
    usage
    exit 1
    ;;
esac
