#!/bin/bash
# Manage deployed subagent packages.

set -euo pipefail

AGENT_USER="${BAUDBOT_AGENT_USER:-baudbot_agent}"
AGENT_HOME="${BAUDBOT_AGENT_HOME:-/home/$AGENT_USER}"
SUBAGENT_DIR="${BAUDBOT_SUBAGENT_DIR:-$AGENT_HOME/.pi/agent/subagents}"
STATE_FILE="${BAUDBOT_SUBAGENT_STATE_FILE:-$AGENT_HOME/.pi/agent/subagents-state.json}"
CONTROL_DIR="${BAUDBOT_SUBAGENT_CONTROL_DIR:-$AGENT_HOME/.pi/session-control}"
ENV_FILE="${BAUDBOT_SUBAGENT_ENV_FILE:-$AGENT_HOME/.config/.env}"

usage() {
  cat <<USAGE
Usage: sudo baudbot subagents <command> [args]

Commands:
  list
  status [id]
  install <id>
  uninstall <id>
  enable <id>
  disable <id>
  autostart-on <id>
  autostart-off <id>
  start <id>
  stop <id>
  reconcile
USAGE
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "❌ subagents commands require root. Run: sudo baudbot subagents ..."
    exit 1
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq is required for subagent management"
    exit 1
  fi
}

require_realpath() {
  if ! command -v realpath >/dev/null 2>&1; then
    echo "❌ realpath is required for subagent management"
    exit 1
  fi
}

ensure_state_file() {
  if [ -f "$STATE_FILE" ]; then
    return
  fi
  install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "$(dirname "$STATE_FILE")"
  printf '{\n  "version": 1,\n  "agents": {}\n}\n' > "$STATE_FILE"
  chown "$AGENT_USER:$AGENT_USER" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

write_state_with_jq() {
  local jq_expr="$1"
  local id="${2:-}"
  ensure_state_file
  local tmp
  tmp=$(mktemp)
  if [ -n "$id" ]; then
    jq --arg id "$id" "$jq_expr" "$STATE_FILE" > "$tmp"
  else
    jq "$jq_expr" "$STATE_FILE" > "$tmp"
  fi
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

manifest_path_for_id() {
  local id="$1"
  local manifest="$SUBAGENT_DIR/$id/subagent.json"
  if [ ! -f "$manifest" ]; then
    echo ""
    return 1
  fi
  echo "$manifest"
}

manifest_field() {
  local manifest="$1"
  local field="$2"
  jq -er "$field" "$manifest" 2>/dev/null || true
}

state_override_bool() {
  local id="$1"
  local key="$2"
  if [ ! -f "$STATE_FILE" ]; then
    echo ""
    return
  fi
  jq -r --arg id "$id" --arg key "$key" '.agents[$id][$key] // empty' "$STATE_FILE" 2>/dev/null || true
}

effective_bool() {
  local id="$1"
  local key="$2"
  local default_value="$3"
  local override
  override="$(state_override_bool "$id" "$key")"
  if [ "$override" = "true" ] || [ "$override" = "false" ]; then
    echo "$override"
    return
  fi
  echo "$default_value"
}

is_true() {
  [ "$1" = "true" ]
}

resolve_home_path() {
  local value="$1"
  if [ "$value" = "~" ]; then
    echo "$AGENT_HOME"
    return
  fi
  if [[ "$value" == ~/* ]]; then
    echo "$AGENT_HOME/${value#~/}"
    return
  fi
  echo "$value"
}

shell_quote() {
  local value="${1:-}"
  printf "'%s'" "${value//\'/\'\"\'\"\'}"
}

is_safe_token() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

resolve_path_in_package() {
  local package_dir="$1"
  local relative_path="$2"
  local package_root resolved

  package_root="$(realpath -m -- "$package_dir")"
  resolved="$(realpath -m -- "$package_dir/$relative_path")"

  case "$resolved" in
    "$package_root"|"$package_root"/*)
      echo "$resolved"
      return 0
      ;;
  esac

  return 1
}

resolve_model() {
  local profile="$1"
  local explicit_model="${2:-}"

  has_key() {
    local key="$1"
    grep -Eq "^${key}=[^[:space:]].*$" "$ENV_FILE" 2>/dev/null
  }

  if [ "$profile" = "explicit" ]; then
    if [ -n "$explicit_model" ]; then
      echo "$explicit_model"
      return 0
    fi
    return 1
  fi

  if [ "$profile" = "top_tier" ]; then
    if has_key "ANTHROPIC_API_KEY"; then echo "anthropic/claude-opus-4-6"; return 0; fi
    if has_key "OPENAI_API_KEY"; then echo "openai/gpt-5.2-codex"; return 0; fi
    if has_key "GEMINI_API_KEY"; then echo "google/gemini-3-pro-preview"; return 0; fi
    if has_key "OPENCODE_ZEN_API_KEY"; then echo "opencode-zen/claude-opus-4-6"; return 0; fi
    return 1
  fi

  if has_key "ANTHROPIC_API_KEY"; then echo "anthropic/claude-haiku-4-5"; return 0; fi
  if has_key "OPENAI_API_KEY"; then echo "openai/gpt-5-mini"; return 0; fi
  if has_key "GEMINI_API_KEY"; then echo "google/gemini-3-flash-preview"; return 0; fi
  if has_key "OPENCODE_ZEN_API_KEY"; then echo "opencode-zen/claude-haiku-4-5"; return 0; fi
  return 1
}

session_running() {
  local session_name="$1"
  sudo -u "$AGENT_USER" tmux has-session -t "$session_name" >/dev/null 2>&1
}

spawn_one() {
  local id="$1"
  local manifest
  manifest="$(manifest_path_for_id "$id")" || true
  if [ -z "$manifest" ]; then
    echo "❌ Unknown subagent id: $id"
    return 1
  fi

  local installed_default enabled_default autostart_default
  installed_default="$(manifest_field "$manifest" '.installed_by_default // true')"
  enabled_default="$(manifest_field "$manifest" '.enabled_by_default // true')"
  autostart_default="$(manifest_field "$manifest" '.autostart // false')"

  local installed enabled
  installed="$(effective_bool "$id" "installed" "$installed_default")"
  enabled="$(effective_bool "$id" "enabled" "$enabled_default")"

  if ! is_true "$installed" || ! is_true "$enabled"; then
    echo "❌ $id is not installed/enabled (installed=$installed enabled=$enabled)"
    return 1
  fi

  local session_name ready_alias skill_path cwd profile explicit_model ready_timeout
  session_name="$(manifest_field "$manifest" '.session_name')"
  ready_alias="$(manifest_field "$manifest" '.ready_alias // .session_name')"
  skill_path="$(manifest_field "$manifest" '.skill_path // "SKILL.md"')"
  cwd="$(manifest_field "$manifest" '.cwd // "~"')"
  profile="$(manifest_field "$manifest" '.model_profile')"
  explicit_model="$(manifest_field "$manifest" '.model // empty')"
  ready_timeout="$(manifest_field "$manifest" '.ready_timeout_sec // 10')"

  local package_dir
  package_dir="$(dirname "$manifest")"

  if ! is_safe_token "$session_name"; then
    echo "❌ invalid session_name for $id"
    return 1
  fi
  if ! is_safe_token "$ready_alias"; then
    echo "❌ invalid ready_alias for $id"
    return 1
  fi

  if [[ "$skill_path" != /* ]] && [[ "$skill_path" != ~* ]]; then
    if ! skill_path="$(resolve_path_in_package "$package_dir" "$skill_path")"; then
      echo "❌ invalid skill_path for $id: $skill_path"
      return 1
    fi
  else
    skill_path="$(realpath -m -- "$(resolve_home_path "$skill_path")")"
  fi

  if [[ "$cwd" != /* ]] && [[ "$cwd" != ~* ]]; then
    if ! cwd="$(resolve_path_in_package "$package_dir" "$cwd")"; then
      echo "❌ invalid cwd for $id: $cwd"
      return 1
    fi
  else
    cwd="$(realpath -m -- "$(resolve_home_path "$cwd")")"
  fi

  if [ ! -d "$cwd" ]; then
    echo "❌ cwd does not exist: $cwd"
    return 1
  fi
  if [ ! -f "$skill_path" ]; then
    echo "❌ skill_path does not exist for $id: $skill_path"
    return 1
  fi

  local model
  if ! model="$(resolve_model "$profile" "$explicit_model")"; then
    echo "❌ could not resolve model for $id"
    return 1
  fi

  if session_running "$session_name"; then
    echo "✓ $id already running"
    return 0
  fi

  local log_path
  log_path="$AGENT_HOME/.pi/agent/logs/spawn-$session_name.log"

  sudo -u "$AGENT_USER" mkdir -p "$AGENT_HOME/.pi/agent/logs"

  local tmux_cmd
  tmux_cmd="cd $(shell_quote "$cwd") && export PATH=\"\$HOME/.varlock/bin:\$HOME/opt/node/bin:\$PATH\" && export PI_SESSION_NAME=$(shell_quote "$session_name") && exec varlock run --path \"\$HOME/.config/\" -- pi --session-control --skill $(shell_quote "$skill_path") --model $(shell_quote "$model") > $(shell_quote "$log_path") 2>&1"
  sudo -u "$AGENT_USER" tmux new-session -d -s "$session_name" "$tmux_cmd"

  local alias_path="$CONTROL_DIR/$ready_alias.alias"
  local wait_ticks=$((ready_timeout * 5))
  local tick=0
  while [ "$tick" -lt "$wait_ticks" ]; do
    if [ -L "$alias_path" ]; then
      local target
      target="$(readlink "$alias_path" 2>/dev/null || true)"
      if [ -n "$target" ] && [ -S "$CONTROL_DIR/$target" ]; then
        echo "✓ started $id ($session_name)"
        return 0
      fi
    fi
    sleep 0.2
    tick=$((tick + 1))
  done

  echo "⚠️ started $id but readiness alias was not observed before timeout"
  return 1
}

stop_one() {
  local id="$1"
  local manifest
  manifest="$(manifest_path_for_id "$id")" || true
  if [ -z "$manifest" ]; then
    echo "❌ Unknown subagent id: $id"
    return 1
  fi
  local session_name
  session_name="$(manifest_field "$manifest" '.session_name')"
  if sudo -u "$AGENT_USER" tmux kill-session -t "$session_name" >/dev/null 2>&1; then
    echo "✓ stopped $id ($session_name)"
  else
    echo "⚠️ $id ($session_name) was not running"
  fi
}

list_packages() {
  printf "%-20s %-8s %-8s %-10s %-14s %s\n" "ID" "INST" "ENBL" "AUTOSTART" "SESSION" "MODEL"
  printf "%-20s %-8s %-8s %-10s %-14s %s\n" "--------------------" "--------" "--------" "----------" "--------------" "-----"

  shopt -s nullglob
  local manifest
  for manifest in "$SUBAGENT_DIR"/*/subagent.json; do
    local id installed_default enabled_default autostart_default installed enabled autostart session profile
    id="$(manifest_field "$manifest" '.id')"
    installed_default="$(manifest_field "$manifest" '.installed_by_default // true')"
    enabled_default="$(manifest_field "$manifest" '.enabled_by_default // true')"
    autostart_default="$(manifest_field "$manifest" '.autostart // false')"
    installed="$(effective_bool "$id" "installed" "$installed_default")"
    enabled="$(effective_bool "$id" "enabled" "$enabled_default")"
    autostart="$(effective_bool "$id" "autostart" "$autostart_default")"
    session="$(manifest_field "$manifest" '.session_name')"
    profile="$(manifest_field "$manifest" '.model_profile')"
    printf "%-20s %-8s %-8s %-10s %-14s %s\n" "$id" "$installed" "$enabled" "$autostart" "$session" "$profile"
  done
  shopt -u nullglob
}

status_packages() {
  local maybe_id="${1:-}"
  if [ -n "$maybe_id" ]; then
    local manifest
    manifest="$(manifest_path_for_id "$maybe_id")" || true
    if [ -z "$manifest" ]; then
      echo "❌ Unknown subagent id: $maybe_id"
      exit 1
    fi
    set -- "$manifest"
  else
    set -- "$SUBAGENT_DIR"/*/subagent.json
  fi

  shopt -s nullglob
  local manifest
  for manifest in "$@"; do
    [ -f "$manifest" ] || continue
    local id session ready_alias alias_path running
    id="$(manifest_field "$manifest" '.id')"
    session="$(manifest_field "$manifest" '.session_name')"
    ready_alias="$(manifest_field "$manifest" '.ready_alias // .session_name')"
    alias_path="$CONTROL_DIR/$ready_alias.alias"

    if session_running "$session"; then running="running"; else running="stopped"; fi
    echo "$id"
    echo "  session: $session ($running)"
    echo "  alias:   $alias_path"
    if [ -L "$alias_path" ]; then
      echo "  socket:  $(readlink "$alias_path" 2>/dev/null || true)"
    else
      echo "  socket:  (missing alias)"
    fi
  done
  shopt -u nullglob
}

set_install_state() {
  local id="$1"
  local installed="$2"
  local enabled="$3"
  local autostart="$4"
  write_state_with_jq '.version = 1 | .agents[$id] = (.agents[$id] // {}) | .agents[$id].installed = ('"$installed"') | .agents[$id].enabled = ('"$enabled"') | .agents[$id].autostart = ('"$autostart"')' "$id"
}

set_enabled_state() {
  local id="$1"
  local enabled="$2"
  write_state_with_jq '.version = 1 | .agents[$id] = (.agents[$id] // {}) | .agents[$id].installed = true | .agents[$id].enabled = ('"$enabled"')' "$id"
}

set_autostart_state() {
  local id="$1"
  local autostart="$2"
  write_state_with_jq '.version = 1 | .agents[$id] = (.agents[$id] // {}) | .agents[$id].installed = true | .agents[$id].enabled = true | .agents[$id].autostart = ('"$autostart"')' "$id"
}

reconcile_subagents() {
  shopt -s nullglob
  local manifest
  local failures=0
  for manifest in "$SUBAGENT_DIR"/*/subagent.json; do
    local id installed_default enabled_default autostart_default installed enabled autostart
    id="$(manifest_field "$manifest" '.id')"
    installed_default="$(manifest_field "$manifest" '.installed_by_default // true')"
    enabled_default="$(manifest_field "$manifest" '.enabled_by_default // true')"
    autostart_default="$(manifest_field "$manifest" '.autostart // false')"

    installed="$(effective_bool "$id" "installed" "$installed_default")"
    enabled="$(effective_bool "$id" "enabled" "$enabled_default")"
    autostart="$(effective_bool "$id" "autostart" "$autostart_default")"

    if is_true "$installed" && is_true "$enabled" && is_true "$autostart"; then
      if ! spawn_one "$id"; then
        failures=$((failures + 1))
      fi
    fi
  done
  shopt -u nullglob

  if [ "$failures" -gt 0 ]; then
    return 1
  fi
}

main() {
  require_root
  require_jq
  require_realpath

  local command="${1:-}"
  shift || true

  case "$command" in
    list)
      list_packages
      ;;
    status)
      status_packages "${1:-}"
      ;;
    install)
      [ -n "${1:-}" ] || { echo "❌ install requires id"; exit 1; }
      set_install_state "$1" true true false
      echo "✓ installed $1"
      ;;
    uninstall)
      [ -n "${1:-}" ] || { echo "❌ uninstall requires id"; exit 1; }
      set_install_state "$1" false false false
      stop_one "$1" || true
      echo "✓ uninstalled $1"
      ;;
    enable)
      [ -n "${1:-}" ] || { echo "❌ enable requires id"; exit 1; }
      set_enabled_state "$1" true
      echo "✓ enabled $1"
      ;;
    disable)
      [ -n "${1:-}" ] || { echo "❌ disable requires id"; exit 1; }
      set_enabled_state "$1" false
      stop_one "$1" || true
      echo "✓ disabled $1"
      ;;
    autostart-on)
      [ -n "${1:-}" ] || { echo "❌ autostart-on requires id"; exit 1; }
      set_autostart_state "$1" true
      echo "✓ autostart enabled for $1"
      ;;
    autostart-off)
      [ -n "${1:-}" ] || { echo "❌ autostart-off requires id"; exit 1; }
      write_state_with_jq '.version = 1 | .agents[$id] = (.agents[$id] // {}) | .agents[$id].autostart = false' "$1"
      echo "✓ autostart disabled for $1"
      ;;
    start)
      [ -n "${1:-}" ] || { echo "❌ start requires id"; exit 1; }
      spawn_one "$1"
      ;;
    stop)
      [ -n "${1:-}" ] || { echo "❌ stop requires id"; exit 1; }
      stop_one "$1"
      ;;
    reconcile)
      reconcile_subagents
      ;;
    --help|-h|"")
      usage
      ;;
    *)
      echo "❌ unknown command: $command"
      usage
      exit 1
      ;;
  esac
}

main "$@"
