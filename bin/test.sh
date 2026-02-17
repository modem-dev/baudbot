#!/bin/bash
# Run all Baudbot tests. Exit code reflects overall pass/fail.
#
# Usage:
#   bin/test.sh           # run all tests
#   bin/test.sh js        # only JS/TS tests
#   bin/test.sh shell     # only shell tests
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

echo "=== Baudbot Tests ==="
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
  run "safe-bash wrapper" bash bin/baudbot-safe-bash.test.sh
  run "log redaction"     bash bin/redact-logs.test.sh
  echo ""
fi

echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
