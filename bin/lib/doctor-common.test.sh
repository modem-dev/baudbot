#!/bin/bash
# Tests for bin/lib/doctor-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/doctor-common.sh
source "$SCRIPT_DIR/doctor-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-doctor-common-test-output.XXXXXX)"
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

test_init_sets_zero_counters() {
  (
    set -euo pipefail
    PASS=7
    FAIL=3
    WARN=9
    doctor_init_counters
    [ "$PASS" -eq 0 ]
    [ "$FAIL" -eq 0 ]
    [ "$WARN" -eq 0 ]
  )
}

test_pass_fail_warn_increment_counters() {
  (
    set -euo pipefail
    doctor_init_counters
    doctor_pass "one" >/dev/null
    doctor_fail "two" >/dev/null
    doctor_warn "three" >/dev/null
    [ "$PASS" -eq 1 ]
    [ "$FAIL" -eq 1 ]
    [ "$WARN" -eq 1 ]
  )
}

test_summary_exits_one_when_failures_present() {
  (
    set -euo pipefail
    local out
    out="$(mktemp /tmp/doctor-summary-fail.XXXXXX)"
    trap 'rm -f "$out"' EXIT

    set +e
    (
      doctor_init_counters
      FAIL=1
      doctor_summary_and_exit
    ) >"$out" 2>&1
    exit_code=$?
    set -e

    [ "$exit_code" -eq 1 ]
    grep -q "Fix failures before starting the agent." "$out"
  )
}

test_summary_exits_zero_with_warnings_only() {
  (
    set -euo pipefail
    local out
    out="$(mktemp /tmp/doctor-summary-warn.XXXXXX)"
    trap 'rm -f "$out"' EXIT

    set +e
    (
      doctor_init_counters
      WARN=2
      doctor_summary_and_exit
    ) >"$out" 2>&1
    exit_code=$?
    set -e

    [ "$exit_code" -eq 0 ]
    grep -q "Warnings are non-blocking" "$out"
  )
}

test_summary_exits_zero_when_all_clear() {
  (
    set -euo pipefail
    local out
    out="$(mktemp /tmp/doctor-summary-pass.XXXXXX)"
    trap 'rm -f "$out"' EXIT

    set +e
    (
      doctor_init_counters
      doctor_summary_and_exit
    ) >"$out" 2>&1
    exit_code=$?
    set -e

    [ "$exit_code" -eq 0 ]
    grep -q "All checks passed." "$out"
  )
}

echo "=== doctor-common tests ==="
echo ""

run_test "init sets counters to zero" test_init_sets_zero_counters
run_test "pass/fail/warn increment counters" test_pass_fail_warn_increment_counters
run_test "summary exits 1 on failures" test_summary_exits_one_when_failures_present
run_test "summary exits 0 on warnings" test_summary_exits_zero_with_warnings_only
run_test "summary exits 0 when all clear" test_summary_exits_zero_when_all_clear

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
