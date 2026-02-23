#!/bin/bash
# Tests for bin/lib/shell-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/shell-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-shell-common-test-output.XXXXXX)"
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

test_has_arg_detects_present() {
  (
    set -euo pipefail
    bb_has_arg "--flag" "--foo" "--flag" "--bar"
  )
}

test_has_arg_returns_not_found() {
  (
    set -euo pipefail
    if bb_has_arg "--missing" "--foo" "--bar"; then
      return 1
    fi
  )
}

test_require_option_value_allows_value() {
  (
    set -euo pipefail
    bb_require_option_value "--repo" 2
  )
}

test_require_option_value_fails_without_value() {
  (
    set -euo pipefail
    local out
    out="$(mktemp /tmp/shell-common-require-option.XXXXXX)"
    trap 'rm -f "$out"' EXIT

    set +e
    bash -c '
      source "$1"
      bb_require_option_value "--repo" 1
    ' _ "$SCRIPT_DIR/shell-common.sh" >"$out" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -q -- "--repo requires a value" "$out"
  )
}

echo "=== shell-common tests ==="
echo ""

run_test "has_arg detects present value" test_has_arg_detects_present
run_test "has_arg returns not found" test_has_arg_returns_not_found
run_test "require_option_value allows value" test_require_option_value_allows_value
run_test "require_option_value fails when missing" test_require_option_value_fails_without_value

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
