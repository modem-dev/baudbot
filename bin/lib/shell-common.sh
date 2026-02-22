#!/bin/bash
# Shared shell helpers for bin/*.sh scripts.

bb_enable_strict_mode() {
  set -euo pipefail
}

bb_log() {
  echo "  $*"
}

bb_warn() {
  echo "⚠ $*" >&2
}

bb_error() {
  echo "❌ $*" >&2
}

bb_die() {
  bb_error "$*"
  exit 1
}

bb_require_root() {
  local action="${1:-this command}"
  local allow_non_root="${2:-0}"

  if [ "$(id -u)" -ne 0 ] && [ "$allow_non_root" != "1" ]; then
    bb_die "$action requires root"
  fi
}

bb_require_non_empty() {
  local name="$1"
  local value="${2:-}"

  if [ -z "$value" ]; then
    bb_die "required value is empty: $name"
  fi
}

bb_has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

bb_restart_systemd_service_or_die() {
  local service="$1"
  if bb_has_systemd; then
    systemctl restart "$service"
  else
    bb_die "systemd not available; restart manually"
  fi
}

bb_resolve_user_home() {
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

bb_read_env_value() {
  local file="$1"
  local key="$2"
  local line=""

  [ -f "$file" ] || return 0
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)"
  [ -n "$line" ] || return 0
  echo "${line#*=}"
}
