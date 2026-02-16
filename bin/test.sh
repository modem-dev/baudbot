#!/bin/bash
# Run all Hornet tests. Exit code reflects overall pass/fail.
#
# Usage:
#   bin/test.sh           # run all tests
#   bin/test.sh js        # only JS/TS tests
#   bin/test.sh shell     # only shell tests
#
# Add new test files here — don't scatter test invocations across CI/docs.

set -uo pipefail
cd "$(dirname "$0")/.."

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
    count=$(echo "$output" | grep -oP '(?<=ℹ pass )\d+' | tail -1)
    if [ -z "$count" ]; then
      count=$(echo "$output" | grep -oP '\d+(?= passed)' | tail -1)
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

echo "=== Hornet Tests ==="
echo ""

if [ "$FILTER" = "all" ] || [ "$FILTER" = "js" ]; then
  echo "JS/TS:"
  run "tool-guard"        node --test pi/extensions/tool-guard.test.mjs
  run "bridge security"   node --test slack-bridge/security.test.mjs
  run "extension scanner" node --test bin/scan-extensions.test.mjs
  echo ""
fi

if [ "$FILTER" = "all" ] || [ "$FILTER" = "shell" ]; then
  echo "Shell:"
  run "safe-bash wrapper" bash bin/hornet-safe-bash.test.sh
  run "log redaction"     bash bin/redact-logs.test.sh
  echo ""
fi

echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
