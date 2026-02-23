#!/bin/bash
# SSH/SCP wrappers for baudbot remote workflows.

_REMOTE_SSH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/remote-common.sh
source "$_REMOTE_SSH_LIB_DIR/remote-common.sh"

REMOTE_SSH_CONNECT_TIMEOUT_SEC="${REMOTE_SSH_CONNECT_TIMEOUT_SEC:-8}"
REMOTE_SSH_SERVER_ALIVE_INTERVAL_SEC="${REMOTE_SSH_SERVER_ALIVE_INTERVAL_SEC:-20}"
REMOTE_SSH_SERVER_ALIVE_COUNT_MAX="${REMOTE_SSH_SERVER_ALIVE_COUNT_MAX:-3}"

remote_ssh_target() {
  local ssh_user="$1"
  local host="$2"
  printf '%s@%s\n' "$ssh_user" "$host"
}

remote_ssh_exec() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="${3:-}"
  local remote_command="$4"

  remote_init_storage

  local -a args
  args=(
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$(remote_known_hosts_path)"
    -o "ConnectTimeout=${REMOTE_SSH_CONNECT_TIMEOUT_SEC}"
    -o "ServerAliveInterval=${REMOTE_SSH_SERVER_ALIVE_INTERVAL_SEC}"
    -o "ServerAliveCountMax=${REMOTE_SSH_SERVER_ALIVE_COUNT_MAX}"
    -o BatchMode=yes
  )

  if [ -n "$ssh_key_path" ]; then
    args+=( -i "$ssh_key_path" )
  fi

  ssh "${args[@]}" "$(remote_ssh_target "$ssh_user" "$host")" "$remote_command"
}

remote_ssh_exec_tty() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="${3:-}"
  local remote_command="$4"

  remote_init_storage

  local -a args
  args=(
    -tt
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$(remote_known_hosts_path)"
    -o "ConnectTimeout=${REMOTE_SSH_CONNECT_TIMEOUT_SEC}"
    -o "ServerAliveInterval=${REMOTE_SSH_SERVER_ALIVE_INTERVAL_SEC}"
    -o "ServerAliveCountMax=${REMOTE_SSH_SERVER_ALIVE_COUNT_MAX}"
  )

  if [ -n "$ssh_key_path" ]; then
    args+=( -i "$ssh_key_path" )
  fi

  ssh "${args[@]}" "$(remote_ssh_target "$ssh_user" "$host")" "$remote_command"
}

remote_scp_to() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="${3:-}"
  local local_path="$4"
  local remote_path="$5"

  remote_init_storage

  local -a args
  args=(
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$(remote_known_hosts_path)"
    -o "ConnectTimeout=${REMOTE_SSH_CONNECT_TIMEOUT_SEC}"
  )

  if [ -n "$ssh_key_path" ]; then
    args+=( -i "$ssh_key_path" )
  fi

  scp "${args[@]}" "$local_path" "$(remote_ssh_target "$ssh_user" "$host"):$remote_path"
}

remote_scp_from() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="${3:-}"
  local remote_path="$4"
  local local_path="$5"

  remote_init_storage

  local -a args
  args=(
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$(remote_known_hosts_path)"
    -o "ConnectTimeout=${REMOTE_SSH_CONNECT_TIMEOUT_SEC}"
  )

  if [ -n "$ssh_key_path" ]; then
    args+=( -i "$ssh_key_path" )
  fi

  scp "${args[@]}" "$(remote_ssh_target "$ssh_user" "$host"):$remote_path" "$local_path"
}

remote_ssh_wait_for_reachable() {
  local ssh_user="$1"
  local host="$2"
  local ssh_key_path="${3:-}"
  local max_attempts="${4:-30}"
  local sleep_seconds="${5:-5}"

  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if remote_ssh_exec "$ssh_user" "$host" "$ssh_key_path" "true" >/dev/null 2>&1; then
      return 0
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$sleep_seconds"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}
