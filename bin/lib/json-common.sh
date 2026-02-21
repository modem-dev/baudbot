#!/bin/bash
# Shared JSON parsing helpers for shell scripts.
#
# jq is a required runtime dependency.
#
# Return codes:
#   0 => key found and value printed
#   1 => JSON parsed, but key missing/non-string
#   2 => JSON/file/tool error (including missing jq)

_json_filter='if (type == "object") and has($k) and (.[$k] | type == "string") then .[$k] else empty end'

json_require_jq() {
  command -v jq >/dev/null 2>&1
}

json_get_string() {
  local file="$1"
  local key="$2"

  [ -n "$file" ] || return 2
  [ -n "$key" ] || return 2
  [ -r "$file" ] || return 2
  json_require_jq || return 2

  jq -er --arg k "$key" "$_json_filter" "$file" 2>/dev/null
  case "$?" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

json_get_string_stdin() {
  local key="$1"

  [ -n "$key" ] || return 2
  json_require_jq || return 2

  jq -er --arg k "$key" "$_json_filter" 2>/dev/null
  case "$?" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

json_get_string_or_empty() {
  local file="$1"
  local key="$2"

  json_get_string "$file" "$key" 2>/dev/null || true
}
