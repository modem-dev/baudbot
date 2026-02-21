#!/bin/bash
# Runtime/status/session helpers for bin/baudbot.

# Detect systemd
has_systemd() {
  command -v systemctl &>/dev/null && [ -d /run/systemd/system ]
}

print_deployed_version() {
  local agent_user="${BAUDBOT_AGENT_USER:-baudbot_agent}"
  local version_file="/home/$agent_user/.pi/agent/baudbot-version.json"
  local short=""
  local sha=""
  local branch=""
  local deployed_at=""
  local line=""

  if [ -r "$version_file" ]; then
    short="$(json_get_string_or_empty "$version_file" "short")"
    sha="$(json_get_string_or_empty "$version_file" "sha")"
    branch="$(json_get_string_or_empty "$version_file" "branch")"
    deployed_at="$(json_get_string_or_empty "$version_file" "deployed_at")"
  elif [ "$(id -u)" -eq 0 ] && id "$agent_user" >/dev/null 2>&1; then
    local version_json=""
    version_json="$(sudo -u "$agent_user" sh -c "cat '$version_file' 2>/dev/null" || true)"
    if [ -n "$version_json" ]; then
      short="$(printf '%s' "$version_json" | json_get_string_stdin_or_empty "short" 2>/dev/null || true)"
      sha="$(printf '%s' "$version_json" | json_get_string_stdin_or_empty "sha" 2>/dev/null || true)"
      branch="$(printf '%s' "$version_json" | json_get_string_stdin_or_empty "branch" 2>/dev/null || true)"
      deployed_at="$(printf '%s' "$version_json" | json_get_string_stdin_or_empty "deployed_at" 2>/dev/null || true)"
    fi
  fi

  if [ -z "$short" ] && [ -z "$sha" ] && [ -z "$branch" ] && [ -z "$deployed_at" ]; then
    local release_target=""
    local release_sha=""

    release_target="$(readlink -f /opt/baudbot/current 2>/dev/null || true)"
    if printf '%s\n' "$release_target" | grep -Eq '/releases/[0-9a-f]{7,40}$'; then
      release_sha="${release_target##*/}"
      echo -e "${BOLD}deployed version:${RESET} ${release_sha:0:7} sha: $release_sha (from /opt/baudbot/current)"
    else
      echo -e "${BOLD}deployed version:${RESET} unavailable"
    fi
    return 0
  fi

  if [ -z "$short" ] && [ -n "$sha" ]; then
    short="${sha:0:7}"
  fi

  line="${short:-unknown}"
  [ -n "$branch" ] && line="$line (branch: $branch)"
  [ -n "$deployed_at" ] && line="$line deployed: $deployed_at"
  [ -n "$sha" ] && line="$line sha: $sha"

  echo -e "${BOLD}deployed version:${RESET} $line"
}

broker_mode_configured() {
  local env_file="/home/${1:-baudbot_agent}/.config/.env"
  [ -r "$env_file" ] || return 1
  grep -Eq '^SLACK_BROKER_URL=[^[:space:]].*$' "$env_file" || return 1
  grep -Eq '^SLACK_BROKER_WORKSPACE_ID=[^[:space:]].*$' "$env_file" || return 1
}

print_broker_connection_status() {
  local agent_user="${BAUDBOT_AGENT_USER:-baudbot_agent}"
  local health_file="/home/$agent_user/.pi/agent/broker-health.json"
  local health_summary=""
  local connection_state=""
  local components_line=""
  local bridge_running=0

  if ! broker_mode_configured "$agent_user"; then
    echo -e "${BOLD}broker connection:${RESET} not configured"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    if pgrep -u "$agent_user" -f "node broker-bridge.mjs" >/dev/null 2>&1; then
      bridge_running=1
    fi
  elif [ "$(id -un)" = "$agent_user" ]; then
    if pgrep -u "$agent_user" -f "node broker-bridge.mjs" >/dev/null 2>&1; then
      bridge_running=1
    fi
  else
    echo -e "${BOLD}broker connection:${RESET} configured (run with sudo for runtime status)"
    return 0
  fi

  if [ "$bridge_running" -ne 1 ]; then
    echo -e "${BOLD}broker connection:${RESET} disconnected (broker bridge process not running)"
    return 0
  fi

  if [ ! -r "$health_file" ]; then
    echo -e "${BOLD}broker connection:${RESET} starting"
    echo -e "${BOLD}broker health:${RESET} unavailable (waiting for bridge health file)"
    return 0
  fi

  health_summary="$(python3 - "$health_file" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    h = json.load(f)

def parse_iso(s):
    if not s:
        return None
    try:
        if s.endswith('Z'):
            s = s[:-1] + '+00:00'
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None

def age_seconds(ts):
    dt = parse_iso(ts)
    if not dt:
        return None
    return (datetime.now(timezone.utc) - dt).total_seconds()

def status(ok_ts, err_ts):
    ok_dt = parse_iso(ok_ts)
    err_dt = parse_iso(err_ts)
    if err_dt and (not ok_dt or err_dt >= ok_dt):
        return 'error'
    if ok_dt:
        return 'ok'
    return 'unknown'

poll = h.get('poll', {})
inbound = h.get('inbound', {})
ack = h.get('ack', {})
outbound = h.get('outbound', {})

poll_age = age_seconds(poll.get('last_ok_at'))
poll_failures = int(poll.get('consecutive_failures') or 0)
poll_state = status(poll.get('last_ok_at'), poll.get('last_error_at'))

if poll_state == 'error' and poll_failures > 0:
    connection = 'reconnecting'
elif poll_age is not None and poll_age <= 120:
    connection = 'connected'
elif poll_age is not None:
    connection = 'stale'
else:
    connection = 'starting'

inbound_state = status(inbound.get('last_process_ok_at'), inbound.get('last_process_error_at'))
ack_state = status(ack.get('last_ok_at'), ack.get('last_error_at'))
outbound_state = status(outbound.get('last_ok_at'), outbound.get('last_error_at'))

print(connection)
print(f'poll={poll_state} inbound={inbound_state} ack={ack_state} outbound={outbound_state}')
PY
  )"

  connection_state="$(printf '%s\n' "$health_summary" | sed -n '1p')"
  components_line="$(printf '%s\n' "$health_summary" | sed -n '2p')"

  case "$connection_state" in
    connected)
      echo -e "${BOLD}broker connection:${RESET} connected"
      ;;
    reconnecting)
      echo -e "${BOLD}broker connection:${RESET} reconnecting"
      ;;
    stale)
      echo -e "${BOLD}broker connection:${RESET} stale (no recent successful poll)"
      ;;
    starting)
      echo -e "${BOLD}broker connection:${RESET} starting"
      ;;
    *)
      echo -e "${BOLD}broker connection:${RESET} unknown"
      ;;
  esac

  [ -n "$components_line" ] && echo -e "${BOLD}broker health:${RESET} $components_line"
}

pi_control_dir() {
  local agent_user="${1:-baudbot_agent}"
  echo "/home/$agent_user/.pi/session-control"
}

pi_alias_to_uuid() {
  local alias_path="$1"
  local target

  target=$(readlink "$alias_path" 2>/dev/null || true)
  target=$(basename "$target")
  target="${target%.sock}"

  if [ -n "$target" ]; then
    echo "$target"
    return 0
  fi

  return 1
}

resolve_pi_session_id() {
  local agent_user="$1"
  local query="${2:-}"
  local dir
  local first_sock
  local matches
  local count

  dir=$(pi_control_dir "$agent_user")
  [ -d "$dir" ] || return 1

  if [ -z "$query" ]; then
    if [ -L "$dir/control-agent.alias" ]; then
      pi_alias_to_uuid "$dir/control-agent.alias"
      return 0
    fi

    first_sock=$(find "$dir" -maxdepth 1 -type s -name '*.sock' -printf '%f\n' 2>/dev/null | sort | head -1)
    if [ -n "$first_sock" ]; then
      echo "${first_sock%.sock}"
      return 0
    fi

    return 1
  fi

  if [ -S "$dir/$query.sock" ]; then
    echo "$query"
    return 0
  fi

  if [ -L "$dir/$query.alias" ]; then
    pi_alias_to_uuid "$dir/$query.alias"
    return 0
  fi

  if [ -L "$dir/$query.sock" ]; then
    pi_alias_to_uuid "$dir/$query.sock"
    return 0
  fi

  matches=$(find "$dir" -maxdepth 1 -type s -name "$query*.sock" -printf '%f\n' 2>/dev/null | sort)
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 1 ]; then
    echo "${matches%.sock}"
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "❌ Multiple pi sessions match '$query'. Use full UUID or alias from: baudbot sessions" >&2
    return 2
  fi

  return 1
}

pause_before_attach() {
  if [ "${BAUDBOT_ATTACH_NO_PAUSE:-0}" = "1" ]; then
    return 0
  fi

  if [ -t 0 ] && [ -t 1 ]; then
    echo -e "${DIM}Press Enter to attach (Ctrl+C to cancel)...${RESET}"
    # shellcheck disable=SC2162
    read _
  else
    sleep 2
  fi
}

cmd_status() {
  if has_systemd && systemctl is-enabled baudbot &>/dev/null; then
    local status_rc=0
    systemctl status baudbot "$@" || status_rc=$?
    echo ""
    print_deployed_version
    print_broker_connection_status
    exit "$status_rc"
  fi

  if pgrep -u baudbot_agent -f "pi --session-control" &>/dev/null; then
    echo "baudbot is running (no systemd unit)"
    pgrep -u baudbot_agent -af "pi --session-control"
  else
    echo "baudbot is not running"
  fi
  echo ""
  print_deployed_version
  print_broker_connection_status
}

cmd_logs() {
  if has_systemd && systemctl is-enabled baudbot &>/dev/null; then
    exec journalctl -u baudbot -f "$@"
  fi

  echo "No systemd unit. Check tmux sessions:"
  echo "  sudo -u baudbot_agent tmux ls"
}

cmd_sessions() {
  require_root "sessions"
  local AGENT_USER="baudbot_agent"
  local PI_CONTROL_DIR
  local found alias alias_name alias_uuid sock sess_id name status
  declare -A ALIASES

  echo -e "${BOLD}tmux sessions:${RESET}"
  if sudo -u "$AGENT_USER" tmux ls 2>/dev/null; then
    :
  else
    echo "  (none)"
  fi

  echo ""
  echo -e "${BOLD}pi sessions:${RESET}"
  PI_CONTROL_DIR="$(pi_control_dir "$AGENT_USER")"
  if [ ! -d "$PI_CONTROL_DIR" ]; then
    echo "  (no session-control directory)"
    return 0
  fi

  found=0

  for alias in "$PI_CONTROL_DIR"/*.alias; do
    [ -L "$alias" ] || continue
    alias_name=$(basename "$alias" .alias)
    alias_uuid=$(pi_alias_to_uuid "$alias" || true)
    [ -n "$alias_uuid" ] && ALIASES[$alias_uuid]="$alias_name"
  done

  for alias in "$PI_CONTROL_DIR"/*.sock; do
    [ -L "$alias" ] || continue
    alias_name=$(basename "$alias" .sock)
    alias_uuid=$(pi_alias_to_uuid "$alias" || true)
    [ -n "$alias_uuid" ] && ALIASES[$alias_uuid]="$alias_name"
  done

  for sock in "$PI_CONTROL_DIR"/*.sock; do
    [ -S "$sock" ] || continue
    [ -L "$sock" ] && continue

    sess_id=$(basename "$sock" .sock)
    name="${ALIASES[$sess_id]:-}"

    status="stopped (stale)"
    if sudo -u "$AGENT_USER" bash -c "python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(0.3); s.connect('$sock'); s.close()\" 2>/dev/null" 2>/dev/null; then
      status="running"
    fi

    if [ -n "$name" ]; then
      echo "  $name ($sess_id) [$status]"
    else
      echo "  $sess_id [$status]"
    fi
    found=$((found + 1))
  done

  if [ "$found" -eq 0 ]; then
    echo "  (none)"
  fi
}

cmd_attach() {
  require_root "attach"

  local AGENT_USER="baudbot_agent"
  local AGENT_HOME="/home/$AGENT_USER"
  local ATTACH_MODE="auto"
  local TARGET=""
  local tmux_target pi_target

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pi)
        ATTACH_MODE="pi"
        shift
        ;;
      --tmux)
        ATTACH_MODE="tmux"
        shift
        ;;
      -h|--help)
        echo "Usage: sudo baudbot attach [--pi|--tmux] [session-name|session-id]"
        echo ""
        echo "Examples:"
        echo "  sudo baudbot attach                  # defaults to control-agent"
        echo "  sudo baudbot attach --pi control-agent"
        echo "  sudo baudbot attach --pi <uuid>"
        echo "  sudo baudbot attach --tmux slack-bridge"
        exit 0
        ;;
      *)
        if [ -n "$TARGET" ]; then
          echo "❌ Too many arguments for attach"
          exit 1
        fi
        TARGET="$1"
        shift
        ;;
    esac
  done

  if [ -z "$TARGET" ]; then
    TARGET="control-agent"
  fi

  attach_tmux_session() {
    local tmux_target="$1"
    echo -e "${BOLD}${CYAN}Attaching to tmux session:${RESET} $tmux_target"
    echo -e "${GREEN}Safe detach:${RESET} Ctrl+b, d ${DIM}(keeps agent running)${RESET}"
    echo ""
    pause_before_attach
    exec sudo -u "$AGENT_USER" tmux attach-session -t "$tmux_target"
  }

  attach_pi_session() {
    local pi_target="$1"
    echo -e "${BOLD}${CYAN}Attaching to pi session:${RESET} $pi_target"
    echo -e "${BOLD}${YELLOW}Safe detach (does NOT stop the agent):${RESET}"
    echo -e "  ${YELLOW}1)${RESET} Press Ctrl+C once to clear input/cancel local prompt"
    echo -e "  ${YELLOW}2)${RESET} Press Ctrl+C again to exit this client"
    echo -e "  ${GREEN}Agent keeps running under systemd in the background.${RESET}"
    echo ""
    pause_before_attach
    exec sudo -u "$AGENT_USER" bash -lc "export PATH='$AGENT_HOME/.varlock/bin:$AGENT_HOME/opt/node-v22.14.0-linux-x64/bin':\$PATH; cd ~; varlock run --path ~/.config/ -- pi --session '$pi_target'"
  }

  choose_tmux_target() {
    local requested="${1:-}"
    local first

    if [ -n "$requested" ]; then
      if sudo -u "$AGENT_USER" tmux has-session -t "$requested" 2>/dev/null; then
        echo "$requested"
        return 0
      fi
      return 1
    fi

    first=$(sudo -u "$AGENT_USER" tmux ls -F '#{session_name}' 2>/dev/null | head -1)
    [ -n "$first" ] || return 1
    echo "$first"
    return 0
  }

  choose_pi_target() {
    local requested="${1:-}"
    local resolved

    if ! resolved=$(resolve_pi_session_id "$AGENT_USER" "$requested"); then
      return 1
    fi

    [ -n "$resolved" ] || return 1
    echo "$resolved"
    return 0
  }

  if [ "$ATTACH_MODE" = "tmux" ]; then
    if tmux_target=$(choose_tmux_target "$TARGET"); then
      attach_tmux_session "$tmux_target"
    fi
    echo "❌ tmux session not found. See: sudo baudbot sessions"
    exit 1
  fi

  if [ "$ATTACH_MODE" = "pi" ]; then
    if pi_target=$(choose_pi_target "$TARGET"); then
      attach_pi_session "$pi_target"
    fi
    echo "❌ pi session not found. See: sudo baudbot sessions"
    exit 1
  fi

  if pi_target=$(choose_pi_target "$TARGET"); then
    attach_pi_session "$pi_target"
  fi

  if tmux_target=$(choose_tmux_target "$TARGET"); then
    attach_tmux_session "$tmux_target"
  fi

  echo "❌ No matching tmux/pi session found. See: sudo baudbot sessions"
  exit 1
}
