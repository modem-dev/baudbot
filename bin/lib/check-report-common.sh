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
