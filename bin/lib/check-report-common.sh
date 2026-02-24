#!/bin/bash
# Shared counter helpers for check/report style shell scripts.

bb_counter_reset_many() {
  local counter_name
  for counter_name in "$@"; do
    local -n counter_ref="$counter_name"
    counter_ref=0
  done
}

bb_counter_inc() {
  local counter_name="$1"
  local -n counter_ref="$counter_name"
  counter_ref=$((counter_ref + 1))
}

bb_summary_print_header() {
  echo "Summary"
  echo "───────"
}

bb_summary_print_item() {
  local icon="$1"
  local label="$2"
  local value="$3"

  printf "  %s %-9s %s\n" "$icon" "$label:" "$value"
}

bb_json_field_or_default() {
  local payload="$1"
  local key="$2"
  local fallback="$3"
  local value=""

  if [ -z "$payload" ]; then
    echo "$fallback"
    return 0
  fi

  value="$(printf '%s' "$payload" | json_get_string_stdin "$key" 2>/dev/null || true)"
  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$fallback"
  fi
}

bb_pick_node_bin() {
  local preferred_bin="${1:-}"

  if [ -n "$preferred_bin" ] && [ -x "$preferred_bin" ]; then
    echo "$preferred_bin"
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi

  return 1
}

bb_run_node_check_payload() {
  local node_bin="${1:-}"
  local script_path="${2:-}"
  shift 2 || true

  if [ -z "$node_bin" ] || [ ! -x "$node_bin" ]; then
    return 0
  fi

  if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
    return 0
  fi

  "$node_bin" "$script_path" "$@" 2>/dev/null || true
}
