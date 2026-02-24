#!/bin/bash
# Tests for bin/lib/check-report-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/json-common.sh"
# shellcheck source=bin/lib/check-report-common.sh
source "$SCRIPT_DIR/check-report-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-check-report-common-test-output.XXXXXX)"
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

test_reset_many_sets_zero() {
  (
    set -euo pipefail
    a=7
    b=3
    c=9
    bb_counter_reset_many a b c
    [ "$a" -eq 0 ]
    [ "$b" -eq 0 ]
    [ "$c" -eq 0 ]
  )
}

test_inc_increments_named_counter() {
  (
    set -euo pipefail
    value=0
    bb_counter_inc value
    bb_counter_inc value
    [ "$value" -eq 2 ]
  )
}

test_summary_helpers_render_rows() {
  (
    set -euo pipefail
    local out
    out="$(mktemp /tmp/check-report-summary.XXXXXX)"
    trap 'rm -f "$out"' EXIT

    {
      bb_summary_print_header
      bb_summary_print_item "✅" "Pass" "3"
    } >"$out"

    grep -q '^Summary$' "$out"
    grep -q '✅ Pass:' "$out"
  )
}

test_json_field_or_default_reads_existing_key() {
  (
    set -euo pipefail
    payload='{"status":"pass"}'
    [ "$(bb_json_field_or_default "$payload" status unknown)" = "pass" ]
  )
}

test_json_field_or_default_falls_back_when_missing() {
  (
    set -euo pipefail
    payload='{"exists":"1"}'
    [ "$(bb_json_field_or_default "$payload" status unknown)" = "unknown" ]
  )
}

test_pick_node_bin_uses_preferred() {
  (
    set -euo pipefail
    fake_node="$(command -v node)"
    [ -n "$(bb_pick_node_bin "$fake_node")" ]
  )
}

test_run_node_check_payload_executes_script() {
  (
    set -euo pipefail
    tmp_script="$(mktemp /tmp/check-report-node-check.XXXXXX.mjs)"
    trap 'rm -f "$tmp_script"' EXIT

    cat >"$tmp_script" <<'EOF'
#!/usr/bin/env node
process.stdout.write(JSON.stringify({ ok: "1" }));
EOF
    chmod +x "$tmp_script"

    output="$(bb_run_node_check_payload "$(command -v node)" "$tmp_script")"
    [ "$(bb_json_field_or_default "$output" ok 0)" = "1" ]
  )
}

echo "=== check-report-common tests ==="
echo ""

run_test "reset many sets counters to zero" test_reset_many_sets_zero
run_test "increment updates named counter" test_inc_increments_named_counter
run_test "summary helpers render rows" test_summary_helpers_render_rows
run_test "json field helper reads key" test_json_field_or_default_reads_existing_key
run_test "json field helper falls back when missing" test_json_field_or_default_falls_back_when_missing
run_test "node picker prefers runtime path" test_pick_node_bin_uses_preferred
run_test "node check runner executes script" test_run_node_check_payload_executes_script

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
