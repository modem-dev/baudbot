#!/bin/bash
# Tests for bin/lib/release-runtime-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/release-runtime-common.sh
source "$SCRIPT_DIR/release-runtime-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-release-runtime-common-test-output.XXXXXX)"
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

TEST_LOGS=()
RESTART_CALLS=0

log() {
  TEST_LOGS+=("$*")
}

die() {
  echo "die:$*" >&2
  exit 1
}

restart_baudbot_service_if_active() {
  RESTART_CALLS=$((RESTART_CALLS + 1))
}

json_get_string_stdin() {
  local _key="$1"
  cat
}

reset_state() {
  TEST_LOGS=()
  RESTART_CALLS=0
}

test_restart_override_failure_does_not_fallback() {
  (
    set -euo pipefail
    reset_state
    local hook_env=("X_TEST=1")

    set +e
    bb_run_release_restart_and_health "false" "0" "" hook_env
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    [ "$RESTART_CALLS" -eq 0 ]
  )
}

test_no_restart_override_uses_default_restart() {
  (
    set -euo pipefail
    reset_state
    local hook_env=()

    bb_run_release_restart_and_health "" "0" "" hook_env
    [ "$RESTART_CALLS" -eq 1 ]
  )
}

test_skip_restart_logs_and_does_not_restart() {
  (
    set -euo pipefail
    reset_state
    local hook_env=()

    bb_run_release_restart_and_health "" "1" "" hook_env
    [ "$RESTART_CALLS" -eq 0 ]
  )
}

test_health_override_failure_propagates() {
  (
    set -euo pipefail
    reset_state
    local hook_env=("X_TEST=1")

    set +e
    bb_run_release_restart_and_health "" "1" "false" hook_env
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
  )
}

echo "=== release-runtime-common tests ==="
echo ""

run_test "restart override failure does not fallback" test_restart_override_failure_does_not_fallback
run_test "default restart runs without override" test_no_restart_override_uses_default_restart
run_test "skip restart avoids default restart" test_skip_restart_logs_and_does_not_restart
run_test "health override failure propagates" test_health_override_failure_propagates

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
