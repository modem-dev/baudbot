#!/bin/bash
# Run all Baudbot tests. Exit code reflects overall pass/fail.
#
# Usage:
#   bin/test.sh                # run all tests
#   bin/test.sh js             # only JS/TS tests
#   bin/test.sh shell          # only shell tests
#   bin/test.sh coverage       # JS tests with coverage report + thresholds
#
# Add new test files here — don't scatter test invocations across CI/docs.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FILTER="${1:-all}"
FAILED=0
PASSED=0
TOTAL=0

run() {
  local name="$1"
  shift
  TOTAL=$((TOTAL + 1))
  printf "  %-40s " "$name"
  local output=""
  local rc=0
  output=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Extract test count if available
    count=$(echo "$output" | awk '/ℹ pass [0-9]/ {for(i=1;i<=NF;i++) if($i=="pass") print $(i+1)}' | tail -1)
    if [ -z "$count" ]; then
      count=$(echo "$output" | awk '/[0-9]+ passed/ {for(i=1;i<=NF;i++) if($(i+1)=="passed," || $(i+1)=="passed") print $i}' | tail -1)
    fi
    if [ -n "$count" ]; then
      echo "✓ ($count tests)"
    else
      echo "✓"
    fi
    PASSED=$((PASSED + 1))
  else
    echo "✗ FAILED (exit $rc)"
    echo "$output" | tail -20 | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
}

# ── JS test file list (used for both normal runs and coverage) ───────────
JS_TEST_FILES=(
  pi/extensions/tool-guard.test.mjs
  pi/extensions/heartbeat.test.mjs
  pi/extensions/memory.test.mjs
  slack-bridge/security.test.mjs
  bin/scan-extensions.test.mjs
  bin/broker-register.test.mjs
  control-plane/server.test.mjs
)

JS_TEST_NAMES=(
  "tool-guard"
  "heartbeat"
  "memory"
  "bridge security"
  "extension scanner"
  "broker register"
  "control-plane"
)

run_js_tests() {
  echo "JS/TS:"
  for i in "${!JS_TEST_FILES[@]}"; do
    run "${JS_TEST_NAMES[$i]}" node --test "${JS_TEST_FILES[$i]}"
  done
  echo ""
}

run_shell_tests() {
  echo "Shell:"
  run "safe-bash wrapper"   bash bin/baudbot-safe-bash.test.sh
  run "log redaction"       bash bin/redact-logs.test.sh
  run "log pruning"         bash bin/prune-session-logs.test.sh
  run "update release flow" bash bin/update-release.test.sh
  run "rollback release"    bash bin/rollback-release.test.sh
  echo ""
}

# ── Coverage mode ────────────────────────────────────────────────────────
if [ "$FILTER" = "coverage" ]; then
  echo "=== Baudbot Tests (with coverage) ==="
  echo ""

  if ! command -v npx &>/dev/null; then
    echo "Error: npx not found — install Node.js" >&2
    exit 1
  fi

  npx c8 node --test "${JS_TEST_FILES[@]}"
  exit $?
fi

# ── Normal mode ──────────────────────────────────────────────────────────
echo "=== Baudbot Tests ==="
echo ""

if [ "$FILTER" = "all" ] || [ "$FILTER" = "js" ]; then
  run_js_tests
fi

if [ "$FILTER" = "all" ] || [ "$FILTER" = "shell" ]; then
  run_shell_tests
fi

echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
