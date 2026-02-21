#!/bin/bash
# Shared JSON parsing helpers for shell scripts.
#
# Return codes:
#   0 => key found and value printed
#   1 => JSON parsed, but key missing/non-string
#   2 => JSON/file/tool error

_json_filter='if (type == "object") and has($k) and (.[$k] | type == "string") then .[$k] else empty end'

json_get_string() {
  local file="$1"
  local key="$2"

  [ -n "$file" ] || return 2
  [ -n "$key" ] || return 2
  [ -r "$file" ] || return 2

  if command -v jq >/dev/null 2>&1; then
    jq -er --arg k "$key" "$_json_filter" "$file" 2>/dev/null
    case "$?" in
      0) return 0 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 2
  fi

  python3 - "$file" "$key" <<'PY'
import json
import sys

if len(sys.argv) != 3:
    sys.exit(2)

path = sys.argv[1]
key = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(2)

if not isinstance(data, dict):
    sys.exit(1)

value = data.get(key)
if not isinstance(value, str):
    sys.exit(1)

sys.stdout.write(value)
PY
}

json_get_string_stdin() {
  local key="$1"

  [ -n "$key" ] || return 2

  if command -v jq >/dev/null 2>&1; then
    jq -er --arg k "$key" "$_json_filter" 2>/dev/null
    case "$?" in
      0) return 0 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 2
  fi

  python3 - "$key" <<'PY'
import json
import sys

if len(sys.argv) != 2:
    sys.exit(2)

key = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)

if not isinstance(data, dict):
    sys.exit(1)

value = data.get(key)
if not isinstance(value, str):
    sys.exit(1)

sys.stdout.write(value)
PY
}

json_get_string_or_empty() {
  local file="$1"
  local key="$2"

  json_get_string "$file" "$key" 2>/dev/null || true
}
