#!/bin/bash
# Shared runtime helpers for release update/rollback scripts.
#
# Expects caller to provide:
# - log() and die() functions
# - restart_baudbot_service_if_active()
# - json_get_string_stdin()
# - BAUDBOT_AGENT_USER and BAUDBOT_AGENT_HOME

bb_run_release_override_cmd() {
  local description="$1"
  local command="$2"
  local env_array_name="$3"

  [ -n "$command" ] || return 1

  local -n env_ref="$env_array_name"
  log "running $description override"
  env "${env_ref[@]}" bash -lc "$command"
}

bb_run_release_restart_and_health() {
  local restart_cmd="$1"
  local skip_restart="$2"
  local health_cmd="$3"
  local env_array_name="$4"

  if ! bb_run_release_override_cmd "restart" "$restart_cmd" "$env_array_name"; then
    if [ "$skip_restart" = "1" ]; then
      log "skipping restart"
    else
      restart_baudbot_service_if_active
    fi
  fi

  bb_run_release_override_cmd "health" "$health_cmd" "$env_array_name" || true
}

bb_verify_deployed_release_sha() {
  local expected_sha="$1"
  local skip_version_check="$2"
  local verified_label="${3:-}"

  if [ "$skip_version_check" = "1" ]; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    log "non-root run: skipping deployed version verification"
    return 0
  fi

  if ! id "$BAUDBOT_AGENT_USER" >/dev/null 2>&1; then
    log "agent user '$BAUDBOT_AGENT_USER' missing; skipping deployed version verification"
    return 0
  fi

  local version_file="$BAUDBOT_AGENT_HOME/.pi/agent/baudbot-version.json"
  local deployed_sha

  deployed_sha="$(sudo -u "$BAUDBOT_AGENT_USER" sh -c "cat '$version_file' 2>/dev/null" | json_get_string_stdin "sha" 2>/dev/null || true)"

  if [ -z "$deployed_sha" ]; then
    die "deployed version file missing or unreadable: $version_file"
  fi

  if [ "$deployed_sha" != "$expected_sha" ]; then
    die "deployed sha mismatch (expected $expected_sha, got $deployed_sha)"
  fi

  if [ -n "$verified_label" ]; then
    log "deployed version verified: $verified_label"
  fi
}
