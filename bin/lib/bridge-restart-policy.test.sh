#!/bin/bash
# Tests for bin/lib/bridge-restart-policy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/bridge-restart-policy.sh
source "$SCRIPT_DIR/bridge-restart-policy.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-bridge-restart-policy-test.XXXXXX)"
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

test_mode_defaults_to_legacy() {
  (
    set -euo pipefail
    unset BAUDBOT_BRIDGE_RESTART_POLICY
    unset BAUDBOT_BRIDGE_RESTART_BASE_DELAY_SECONDS
    unset BAUDBOT_BRIDGE_RESTART_MAX_DELAY_SECONDS
    unset BAUDBOT_BRIDGE_RESTART_STABLE_WINDOW_SECONDS
    unset BAUDBOT_BRIDGE_RESTART_MAX_CONSECUTIVE_FAILURES
    unset BAUDBOT_BRIDGE_RESTART_JITTER_SECONDS

    [ "$(bb_bridge_policy_mode)" = "legacy" ]
  )
}

test_mode_uses_explicit_policy_override() {
  (
    set -euo pipefail
    export BAUDBOT_BRIDGE_RESTART_POLICY="adaptive"
    [ "$(bb_bridge_policy_mode)" = "adaptive" ]

    export BAUDBOT_BRIDGE_RESTART_POLICY="legacy"
    [ "$(bb_bridge_policy_mode)" = "legacy" ]
  )
}

test_mode_enables_adaptive_when_policy_vars_set() {
  (
    set -euo pipefail
    unset BAUDBOT_BRIDGE_RESTART_POLICY
    export BAUDBOT_BRIDGE_RESTART_BASE_DELAY_SECONDS="7"

    [ "$(bb_bridge_policy_mode)" = "adaptive" ]
  )
}

test_int_parser_falls_back_for_invalid_values() {
  (
    set -euo pipefail
    [ "$(bb_bridge_policy_int "" 9)" = "9" ]
    [ "$(bb_bridge_policy_int "abc" 9)" = "9" ]
    [ "$(bb_bridge_policy_int "12" 9)" = "12" ]
  )
}

test_next_delay_doubles_and_caps() {
  (
    set -euo pipefail
    [ "$(bb_bridge_policy_compute_next_delay 5 30)" = "10" ]
    [ "$(bb_bridge_policy_compute_next_delay 20 30)" = "30" ]
  )
}

test_jitter_within_range() {
  (
    set -euo pipefail
    local i val
    for i in $(seq 1 50); do
      val="$(bb_bridge_policy_random_jitter 2)"
      [ "$val" -ge 0 ]
      [ "$val" -le 2 ]
    done
  )
}

echo "=== bridge-restart-policy tests ==="
echo ""

run_test "mode: defaults to legacy" test_mode_defaults_to_legacy
run_test "mode: explicit policy override" test_mode_uses_explicit_policy_override
run_test "mode: adaptive when vars set" test_mode_enables_adaptive_when_policy_vars_set
run_test "int parser: invalid values fallback" test_int_parser_falls_back_for_invalid_values
run_test "backoff: doubles and caps" test_next_delay_doubles_and_caps
run_test "jitter: bounded range" test_jitter_within_range

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
