#!/bin/bash
# Shared helpers for remote install/repair orchestration.

_REMOTE_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$_REMOTE_COMMON_LIB_DIR/shell-common.sh"

REMOTE_ROOT_DEFAULT="${HOME}/.baudbot/remote"
REMOTE_ROOT="${BAUDBOT_REMOTE_DIR:-$REMOTE_ROOT_DEFAULT}"
REMOTE_TARGETS_DIR="${REMOTE_ROOT}/targets"
REMOTE_KEYS_DIR="${REMOTE_ROOT}/keys"
REMOTE_KNOWN_HOSTS="${REMOTE_ROOT}/known_hosts"

remote_refresh_paths() {
  REMOTE_ROOT="${BAUDBOT_REMOTE_DIR:-$REMOTE_ROOT_DEFAULT}"
  REMOTE_TARGETS_DIR="${REMOTE_ROOT}/targets"
  REMOTE_KEYS_DIR="${REMOTE_ROOT}/keys"
  REMOTE_KNOWN_HOSTS="${REMOTE_ROOT}/known_hosts"
}

remote_log() {
  echo "[remote] $*"
}

remote_warn() {
  echo "[remote] WARN: $*" >&2
}

remote_error() {
  echo "[remote] ERROR: $*" >&2
}

remote_die() {
  remote_error "$*"
  exit 1
}

remote_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

remote_targets_dir() {
  remote_refresh_paths
  printf '%s\n' "$REMOTE_TARGETS_DIR"
}

remote_keys_dir() {
  remote_refresh_paths
  printf '%s\n' "$REMOTE_KEYS_DIR"
}

remote_known_hosts_path() {
  remote_refresh_paths
  printf '%s\n' "$REMOTE_KNOWN_HOSTS"
}

remote_state_path() {
  local target="$1"
  printf '%s/%s.json\n' "$(remote_targets_dir)" "$target"
}

remote_state_exists() {
  local target="$1"
  [ -f "$(remote_state_path "$target")" ]
}

remote_validate_target_name() {
  local target="$1"
  if [ -z "$target" ]; then
    remote_error "target name cannot be empty"
    return 1
  fi
  if [ "${#target}" -gt 63 ]; then
    remote_error "target name must be 63 characters or fewer"
    return 1
  fi
  if ! printf '%s' "$target" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
    remote_error "target name must use lowercase letters, numbers, and hyphens"
    return 1
  fi
  return 0
}

remote_init_storage() {
  remote_refresh_paths
  mkdir -p "$REMOTE_ROOT" "$REMOTE_TARGETS_DIR" "$REMOTE_KEYS_DIR"
  chmod 700 "$REMOTE_ROOT" "$REMOTE_TARGETS_DIR" "$REMOTE_KEYS_DIR"
  if [ ! -f "$REMOTE_KNOWN_HOSTS" ]; then
    : > "$REMOTE_KNOWN_HOSTS"
  fi
  chmod 600 "$REMOTE_KNOWN_HOSTS"
}

remote_require_tools() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      remote_error "required command not found: $cmd"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    return 1
  fi
  return 0
}

remote_require_dependencies_install() {
  local mode="$1"
  local tools=(jq ssh scp ssh-keygen)
  if [ "$mode" = "hetzner" ]; then
    tools+=(curl)
  fi
  remote_require_tools "${tools[@]}"
}

remote_require_dependencies_repair() {
  remote_require_tools jq ssh scp
}

remote_expand_path() {
  local input="$1"
  if [ -z "$input" ]; then
    printf '\n'
    return 0
  fi
  case "$input" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${input#~/}"
      ;;
    *)
      printf '%s\n' "$input"
      ;;
  esac
}

_remote_state_write_jq() {
  local target="$1"
  local filter="$2"
  shift 2

  local state_file tmp_file
  state_file="$(remote_state_path "$target")"
  if [ ! -f "$state_file" ]; then
    remote_die "state not found for target '$target'"
  fi

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/baudbot-remote-state.XXXXXX")"
  if jq "$@" "$filter" "$state_file" > "$tmp_file"; then
    mv "$tmp_file" "$state_file"
  else
    rm -f "$tmp_file"
    remote_die "failed to update state for target '$target'"
  fi
}

remote_state_init() {
  local target="$1"
  local mode="$2"
  local host="$3"
  local ssh_user="$4"
  local ssh_key_path="$5"
  local provider_name="$6"
  local location="$7"
  local server_type="$8"
  local image="$9"

  remote_validate_target_name "$target" || return 1
  remote_init_storage

  local state_file now tmp_file
  state_file="$(remote_state_path "$target")"
  now="$(remote_now_iso)"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/baudbot-remote-state-init.XXXXXX")"

  if ! jq -n \
    --arg name "$target" \
    --arg mode "$mode" \
    --arg host "$host" \
    --arg ssh_user "$ssh_user" \
    --arg ssh_key_path "$ssh_key_path" \
    --arg provider_name "$provider_name" \
    --arg location "$location" \
    --arg server_type "$server_type" \
    --arg image "$image" \
    --arg now "$now" \
    '{
      name: $name,
      mode: $mode,
      host: $host,
      ssh_user: $ssh_user,
      ssh_key_path: $ssh_key_path,
      provider: {
        name: $provider_name,
        server_id: "",
        ssh_key_id: "",
        location: $location,
        server_type: $server_type,
        image: $image
      },
      tailscale: {
        enabled: false,
        ip: ""
      },
      status: "initialized",
      checkpoints: [],
      last_error: "",
      created_at: $now,
      updated_at: $now
    }' > "$tmp_file"; then
    rm -f "$tmp_file"
    remote_die "failed to initialize state for target '$target'"
  fi

  mv "$tmp_file" "$state_file"
  chmod 600 "$state_file"
}

remote_state_get_field() {
  local target="$1"
  local jq_expr="$2"
  local state_file
  state_file="$(remote_state_path "$target")"
  [ -f "$state_file" ] || return 1
  jq -er "$jq_expr // empty" "$state_file" 2>/dev/null || true
}

remote_state_set_status() {
  local target="$1"
  local status="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.status = $status | .updated_at = $now' --arg status "$status" --arg now "$now"
}

remote_state_set_mode() {
  local target="$1"
  local mode="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.mode = $mode | .updated_at = $now' --arg mode "$mode" --arg now "$now"
}

remote_state_set_host() {
  local target="$1"
  local host="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.host = $host | .updated_at = $now' --arg host "$host" --arg now "$now"
}

remote_state_set_ssh_user() {
  local target="$1"
  local ssh_user="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.ssh_user = $ssh_user | .updated_at = $now' --arg ssh_user "$ssh_user" --arg now "$now"
}

remote_state_set_ssh_key_path() {
  local target="$1"
  local ssh_key_path="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.ssh_key_path = $ssh_key_path | .updated_at = $now' --arg ssh_key_path "$ssh_key_path" --arg now "$now"
}

remote_state_set_provider_field() {
  local target="$1"
  local field="$2"
  local value="$3"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" ".provider.${field} = \$value | .updated_at = \$now" --arg value "$value" --arg now "$now"
}

remote_state_set_tailscale_enabled() {
  local target="$1"
  local enabled="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.tailscale.enabled = ($enabled == "true") | .updated_at = $now' --arg enabled "$enabled" --arg now "$now"
}

remote_state_set_tailscale_ip() {
  local target="$1"
  local ip="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.tailscale.ip = $ip | .updated_at = $now' --arg ip "$ip" --arg now "$now"
}

remote_state_set_last_error() {
  local target="$1"
  local message="$2"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.last_error = $message | .updated_at = $now' --arg message "$message" --arg now "$now"
}

remote_state_clear_last_error() {
  local target="$1"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.last_error = "" | .updated_at = $now' --arg now "$now"
}

remote_checkpoint_retry_count() {
  local target="$1"
  local checkpoint="$2"
  local current
  current="$(remote_state_get_field "$target" ".checkpoints[]? | select(.name == \"$checkpoint\") | .retry_count")"
  if [ -z "$current" ]; then
    printf '0\n'
  else
    printf '%s\n' "$current"
  fi
}

remote_checkpoint_is_complete() {
  local target="$1"
  local checkpoint="$2"
  local completed_at
  completed_at="$(remote_state_get_field "$target" ".checkpoints[]? | select(.name == \"$checkpoint\") | .completed_at")"
  [ -n "$completed_at" ]
}

remote_checkpoint_set_retry() {
  local target="$1"
  local checkpoint="$2"
  local retry_count="$3"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '
    .checkpoints = (
      if (.checkpoints | map(.name) | index($checkpoint)) == null then
        .checkpoints + [{ name: $checkpoint, completed_at: "", retry_count: ($retry_count | tonumber) }]
      else
        .checkpoints | map(
          if .name == $checkpoint then
            .retry_count = ($retry_count | tonumber)
          else
            .
          end
        )
      end
    )
    | .updated_at = $now
  ' --arg checkpoint "$checkpoint" --arg retry_count "$retry_count" --arg now "$now"
}

remote_checkpoint_mark_complete() {
  local target="$1"
  local checkpoint="$2"
  local retry_count="$3"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '
    .checkpoints = (
      if (.checkpoints | map(.name) | index($checkpoint)) == null then
        .checkpoints + [{
          name: $checkpoint,
          completed_at: $now,
          retry_count: ($retry_count | tonumber)
        }]
      else
        .checkpoints | map(
          if .name == $checkpoint then
            .completed_at = $now
            | .retry_count = ($retry_count | tonumber)
          else
            .
          end
        )
      end
    )
    | .updated_at = $now
  ' --arg checkpoint "$checkpoint" --arg retry_count "$retry_count" --arg now "$now"
}

remote_install_checkpoint_order() {
  local mode="$1"
  if [ "$mode" = "hetzner" ]; then
    cat <<'EOF'
target_selected
ssh_key_ready
server_provisioned
ssh_reachable
bootstrap_installed
baudbot_install_completed
doctor_passed
tailscale_connected
completed
EOF
  else
    cat <<'EOF'
target_selected
ssh_key_ready
ssh_reachable
bootstrap_installed
baudbot_install_completed
doctor_passed
tailscale_connected
completed
EOF
  fi
}

remote_next_install_checkpoint() {
  local target="$1"
  local mode="$2"
  local checkpoint
  while IFS= read -r checkpoint; do
    [ -n "$checkpoint" ] || continue
    if ! remote_checkpoint_is_complete "$target" "$checkpoint"; then
      printf '%s\n' "$checkpoint"
      return 0
    fi
  done < <(remote_install_checkpoint_order "$mode")
  printf 'completed\n'
}

remote_reset_install_progress() {
  local target="$1"
  local now
  now="$(remote_now_iso)"
  _remote_state_write_jq "$target" '.checkpoints = [] | .status = "initialized" | .last_error = "" | .tailscale.enabled = false | .tailscale.ip = "" | .updated_at = $now' --arg now "$now"
}

remote_prompt_default() {
  local prompt="$1"
  local default_value="${2:-}"
  local answer=""
  if [ -n "$default_value" ]; then
    printf "%s [%s]: " "$prompt" "$default_value" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  read -r answer
  if [ -z "$answer" ]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$answer"
  fi
}

remote_confirm() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local suffix="[Y/n]"
  if [ "$default_answer" = "n" ]; then
    suffix="[y/N]"
  fi

  local answer=""
  printf "%s %s " "$prompt" "$suffix" >&2
  read -r answer
  if [ -z "$answer" ]; then
    answer="$default_answer"
  fi
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remote_is_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

remote_ensure_local_ssh_key() {
  local key_path_input="$1"
  local comment="$2"
  local allow_generate="${3:-1}"
  local key_path
  key_path="$(remote_expand_path "$key_path_input")"

  if [ -z "$key_path" ]; then
    remote_die "ssh key path is empty"
  fi

  local pub_key_path="${key_path}.pub"

  if [ -f "$key_path" ]; then
    chmod 600 "$key_path"
    if [ ! -f "$pub_key_path" ]; then
      if ! ssh-keygen -y -f "$key_path" > "$pub_key_path" 2>/dev/null; then
        remote_die "failed to derive public key from existing private key: $key_path"
      fi
      chmod 644 "$pub_key_path"
    fi
    printf '%s\n' "$key_path"
    return 0
  fi

  if [ "$allow_generate" != "1" ]; then
    remote_die "ssh private key not found: $key_path"
  fi

  mkdir -p "$(dirname "$key_path")"
  chmod 700 "$(dirname "$key_path")"

  if ! ssh-keygen -t ed25519 -C "$comment" -f "$key_path" -N "" >/dev/null 2>&1; then
    remote_die "failed to generate ssh key pair at: $key_path"
  fi
  chmod 600 "$key_path"
  chmod 644 "$pub_key_path"
  printf '%s\n' "$key_path"
}
