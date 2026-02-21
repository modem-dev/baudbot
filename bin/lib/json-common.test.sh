#!/bin/bash
# Tests for bin/lib/json-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/json-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-json-common-test-output.XXXXXX)"
  if "$@" >"$out" 2>&1; then
    echo "✓"
    PASSED=$((PASSED + 1))
  else
    echo "✗ FAILED"
    tail -40 "$out" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
  rm -f "$out"
}

test_parses_string_key_with_whitespace_variations() {
  (
    set -euo pipefail
    local tmp file value
    tmp="$(mktemp -d /tmp/baudbot-json-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    file="$tmp/meta.json"
    cat > "$file" <<'EOF'
{
  "sha"   :    "abc123",
  "short": "abc123",
  "nested": { "x": 1 }
}
EOF

    value="$(json_get_string "$file" "sha")"
    [ "$value" = "abc123" ]
  )
}

test_missing_key_returns_nonzero() {
  (
    set -euo pipefail
    local tmp file
    tmp="$(mktemp -d /tmp/baudbot-json-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    file="$tmp/meta.json"
    printf '{"sha":"abc123"}\n' > "$file"

    if json_get_string "$file" "branch" >/dev/null 2>&1; then
      return 1
    fi

    [ -z "$(json_get_string_or_empty "$file" "branch")" ]
  )
}

test_malformed_json_returns_nonzero() {
  (
    set -euo pipefail
    local tmp file
    tmp="$(mktemp -d /tmp/baudbot-json-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    file="$tmp/bad.json"
    printf '{"sha": "abc123"\n' > "$file"

    if json_get_string "$file" "sha" >/dev/null 2>&1; then
      return 1
    fi
  )
}

test_stdin_parser_handles_whitespace() {
  (
    set -euo pipefail
    local value

    value="$(printf '{\n  "deployed_at" : "2026-02-21T20:00:00Z"\n}\n' | json_get_string_stdin "deployed_at")"
    [ "$value" = "2026-02-21T20:00:00Z" ]
  )
}

echo "=== json-common tests ==="
echo ""

run_test "parses string key with whitespace" test_parses_string_key_with_whitespace_variations
run_test "missing key returns nonzero" test_missing_key_returns_nonzero
run_test "malformed json returns nonzero" test_malformed_json_returns_nonzero
run_test "stdin parser handles whitespace" test_stdin_parser_handles_whitespace

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
