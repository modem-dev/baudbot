#!/bin/bash
# Tests for bin/lib/varlock-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/varlock-common.sh
source "$SCRIPT_DIR/varlock-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-50s " "$name"

  out="$(mktemp /tmp/baudbot-varlock-common-test-output.XXXXXX)"
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

test_pinned_version_default() {
  (
    set -euo pipefail
    unset BAUDBOT_VARLOCK_VERSION
    [ "$(bb_varlock_pinned_version)" = "1.7.1" ]
  )
}

test_pinned_version_env_override() {
  (
    set -euo pipefail
    BAUDBOT_VARLOCK_VERSION="9.9.9"
    [ "$(bb_varlock_pinned_version)" = "9.9.9" ]
  )
}

test_needs_install_when_missing() {
  ( set -euo pipefail; bb_varlock_needs_install "" "1.7.1" )
}

test_needs_install_when_mismatched() {
  ( set -euo pipefail; bb_varlock_needs_install "1.0.0" "1.7.1" )
}

test_no_install_when_matched() {
  ( set -euo pipefail; ! bb_varlock_needs_install "1.7.1" "1.7.1" )
}

test_telemetry_disabled_true() {
  (
    set -euo pipefail
    local tmp; tmp="$(mktemp -d /tmp/baudbot-varlock.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    printf '{\n  "anonymousId": "abc",\n  "telemetryDisabled": true\n}\n' > "$tmp/config.json"
    bb_varlock_telemetry_disabled "$tmp/config.json"
  )
}

test_telemetry_not_disabled_when_only_anonymous_id() {
  (
    set -euo pipefail
    local tmp; tmp="$(mktemp -d /tmp/baudbot-varlock.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    # The pre-fix false-positive case: anonymousId present, no disable flag.
    printf '{\n  "anonymousId": "abc"\n}\n' > "$tmp/config.json"
    ! bb_varlock_telemetry_disabled "$tmp/config.json"
  )
}

test_telemetry_not_disabled_when_missing_file() {
  ( set -euo pipefail; ! bb_varlock_telemetry_disabled "/nonexistent/config.json" )
}

echo "=== varlock-common tests ==="
echo ""

run_test "pinned version default (1.7.1)"          test_pinned_version_default
run_test "pinned version env override"             test_pinned_version_env_override
run_test "needs install when missing"              test_needs_install_when_missing
run_test "needs install when version mismatched"   test_needs_install_when_mismatched
run_test "no install when version matched"         test_no_install_when_matched
run_test "telemetry disabled flag detected"        test_telemetry_disabled_true
run_test "anonymousId alone is not 'disabled'"     test_telemetry_not_disabled_when_only_anonymous_id
run_test "missing config is not 'disabled'"        test_telemetry_not_disabled_when_missing_file

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
