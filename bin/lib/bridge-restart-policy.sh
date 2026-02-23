#!/usr/bin/env bash
# Shared Slack bridge restart policy helpers.

bb_bridge_policy_mode() {
  if [ -n "${BAUDBOT_BRIDGE_RESTART_POLICY:-}" ]; then
    case "${BAUDBOT_BRIDGE_RESTART_POLICY}" in
      adaptive|ADAPTIVE|Adaptive) echo "adaptive"; return 0 ;;
      legacy|LEGACY|Legacy) echo "legacy"; return 0 ;;
    esac
  fi

  if [ -n "${BAUDBOT_BRIDGE_RESTART_BASE_DELAY_SECONDS:-}" ] \
    || [ -n "${BAUDBOT_BRIDGE_RESTART_MAX_DELAY_SECONDS:-}" ] \
    || [ -n "${BAUDBOT_BRIDGE_RESTART_STABLE_WINDOW_SECONDS:-}" ] \
    || [ -n "${BAUDBOT_BRIDGE_RESTART_MAX_CONSECUTIVE_FAILURES:-}" ] \
    || [ -n "${BAUDBOT_BRIDGE_RESTART_JITTER_SECONDS:-}" ]; then
    echo "adaptive"
    return 0
  fi

  # Backward-compatible fallback when no policy configuration is provided.
  echo "legacy"
}

bb_bridge_policy_int() {
  local raw="${1:-}"
  local fallback="${2:-0}"

  if [ -z "$raw" ]; then
    echo "$fallback"
    return 0
  fi

  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
    return 0
  fi

  echo "$fallback"
}

bb_bridge_policy_compute_next_delay() {
  local current="$1"
  local max_delay="$2"
  local doubled=$((current * 2))

  if [ "$doubled" -gt "$max_delay" ]; then
    echo "$max_delay"
  else
    echo "$doubled"
  fi
}

bb_bridge_policy_random_jitter() {
  local max_jitter="$1"

  if [ "$max_jitter" -le 0 ]; then
    echo 0
    return 0
  fi

  echo $((RANDOM % (max_jitter + 1)))
}

bb_bridge_policy_log() {
  local log_file="$1"
  shift

  if [ -z "$log_file" ]; then
    return 0
  fi

  printf '[%s] bridge-supervisor %s\n' "$(date -Is)" "$*" >>"$log_file"
}

bb_bridge_policy_write_status() {
  local status_file="$1"
  local mode="$2"
  local bridge_script="$3"
  local state="$4"
  local consecutive_failures="$5"
  local delay_seconds="$6"
  local max_failures="$7"
  local last_exit_code="$8"
  local last_runtime_seconds="$9"

  [ -n "$status_file" ] || return 0
  mkdir -p "$(dirname "$status_file")" 2>/dev/null || true

  cat >"$status_file" <<EOF
{
  "updated_at": "$(date -Is)",
  "mode": "$mode",
  "bridge_script": "$bridge_script",
  "state": "$state",
  "consecutive_failures": $consecutive_failures,
  "current_delay_seconds": $delay_seconds,
  "max_consecutive_failures": $max_failures,
  "last_exit_code": $last_exit_code,
  "last_runtime_seconds": $last_runtime_seconds
}
EOF
}

bb_bridge_supervise() {
  local log_file="$1"
  local status_file="$2"
  local bridge_script="$3"
  shift 3

  local mode
  mode="$(bb_bridge_policy_mode)"

  if [ "$mode" = "legacy" ]; then
    bb_bridge_policy_log "$log_file" "event=policy_selected mode=legacy restart_delay_seconds=5"
    bb_bridge_policy_write_status "$status_file" "$mode" "$bridge_script" "running" 0 5 0 0 0

    while true; do
      local exit_code=0
      if "$@" >>"$log_file" 2>&1; then
        exit_code=0
      else
        exit_code=$?
      fi

      bb_bridge_policy_log "$log_file" "event=restart_scheduled mode=legacy script=$bridge_script exit_code=$exit_code delay_seconds=5"
      bb_bridge_policy_write_status "$status_file" "$mode" "$bridge_script" "restarting" 0 5 0 "$exit_code" 0
      sleep 5
    done
  fi

  local base_delay max_delay stable_window max_failures max_jitter
  base_delay="$(bb_bridge_policy_int "${BAUDBOT_BRIDGE_RESTART_BASE_DELAY_SECONDS:-}" 5)"
  max_delay="$(bb_bridge_policy_int "${BAUDBOT_BRIDGE_RESTART_MAX_DELAY_SECONDS:-}" 300)"
  stable_window="$(bb_bridge_policy_int "${BAUDBOT_BRIDGE_RESTART_STABLE_WINDOW_SECONDS:-}" 120)"
  max_failures="$(bb_bridge_policy_int "${BAUDBOT_BRIDGE_RESTART_MAX_CONSECUTIVE_FAILURES:-}" 5)"
  max_jitter="$(bb_bridge_policy_int "${BAUDBOT_BRIDGE_RESTART_JITTER_SECONDS:-}" 2)"

  if [ "$max_delay" -lt "$base_delay" ]; then
    max_delay="$base_delay"
  fi

  local consecutive_failures=0
  local current_delay="$base_delay"

  bb_bridge_policy_log "$log_file" "event=policy_selected mode=adaptive base_delay_seconds=$base_delay max_delay_seconds=$max_delay stable_window_seconds=$stable_window max_consecutive_failures=$max_failures max_jitter_seconds=$max_jitter"
  bb_bridge_policy_write_status "$status_file" "$mode" "$bridge_script" "running" "$consecutive_failures" "$current_delay" "$max_failures" 0 0

  while true; do
    local started_at finished_at runtime_seconds exit_code
    started_at="$(date +%s)"
    if "$@" >>"$log_file" 2>&1; then
      exit_code=0
    else
      exit_code=$?
    fi
    finished_at="$(date +%s)"
    runtime_seconds=$((finished_at - started_at))

    local reset_failures=0
    local scheduled_delay="$current_delay"
    if [ "$runtime_seconds" -ge "$stable_window" ]; then
      reset_failures=1
      consecutive_failures=0
      scheduled_delay="$base_delay"
      current_delay="$base_delay"
      bb_bridge_policy_log "$log_file" "event=stable_window_reset mode=adaptive script=$bridge_script runtime_seconds=$runtime_seconds stable_window_seconds=$stable_window"
    else
      consecutive_failures=$((consecutive_failures + 1))
      scheduled_delay="$current_delay"
      current_delay="$(bb_bridge_policy_compute_next_delay "$current_delay" "$max_delay")"
    fi

    local jitter_seconds total_sleep_seconds
    jitter_seconds="$(bb_bridge_policy_random_jitter "$max_jitter")"
    total_sleep_seconds=$((scheduled_delay + jitter_seconds))

    local state="restarting"
    if [ "$max_failures" -gt 0 ] && [ "$consecutive_failures" -ge "$max_failures" ]; then
      state="threshold_exceeded"
      bb_bridge_policy_log "$log_file" "event=restart_threshold_exceeded mode=adaptive script=$bridge_script consecutive_failures=$consecutive_failures threshold=$max_failures exit_code=$exit_code runtime_seconds=$runtime_seconds"
    fi

    bb_bridge_policy_log "$log_file" "event=restart_scheduled mode=adaptive script=$bridge_script exit_code=$exit_code runtime_seconds=$runtime_seconds reset_failures=$reset_failures consecutive_failures=$consecutive_failures backoff_seconds=$scheduled_delay next_backoff_seconds=$current_delay jitter_seconds=$jitter_seconds sleep_seconds=$total_sleep_seconds"
    bb_bridge_policy_write_status "$status_file" "$mode" "$bridge_script" "$state" "$consecutive_failures" "$scheduled_delay" "$max_failures" "$exit_code" "$runtime_seconds"

    sleep "$total_sleep_seconds"
  done
}
