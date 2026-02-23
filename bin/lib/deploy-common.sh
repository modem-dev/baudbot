#!/bin/bash
# Shared helpers for bin/deploy.sh

bb_as_user() {
  local user="$1"
  shift
  sudo -u "$user" "$@"
}

bb_resolve_deploy_user() {
  local source_dir="$1"

  if [ -n "${BAUDBOT_CONFIG_USER:-}" ]; then
    echo "$BAUDBOT_CONFIG_USER"
    return 0
  fi

  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
    echo "$SUDO_USER"
    return 0
  fi

  local owner
  owner="$(stat -c '%U' "$source_dir" 2>/dev/null || true)"
  if [ -z "$owner" ] || [ "$owner" = "root" ]; then
    owner="$(whoami)"
  fi

  echo "$owner"
}

bb_source_env_value() {
  local render_env_script="$1"
  local deploy_home="$2"
  local deploy_user="$3"
  local admin_config="$4"
  local key="$5"

  if [ -x "$render_env_script" ]; then
    BAUDBOT_ADMIN_HOME="$deploy_home" BAUDBOT_CONFIG_USER="$deploy_user" "$render_env_script" --get "$key" 2>/dev/null || true
    return 0
  fi

  if [ -f "$admin_config" ]; then
    grep -E "^${key}=" "$admin_config" | tail -n 1 | cut -d= -f2- || true
    return 0
  fi

  return 0
}

bb_feature_gate_enabled() {
  local gate="$1"
  local experimental_mode="$2"

  case "$gate" in
    ""|always) return 0 ;;
    experimental) [ "$experimental_mode" = "1" ] ;;
    stable) [ "$experimental_mode" != "1" ] ;;
    *) return 1 ;;
  esac
}

bb_manifest_for_each() {
  local manifest_name="$1"
  local callback="$2"
  local -n manifest_ref="$manifest_name"

  local entry
  for entry in "${manifest_ref[@]}"; do
    "$callback" "$entry"
  done
}
