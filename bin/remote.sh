#!/bin/bash
# Remote install/repair orchestration for baudbot.

set -euo pipefail

REMOTE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/remote-common.sh
source "$REMOTE_SCRIPT_DIR/lib/remote-common.sh"
# shellcheck source=bin/lib/remote-ssh.sh
source "$REMOTE_SCRIPT_DIR/lib/remote-ssh.sh"
# shellcheck source=bin/lib/remote-hetzner.sh
source "$REMOTE_SCRIPT_DIR/lib/remote-hetzner.sh"

REMOTE_CHECKPOINT_MAX_RETRIES="${REMOTE_CHECKPOINT_MAX_RETRIES:-3}"
REMOTE_SSH_REACHABLE_ATTEMPTS="${REMOTE_SSH_REACHABLE_ATTEMPTS:-40}"
REMOTE_SSH_REACHABLE_INTERVAL_SEC="${REMOTE_SSH_REACHABLE_INTERVAL_SEC:-3}"
REMOTE_HETZNER_WAIT_TIMEOUT_SEC="${REMOTE_HETZNER_WAIT_TIMEOUT_SEC:-600}"
REMOTE_HETZNER_WAIT_INTERVAL_SEC="${REMOTE_HETZNER_WAIT_INTERVAL_SEC:-5}"
REMOTE_BOOTSTRAP_URL="${REMOTE_BOOTSTRAP_URL:-https://raw.githubusercontent.com/modem-dev/baudbot/main/bootstrap.sh}"
REMOTE_TAILSCALE_INSTALL_URL="${REMOTE_TAILSCALE_INSTALL_URL:-https://tailscale.com/install.sh}"
REMOTE_TAILSCALE_WAIT_ATTEMPTS="${REMOTE_TAILSCALE_WAIT_ATTEMPTS:-40}"
REMOTE_TAILSCALE_WAIT_INTERVAL_SEC="${REMOTE_TAILSCALE_WAIT_INTERVAL_SEC:-3}"

REMOTE_DEFAULT_HETZNER_SERVER_TYPE="${REMOTE_HETZNER_SERVER_TYPE:-cpx11}"
REMOTE_DEFAULT_HETZNER_IMAGE="${REMOTE_HETZNER_IMAGE:-ubuntu-24.04}"
REMOTE_DEFAULT_HETZNER_LOCATION="${REMOTE_HETZNER_LOCATION:-ash}"

remote_usage() {
  cat <<'EOF_USAGE'
Usage: baudbot remote <command> [options]

Commands:
  install    Interactive remote install (mode: hetzner|host)
  repair     Guided repair workflow for existing remote host
  list       List saved remote targets
  status     Show target status and checkpoints
  resume     Resume a previously interrupted install

Install options:
  --target <name>
  --mode hetzner|host
  --host <ip-or-hostname>
  --ssh-user <user>            (default: root)
  --ssh-key <path>
  --hetzner-token <token>      (fallback: HETZNER_API_TOKEN)
  --server-type <type>         (hetzner only, default: cpx11)
  --image <image>              (hetzner only, default: ubuntu-24.04)
  --location <location>        (hetzner only, default: ash)
  --tailscale                  force Tailscale setup
  --no-tailscale               skip Tailscale setup
  --tailscale-auth-key <key>   (fallback: TAILSCALE_AUTHKEY)
  --resume
  --dry-run

Repair options:
  --target <name> | --host <ip-or-hostname>
  --ssh-user <user>
  --ssh-key <path>
  --tailscale-auth-key <key>   (fallback: TAILSCALE_AUTHKEY)
  --non-interactive-safe
  --dry-run
EOF_USAGE
}

remote_prompt_secret() {
  local prompt="$1"
  local value=""
  printf "%s: " "$prompt" >&2
  read -r -s value
  printf '\n' >&2
  printf '%s\n' "$value"
}

remote_mode_or_die() {
  local mode="$1"
  case "$mode" in
    hetzner|host)
      return 0
      ;;
    *)
      remote_die "invalid mode '$mode' (expected hetzner|host)"
      ;;
  esac
}

remote_target_from_host() {
  local host="$1"
  local normalized=""
  normalized="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g')"
  if [ -z "$normalized" ]; then
    normalized="remote-host"
  fi
  printf '%s\n' "$normalized"
}

remote_checkpoint_phase() {
  local mode="$1"
  local checkpoint="$2"

  case "$checkpoint" in
    target_selected|ssh_key_ready|server_provisioned|ssh_reachable)
      if [ "$mode" = "hetzner" ]; then
        printf 'provisioning\n'
      else
        printf 'installing\n'
      fi
      ;;
    bootstrap_installed|baudbot_install_completed|doctor_passed|tailscale_connected)
      printf 'installing\n'
      ;;
    completed)
      printf 'ready\n'
      ;;
    *)
      printf 'installing\n'
      ;;
  esac
}

remote_run_bootstrap_remote() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="$3"

  local cmd
  cmd="if command -v curl >/dev/null 2>&1; then curl -fsSL '$REMOTE_BOOTSTRAP_URL' | bash; elif command -v wget >/dev/null 2>&1; then wget -qO- '$REMOTE_BOOTSTRAP_URL' | bash; else echo 'curl or wget is required on remote host' >&2; exit 1; fi"
  remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "$cmd"
}

remote_run_install_remote() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="$3"

  if ! remote_is_interactive; then
    remote_die "remote install requires an interactive terminal (or use --dry-run)"
  fi

  remote_ssh_exec_tty "$ssh_user" "$host" "$ssh_key_path" "baudbot install"
}

remote_run_post_install_doctor() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="$3"

  remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "sudo baudbot status"
  remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "sudo baudbot doctor"
}

remote_shell_single_quote() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

remote_tailscale_wait_running() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="$3"

  local attempt=1
  while [ "$attempt" -le "$REMOTE_TAILSCALE_WAIT_ATTEMPTS" ]; do
    local status_json backend_state tailscale_ip
    status_json="$(remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "if command -v tailscale >/dev/null 2>&1; then sudo tailscale status --json 2>/dev/null || true; fi" 2>/dev/null || true)"
    backend_state="$(printf '%s' "$status_json" | jq -er '.BackendState // empty' 2>/dev/null || true)"
    tailscale_ip="$(printf '%s' "$status_json" | jq -er '.Self.TailscaleIPs[0] // empty' 2>/dev/null || true)"

    if [ "$backend_state" = "Running" ] && [ -n "$tailscale_ip" ]; then
      printf '%s\n' "$tailscale_ip"
      return 0
    fi

    if [ "$attempt" -lt "$REMOTE_TAILSCALE_WAIT_ATTEMPTS" ]; then
      sleep "$REMOTE_TAILSCALE_WAIT_INTERVAL_SEC"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

remote_configure_tailscale() {
  local target="$1"
  local ssh_user="$2"
  local host="$3"
  local ssh_key_path="$4"
  local tailscale_auth_key="$5"
  local tailscale_mode="$6"
  local dry_run="$7"

  if [ "$dry_run" = "1" ]; then
    remote_state_set_tailscale_enabled "$target" "false"
    remote_state_set_tailscale_ip "$target" ""
    return 0
  fi

  local effective_mode="$tailscale_mode"
  if [ "$effective_mode" = "auto" ]; then
    if remote_is_interactive; then
      if remote_confirm "Configure Tailscale on '$target' for secure remote access?" "y"; then
        effective_mode="enable"
      else
        effective_mode="skip"
      fi
    else
      effective_mode="skip"
    fi
  fi

  if [ "$effective_mode" = "skip" ]; then
    remote_state_set_tailscale_enabled "$target" "false"
    remote_state_set_tailscale_ip "$target" ""
    return 0
  fi

  if [ -z "$tailscale_auth_key" ] && ! remote_is_interactive; then
    remote_die "tailscale setup requested in non-interactive mode requires --tailscale-auth-key or TAILSCALE_AUTHKEY"
  fi

  remote_log "[$target] ensuring Tailscale is installed"
  remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" \
    "sudo sh -c 'if command -v tailscale >/dev/null 2>&1; then exit 0; fi; if command -v curl >/dev/null 2>&1; then curl -fsSL \"$REMOTE_TAILSCALE_INSTALL_URL\" | sh; elif command -v wget >/dev/null 2>&1; then wget -qO- \"$REMOTE_TAILSCALE_INSTALL_URL\" | sh; else echo \"curl or wget required to install tailscale\" >&2; exit 1; fi'"

  remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" \
    "sudo systemctl enable --now tailscaled >/dev/null 2>&1 || sudo service tailscaled start >/dev/null 2>&1 || true"

  if [ -n "$tailscale_auth_key" ]; then
    local escaped_auth_key
    escaped_auth_key="$(remote_shell_single_quote "$tailscale_auth_key")"
    remote_log "[$target] connecting Tailscale with auth key"
    remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" \
      "sudo tailscale up --authkey '$escaped_auth_key' --ssh --accept-routes"
  else
    local up_output=""
    if ! up_output="$(remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "sudo tailscale up --ssh --accept-routes" 2>&1)"; then
      local login_url=""
      login_url="$(printf '%s' "$up_output" | grep -Eo 'https://login\.tailscale\.com[^[:space:]]+' | head -n 1 || true)"

      if [ -n "$login_url" ]; then
        remote_log "[$target] complete Tailscale login: $login_url"
      else
        remote_warn "tailscale up did not return success and no login URL was parsed"
      fi

      if remote_is_interactive; then
        remote_prompt_default "Press Enter after completing Tailscale login in your browser" "" >/dev/null
      fi
    fi
  fi

  local tailscale_ip=""
  tailscale_ip="$(remote_tailscale_wait_running "$ssh_user" "$host" "$ssh_key_path" || true)"
  if [ -z "$tailscale_ip" ]; then
    remote_die "failed to verify Tailscale connectivity on '$target'"
  fi

  remote_state_set_tailscale_enabled "$target" "true"
  remote_state_set_tailscale_ip "$target" "$tailscale_ip"
  remote_log "[$target] Tailscale connected: $tailscale_ip"
}

remote_prepare_state_install() {
  local target="$1"
  local mode="$2"
  local host="$3"
  local ssh_user="$4"
  local ssh_key_path="$5"
  local location="$6"
  local server_type="$7"
  local image="$8"
  local resume="$9"

  local provider_name="none"
  if [ "$mode" = "hetzner" ]; then
    provider_name="hetzner"
  fi

  if [ "$resume" = "1" ]; then
    if ! remote_state_exists "$target"; then
      remote_die "resume requested but target '$target' was not found"
    fi

    local existing_mode
    existing_mode="$(remote_state_get_field "$target" '.mode')"
    if [ -z "$existing_mode" ]; then
      remote_die "target '$target' has invalid state (missing mode)"
    fi
    if [ "$existing_mode" != "$mode" ]; then
      remote_die "target '$target' is mode '$existing_mode', not '$mode'"
    fi

    if [ -n "$host" ]; then
      remote_state_set_host "$target" "$host"
    fi
    if [ -n "$ssh_user" ]; then
      remote_state_set_ssh_user "$target" "$ssh_user"
    fi
    if [ -n "$ssh_key_path" ]; then
      remote_state_set_ssh_key_path "$target" "$ssh_key_path"
    fi
    if [ "$mode" = "hetzner" ]; then
      remote_state_set_provider_field "$target" "location" "$location"
      remote_state_set_provider_field "$target" "server_type" "$server_type"
      remote_state_set_provider_field "$target" "image" "$image"
    fi
  else
    if remote_state_exists "$target"; then
      remote_die "target '$target' already exists; use --resume or choose a new --target"
    fi
    remote_state_init "$target" "$mode" "$host" "$ssh_user" "$ssh_key_path" "$provider_name" "$location" "$server_type" "$image"
  fi

  if ! remote_checkpoint_is_complete "$target" "target_selected"; then
    remote_checkpoint_mark_complete "$target" "target_selected" 0
  fi
}

remote_cleanup_provider_if_key_mismatch() {
  local target="$1"
  local mode="$2"
  local token="$3"
  local key_preexisted="$4"
  local dry_run="$5"

  if [ "$mode" != "hetzner" ]; then
    return 0
  fi

  if [ "$key_preexisted" = "1" ]; then
    return 0
  fi

  local server_id ssh_key_id
  server_id="$(remote_state_get_field "$target" '.provider.server_id')"
  ssh_key_id="$(remote_state_get_field "$target" '.provider.ssh_key_id')"

  if [ -z "$server_id" ] && [ -z "$ssh_key_id" ]; then
    return 0
  fi

  if [ -z "$token" ]; then
    remote_die "local SSH key was regenerated and remote resources exist; provide --hetzner-token (or HETZNER_API_TOKEN) to reconcile"
  fi

  if ! remote_is_interactive; then
    remote_die "local SSH key was regenerated and remote resources exist; rerun interactively to confirm cleanup"
  fi

  if ! remote_confirm "Local SSH key was regenerated for '$target'. Delete stale Hetzner server/key resources before continuing?" "y"; then
    remote_die "aborting to avoid mismatched SSH credentials"
  fi

  if [ "$dry_run" = "1" ]; then
    remote_log "[dry-run] would delete stale Hetzner resources for '$target'"
  else
    provider_delete_server "hetzner" "$token" "$server_id" || true
    provider_delete_ssh_key "hetzner" "$token" "$ssh_key_id" || true
  fi

  remote_state_set_provider_field "$target" "server_id" ""
  remote_state_set_provider_field "$target" "ssh_key_id" ""
  remote_state_set_host "$target" ""
}

remote_execute_install_checkpoint() {
  local target="$1"
  local mode="$2"
  local checkpoint="$3"
  local hetzner_token="$4"
  local tailscale_mode="$5"
  local tailscale_auth_key="$6"
  local dry_run="$7"

  local host ssh_user ssh_key_path
  host="$(remote_state_get_field "$target" '.host')"
  ssh_user="$(remote_state_get_field "$target" '.ssh_user')"
  ssh_key_path="$(remote_state_get_field "$target" '.ssh_key_path')"

  case "$checkpoint" in
    target_selected)
      return 0
      ;;

    ssh_key_ready)
      local default_key key_preexisted key_comment resolved_key
      default_key="$(remote_keys_dir)/$target"
      if [ -z "$ssh_key_path" ]; then
        ssh_key_path="$default_key"
        remote_state_set_ssh_key_path "$target" "$ssh_key_path"
      fi

      key_preexisted=0
      if [ -f "$(remote_expand_path "$ssh_key_path")" ]; then
        key_preexisted=1
      fi

      if [ "$mode" = "hetzner" ] && [ "$dry_run" != "1" ]; then
        provider_validate_credentials "hetzner" "$hetzner_token"
      fi

      remote_cleanup_provider_if_key_mismatch "$target" "$mode" "$hetzner_token" "$key_preexisted" "$dry_run"

      key_comment="baudbot-remote-$target"
      resolved_key="$(remote_ensure_local_ssh_key "$ssh_key_path" "$key_comment" 1)"
      remote_state_set_ssh_key_path "$target" "$resolved_key"
      return 0
      ;;

    server_provisioned)
      if [ "$mode" != "hetzner" ]; then
        return 0
      fi

      if [ -z "$hetzner_token" ]; then
        remote_die "Hetzner mode requires --hetzner-token or HETZNER_API_TOKEN"
      fi

      local location server_type image server_id ssh_key_id key_name pub_key existing_server_id server_ip
      location="$(remote_state_get_field "$target" '.provider.location')"
      server_type="$(remote_state_get_field "$target" '.provider.server_type')"
      image="$(remote_state_get_field "$target" '.provider.image')"
      server_id="$(remote_state_get_field "$target" '.provider.server_id')"
      ssh_key_id="$(remote_state_get_field "$target" '.provider.ssh_key_id')"
      ssh_key_path="$(remote_state_get_field "$target" '.ssh_key_path')"

      if [ -z "$location" ]; then
        location="$REMOTE_DEFAULT_HETZNER_LOCATION"
      fi
      if [ -z "$server_type" ]; then
        server_type="$REMOTE_DEFAULT_HETZNER_SERVER_TYPE"
      fi
      if [ -z "$image" ]; then
        image="$REMOTE_DEFAULT_HETZNER_IMAGE"
      fi

      if [ "$dry_run" = "1" ]; then
        if [ -z "$host" ]; then
          remote_state_set_host "$target" "dry-run-host"
        fi
        return 0
      fi

      key_name="baudbot-remote-$target"
      pub_key="$(cat "${ssh_key_path}.pub")"

      if [ -z "$ssh_key_id" ]; then
        ssh_key_id="$(provider_create_ssh_key "hetzner" "$hetzner_token" "$key_name" "$pub_key")"
        remote_state_set_provider_field "$target" "ssh_key_id" "$ssh_key_id"
      fi

      if [ -z "$server_id" ]; then
        existing_server_id="$(remote_hetzner_find_server_id_by_name "$hetzner_token" "$target" || true)"
        if [ -n "$existing_server_id" ]; then
          if remote_is_interactive && remote_confirm "Existing Hetzner server '$target' found (id $existing_server_id). Delete and recreate?" "y"; then
            provider_delete_server "hetzner" "$hetzner_token" "$existing_server_id"
          else
            remote_die "existing Hetzner server '$target' blocks provisioning"
          fi
        fi

        server_id="$(provider_create_server "hetzner" "$hetzner_token" "$target" "$server_type" "$image" "$location" "$ssh_key_id")"
        remote_state_set_provider_field "$target" "server_id" "$server_id"
      fi

      server_ip="$(provider_wait_server_running "hetzner" "$hetzner_token" "$server_id" "$REMOTE_HETZNER_WAIT_TIMEOUT_SEC" "$REMOTE_HETZNER_WAIT_INTERVAL_SEC")"
      if [ -z "$server_ip" ]; then
        remote_die "failed to obtain running server IP from Hetzner"
      fi
      remote_state_set_host "$target" "$server_ip"
      return 0
      ;;

    ssh_reachable)
      host="$(remote_state_get_field "$target" '.host')"
      if [ -z "$host" ]; then
        remote_die "target '$target' has no host configured"
      fi

      if [ "$dry_run" = "1" ]; then
        return 0
      fi

      if remote_ssh_wait_for_reachable "$ssh_user" "$host" "$ssh_key_path" "$REMOTE_SSH_REACHABLE_ATTEMPTS" "$REMOTE_SSH_REACHABLE_INTERVAL_SEC"; then
        return 0
      fi
      remote_error "SSH not reachable for $ssh_user@$host"
      return 1
      ;;

    bootstrap_installed)
      host="$(remote_state_get_field "$target" '.host')"
      if [ -z "$host" ]; then
        remote_die "target '$target' has no host configured"
      fi
      if [ "$dry_run" = "1" ]; then
        return 0
      fi
      remote_run_bootstrap_remote "$ssh_user" "$host" "$ssh_key_path"
      return 0
      ;;

    baudbot_install_completed)
      host="$(remote_state_get_field "$target" '.host')"
      if [ -z "$host" ]; then
        remote_die "target '$target' has no host configured"
      fi
      if [ "$dry_run" = "1" ]; then
        return 0
      fi
      remote_run_install_remote "$ssh_user" "$host" "$ssh_key_path"
      return 0
      ;;

    doctor_passed)
      host="$(remote_state_get_field "$target" '.host')"
      if [ -z "$host" ]; then
        remote_die "target '$target' has no host configured"
      fi
      if [ "$dry_run" = "1" ]; then
        return 0
      fi
      remote_run_post_install_doctor "$ssh_user" "$host" "$ssh_key_path"
      return 0
      ;;

    tailscale_connected)
      host="$(remote_state_get_field "$target" '.host')"
      if [ -z "$host" ]; then
        remote_die "target '$target' has no host configured"
      fi
      remote_configure_tailscale "$target" "$ssh_user" "$host" "$ssh_key_path" "$tailscale_auth_key" "$tailscale_mode" "$dry_run"
      return 0
      ;;

    completed)
      return 0
      ;;

    *)
      remote_error "unknown checkpoint: $checkpoint"
      return 1
      ;;
  esac
}

remote_run_install_lifecycle() {
  local target="$1"
  local mode="$2"
  local hetzner_token="$3"
  local tailscale_mode="$4"
  local tailscale_auth_key="$5"
  local dry_run="$6"

  while true; do
    local restart_from_beginning=0
    local checkpoint=""

    while IFS= read -r checkpoint; do
      [ -n "$checkpoint" ] || continue

      if remote_checkpoint_is_complete "$target" "$checkpoint"; then
        continue
      fi

      local phase retry_count
      phase="$(remote_checkpoint_phase "$mode" "$checkpoint")"
      if [ "$phase" != "ready" ]; then
        remote_state_set_status "$target" "$phase"
      fi

      retry_count="$(remote_checkpoint_retry_count "$target" "$checkpoint")"
      while [ "$retry_count" -lt "$REMOTE_CHECKPOINT_MAX_RETRIES" ]; do
        remote_log "[$target] checkpoint: $checkpoint"

        if remote_execute_install_checkpoint "$target" "$mode" "$checkpoint" "$hetzner_token" "$tailscale_mode" "$tailscale_auth_key" "$dry_run"; then
          remote_checkpoint_mark_complete "$target" "$checkpoint" "$retry_count"
          remote_state_clear_last_error "$target"
          break
        fi

        retry_count=$((retry_count + 1))
        remote_checkpoint_set_retry "$target" "$checkpoint" "$retry_count"
        remote_state_set_last_error "$target" "checkpoint '$checkpoint' failed"

        if [ "$retry_count" -lt "$REMOTE_CHECKPOINT_MAX_RETRIES" ]; then
          remote_warn "checkpoint '$checkpoint' failed (attempt $retry_count/$REMOTE_CHECKPOINT_MAX_RETRIES), retrying"
          sleep 3
          continue
        fi

        remote_state_set_status "$target" "failed"

        if remote_is_interactive && remote_confirm "Checkpoint '$checkpoint' failed after $REMOTE_CHECKPOINT_MAX_RETRIES attempts. Retry this install from the beginning?" "n"; then
          remote_reset_install_progress "$target"
          restart_from_beginning=1
          break
        fi

        return 1
      done

      if [ "$restart_from_beginning" = "1" ]; then
        break
      fi
    done < <(remote_install_checkpoint_order "$mode")

    if [ "$restart_from_beginning" = "1" ]; then
      continue
    fi

    break
  done

  remote_state_set_status "$target" "ready"
  remote_state_clear_last_error "$target"
  remote_log "[$target] install completed"
}

remote_cmd_install() {
  local target=""
  local mode=""
  local host=""
  local ssh_user="root"
  local ssh_user_set=0
  local ssh_key_path=""
  local hetzner_token="${HETZNER_API_TOKEN:-}"
  local tailscale_mode="auto"
  local tailscale_auth_key="${TAILSCALE_AUTHKEY:-}"
  local resume=0
  local dry_run=0
  local location="$REMOTE_DEFAULT_HETZNER_LOCATION"
  local server_type="$REMOTE_DEFAULT_HETZNER_SERVER_TYPE"
  local image="$REMOTE_DEFAULT_HETZNER_IMAGE"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)
        target="$2"
        shift 2
        ;;
      --mode)
        mode="$2"
        shift 2
        ;;
      --host)
        host="$2"
        shift 2
        ;;
      --ssh-user)
        ssh_user="$2"
        ssh_user_set=1
        shift 2
        ;;
      --ssh-key)
        ssh_key_path="$2"
        shift 2
        ;;
      --hetzner-token)
        hetzner_token="$2"
        shift 2
        ;;
      --tailscale)
        tailscale_mode="enable"
        shift
        ;;
      --no-tailscale)
        tailscale_mode="skip"
        shift
        ;;
      --tailscale-auth-key)
        tailscale_auth_key="$2"
        shift 2
        ;;
      --server-type)
        server_type="$2"
        shift 2
        ;;
      --image)
        image="$2"
        shift 2
        ;;
      --location)
        location="$2"
        shift 2
        ;;
      --resume)
        resume=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        remote_usage
        return 0
        ;;
      *)
        remote_die "unknown install option: $1"
        ;;
    esac
  done

  remote_init_storage

  if [ -z "$target" ]; then
    local target_default
    if [ -n "$host" ]; then
      target_default="$(remote_target_from_host "$host")"
    else
      target_default="baudbot-$(date +%Y%m%d%H%M%S)"
    fi

    if remote_is_interactive; then
      target="$(remote_prompt_default "Target name" "$target_default")"
    else
      target="$target_default"
    fi
  fi
  remote_validate_target_name "$target" || return 1

  if [ "$resume" = "1" ] && ! remote_state_exists "$target"; then
    remote_die "target '$target' not found for resume"
  fi

  if [ "$resume" = "1" ]; then
    if [ -z "$mode" ]; then
      mode="$(remote_state_get_field "$target" '.mode')"
    fi

    local stored_mode
    stored_mode="$(remote_state_get_field "$target" '.mode')"
    if [ -n "$stored_mode" ]; then
      mode="$stored_mode"
    fi
  fi

  if [ -z "$mode" ]; then
    if remote_is_interactive; then
      mode="$(remote_prompt_default "Install mode (hetzner|host)" "host")"
    else
      remote_die "--mode is required in non-interactive mode"
    fi
  fi
  remote_mode_or_die "$mode"
  remote_require_dependencies_install "$mode"

  if [ "$mode" = "host" ] && [ -z "$host" ] && [ "$resume" != "1" ]; then
    if remote_is_interactive; then
      host="$(remote_prompt_default "Remote host (IP or hostname)" "")"
    else
      remote_die "--host is required for host mode"
    fi
  fi

  if [ "$mode" = "hetzner" ] && [ -z "$hetzner_token" ] && [ "$dry_run" != "1" ]; then
    if remote_is_interactive; then
      hetzner_token="$(remote_prompt_secret "Hetzner API token")"
    else
      remote_die "Hetzner mode requires --hetzner-token or HETZNER_API_TOKEN"
    fi
  fi

  if [ -n "$ssh_key_path" ]; then
    ssh_key_path="$(remote_expand_path "$ssh_key_path")"
  else
    ssh_key_path="$(remote_keys_dir)/$target"
  fi

  if [ "$resume" = "1" ]; then
    if [ -z "$host" ]; then
      host="$(remote_state_get_field "$target" '.host')"
    fi
    if [ "$ssh_user_set" -eq 0 ]; then
      ssh_user="$(remote_state_get_field "$target" '.ssh_user')"
      ssh_user="${ssh_user:-root}"
    fi
  fi

  remote_prepare_state_install "$target" "$mode" "$host" "$ssh_user" "$ssh_key_path" "$location" "$server_type" "$image" "$resume"

  remote_run_install_lifecycle "$target" "$mode" "$hetzner_token" "$tailscale_mode" "$tailscale_auth_key" "$dry_run"
}

remote_capture_remote_output() {
  local __result_var="$1"
  local ssh_user="$2"
  local host="$3"
  local ssh_key_path="$4"
  local command="$5"

  local output=""
  local rc=0
  if output="$(remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "$command" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  printf -v "$__result_var" '%s' "$output"
  return "$rc"
}

remote_run_repair_action() {
  local dry_run="$1"
  local ssh_user="$2"
  local host="$3"
  local ssh_key_path="$4"
  local label="$5"
  local command="$6"

  if [ "$dry_run" = "1" ]; then
    remote_log "[dry-run] $label: $command"
    return 0
  fi

  remote_log "$label"
  remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "$command"
}

remote_cmd_repair() {
  local target=""
  local host=""
  local ssh_user="root"
  local ssh_key_path=""
  local tailscale_auth_key="${TAILSCALE_AUTHKEY:-}"
  local non_interactive_safe=0
  local dry_run=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)
        target="$2"
        shift 2
        ;;
      --host)
        host="$2"
        shift 2
        ;;
      --ssh-user)
        ssh_user="$2"
        shift 2
        ;;
      --ssh-key)
        ssh_key_path="$2"
        shift 2
        ;;
      --tailscale-auth-key)
        tailscale_auth_key="$2"
        shift 2
        ;;
      --non-interactive-safe)
        non_interactive_safe=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        remote_usage
        return 0
        ;;
      *)
        remote_die "unknown repair option: $1"
        ;;
    esac
  done

  remote_require_dependencies_repair
  remote_init_storage

  if [ -z "$target" ] && [ -z "$host" ]; then
    remote_die "repair requires --target <name> or --host <ip-or-hostname>"
  fi

  if [ -z "$target" ] && [ -n "$host" ]; then
    target="$(remote_target_from_host "$host")"
  fi

  remote_validate_target_name "$target" || return 1

  if remote_state_exists "$target"; then
    if [ -z "$host" ]; then
      host="$(remote_state_get_field "$target" '.host')"
    fi
    if [ -z "$ssh_user" ] || [ "$ssh_user" = "root" ]; then
      local state_ssh_user
      state_ssh_user="$(remote_state_get_field "$target" '.ssh_user')"
      if [ -n "$state_ssh_user" ]; then
        ssh_user="$state_ssh_user"
      fi
    fi
    if [ -z "$ssh_key_path" ]; then
      ssh_key_path="$(remote_state_get_field "$target" '.ssh_key_path')"
    fi
  else
    if [ -z "$host" ]; then
      remote_die "target '$target' not found and no --host provided"
    fi
    remote_state_init "$target" "host" "$host" "$ssh_user" "$ssh_key_path" "none" "" "" ""
    remote_checkpoint_mark_complete "$target" "target_selected" 0
  fi

  if [ -z "$host" ]; then
    remote_die "repair target '$target' has no host configured"
  fi

  if [ -n "$ssh_key_path" ]; then
    ssh_key_path="$(remote_expand_path "$ssh_key_path")"
    if [ "$dry_run" != "1" ] && [ ! -f "$ssh_key_path" ]; then
      remote_die "ssh key not found: $ssh_key_path"
    fi
    remote_state_set_ssh_key_path "$target" "$ssh_key_path"
  fi

  remote_state_set_host "$target" "$host"
  remote_state_set_ssh_user "$target" "$ssh_user"
  remote_state_set_status "$target" "repairing"

  local before_status_output=""
  local before_doctor_output=""
  local after_status_output=""
  local after_doctor_output=""
  local before_status_rc=0
  local before_doctor_rc=0
  local after_status_rc=0
  local after_doctor_rc=0

  remote_log "[$target] collecting baseline diagnostics"
  if [ "$dry_run" = "1" ]; then
    before_status_output="[dry-run] skipped"
    before_doctor_output="[dry-run] skipped"
  else
    if remote_capture_remote_output before_status_output "$ssh_user" "$host" "$ssh_key_path" "sudo baudbot status"; then
      before_status_rc=0
    else
      before_status_rc=$?
    fi
    if remote_capture_remote_output before_doctor_output "$ssh_user" "$host" "$ssh_key_path" "sudo baudbot doctor"; then
      before_doctor_rc=0
    else
      before_doctor_rc=$?
    fi
  fi

  local -a safe_labels
  local -a safe_commands
  safe_labels=(
    "sync env + restart"
    "deploy"
    "restart"
    "doctor re-check"
    "tailscale status"
  )
  safe_commands=(
    "sudo baudbot env sync --restart"
    "sudo baudbot deploy"
    "sudo baudbot restart"
    "sudo baudbot doctor"
    "if command -v tailscale >/dev/null 2>&1; then sudo tailscale status || true; else echo 'tailscale is not installed'; fi"
  )

  local i run_action=0
  for i in "${!safe_labels[@]}"; do
    run_action=0
    if [ "$non_interactive_safe" = "1" ]; then
      run_action=1
    elif remote_is_interactive; then
      if remote_confirm "Run safe repair action: ${safe_labels[$i]}?" "y"; then
        run_action=1
      fi
    fi

    if [ "$run_action" = "1" ]; then
      if ! remote_run_repair_action "$dry_run" "$ssh_user" "$host" "$ssh_key_path" "[$target] ${safe_labels[$i]}" "${safe_commands[$i]}"; then
        remote_warn "safe action failed: ${safe_labels[$i]}"
      fi
    fi
  done

  if [ "$non_interactive_safe" != "1" ] && remote_is_interactive; then
    if remote_confirm "Run advanced action: rerun setup (sudo baudbot setup <admin_user>)?" "n"; then
      local admin_user
      admin_user="$(remote_prompt_default "Admin username for setup" "")"
      if [ -n "$admin_user" ]; then
        if ! remote_run_repair_action "$dry_run" "$ssh_user" "$host" "$ssh_key_path" "[$target] rerun setup" "sudo baudbot setup $admin_user"; then
          remote_warn "advanced action failed: setup"
        fi
      fi
    fi

    if remote_confirm "Run advanced action: reinstall using bootstrap + install?" "n"; then
      if [ "$dry_run" = "1" ]; then
        remote_log "[dry-run] advanced reinstall skipped"
      else
        remote_run_bootstrap_remote "$ssh_user" "$host" "$ssh_key_path"
        remote_run_install_remote "$ssh_user" "$host" "$ssh_key_path"
      fi
    fi

    if remote_confirm "Run advanced action: install/re-auth Tailscale for remote access?" "n"; then
      local repair_tailscale_key="$tailscale_auth_key"
      if [ -z "$repair_tailscale_key" ] && remote_is_interactive; then
        repair_tailscale_key="$(remote_prompt_secret "Tailscale auth key (leave empty for browser login)")"
      fi
      if ! remote_configure_tailscale "$target" "$ssh_user" "$host" "$ssh_key_path" "$repair_tailscale_key" "enable" "$dry_run"; then
        remote_warn "advanced action failed: tailscale install/re-auth"
      fi
    fi
  fi

  remote_log "[$target] collecting post-repair diagnostics"
  if [ "$dry_run" = "1" ]; then
    after_status_output="[dry-run] skipped"
    after_doctor_output="[dry-run] skipped"
  else
    if remote_capture_remote_output after_status_output "$ssh_user" "$host" "$ssh_key_path" "sudo baudbot status"; then
      after_status_rc=0
    else
      after_status_rc=$?
    fi
    if remote_capture_remote_output after_doctor_output "$ssh_user" "$host" "$ssh_key_path" "sudo baudbot doctor"; then
      after_doctor_rc=0
    else
      after_doctor_rc=$?
    fi
  fi

  if [ "$dry_run" = "1" ] || { [ "$after_status_rc" -eq 0 ] && [ "$after_doctor_rc" -eq 0 ]; }; then
    remote_state_set_status "$target" "ready"
    remote_state_clear_last_error "$target"
  else
    remote_state_set_status "$target" "failed"
    remote_state_set_last_error "$target" "repair health checks failed"
  fi

  echo ""
  echo "=== Repair Summary ($target) ==="
  echo "Host: $host"
  echo "Before: status rc=$before_status_rc, doctor rc=$before_doctor_rc"
  echo "After:  status rc=$after_status_rc, doctor rc=$after_doctor_rc"
  echo ""
  echo "--- Before status ---"
  printf '%s\n' "$before_status_output"
  echo ""
  echo "--- Before doctor ---"
  printf '%s\n' "$before_doctor_output"
  echo ""
  echo "--- After status ---"
  printf '%s\n' "$after_status_output"
  echo ""
  echo "--- After doctor ---"
  printf '%s\n' "$after_doctor_output"
}

remote_cmd_list() {
  remote_init_storage

  local found=0
  local file
  printf "%-24s %-8s %-22s %-12s %-20s\n" "TARGET" "MODE" "HOST" "STATUS" "NEXT"
  printf "%-24s %-8s %-22s %-12s %-20s\n" "------" "----" "----" "------" "----"

  for file in "$(remote_targets_dir)"/*.json; do
    [ -e "$file" ] || continue
    found=1

    local name mode host status next
    name="$(jq -er '.name // empty' "$file" 2>/dev/null || true)"
    mode="$(jq -er '.mode // empty' "$file" 2>/dev/null || true)"
    host="$(jq -er '.host // empty' "$file" 2>/dev/null || true)"
    status="$(jq -er '.status // empty' "$file" 2>/dev/null || true)"

    if [ -z "$name" ]; then
      continue
    fi

    if [ -n "$mode" ]; then
      next="$(remote_next_install_checkpoint "$name" "$mode")"
    else
      next="unknown"
    fi

    printf "%-24s %-8s %-22s %-12s %-20s\n" "$name" "${mode:-?}" "${host:--}" "${status:--}" "$next"
  done

  if [ "$found" -eq 0 ]; then
    echo "No remote targets found."
  fi
}

remote_cmd_status() {
  local target="$1"

  remote_validate_target_name "$target" || return 1
  if ! remote_state_exists "$target"; then
    remote_die "target '$target' not found"
  fi

  local mode host status last_error next_checkpoint tailscale_enabled tailscale_ip
  mode="$(remote_state_get_field "$target" '.mode')"
  host="$(remote_state_get_field "$target" '.host')"
  status="$(remote_state_get_field "$target" '.status')"
  last_error="$(remote_state_get_field "$target" '.last_error')"
  next_checkpoint="$(remote_next_install_checkpoint "$target" "$mode")"
  tailscale_enabled="$(remote_state_get_field "$target" '.tailscale.enabled')"
  tailscale_ip="$(remote_state_get_field "$target" '.tailscale.ip')"

  echo "Target:          $target"
  echo "Mode:            ${mode:--}"
  echo "Host:            ${host:--}"
  echo "Status:          ${status:--}"
  echo "Next checkpoint: ${next_checkpoint:--}"
  echo "Tailscale:       ${tailscale_enabled:-false}"
  if [ -n "$tailscale_ip" ]; then
    echo "Tailscale IP:    $tailscale_ip"
  fi
  if [ -n "$last_error" ]; then
    echo "Last error:      $last_error"
  fi

  echo ""
  echo "Checkpoints:"

  local checkpoint
  while IFS= read -r checkpoint; do
    [ -n "$checkpoint" ] || continue
    local completed_at retry_count
    completed_at="$(remote_state_get_field "$target" ".checkpoints[]? | select(.name == \"$checkpoint\") | .completed_at")"
    retry_count="$(remote_checkpoint_retry_count "$target" "$checkpoint")"
    if [ -n "$completed_at" ]; then
      printf '  %-24s done (%s, retries=%s)\n' "$checkpoint" "$completed_at" "$retry_count"
    else
      printf '  %-24s pending (retries=%s)\n' "$checkpoint" "$retry_count"
    fi
  done < <(remote_install_checkpoint_order "$mode")
}

remote_cmd_resume() {
  local target="$1"
  shift

  if ! remote_state_exists "$target"; then
    remote_die "target '$target' not found"
  fi

  local status
  status="$(remote_state_get_field "$target" '.status')"

  if [ "$status" = "repairing" ]; then
    remote_cmd_repair --target "$target" "$@"
    return 0
  fi

  remote_cmd_install --target "$target" --resume "$@"
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    install)
      remote_cmd_install "$@"
      ;;
    repair)
      remote_cmd_repair "$@"
      ;;
    list)
      remote_cmd_list
      ;;
    status)
      if [ "$#" -ne 1 ]; then
        remote_die "usage: baudbot remote status <target>"
      fi
      remote_cmd_status "$1"
      ;;
    resume)
      if [ "$#" -lt 1 ]; then
        remote_die "usage: baudbot remote resume <target> [options]"
      fi
      local target="$1"
      shift
      remote_cmd_resume "$target" "$@"
      ;;
    -h|--help|"")
      remote_usage
      ;;
    *)
      remote_die "unknown remote command: $command"
      ;;
  esac
}

main "$@"
