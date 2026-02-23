#!/bin/bash
# Smoke-test high-value baudbot CLI flows in droplet CI.
# Intended to run as root after `baudbot install` completes.

set -euo pipefail

TOTAL=0
PASSED=0
FAILED=0

run_expect() {
  local name="$1"
  local timeout_seconds="$2"
  local expected_csv="$3"
  shift 3

  TOTAL=$((TOTAL + 1))
  printf "  %-44s " "$name"

  local out rc=0
  out="$(mktemp /tmp/baudbot-smoke.XXXXXX)"

  if [ "$timeout_seconds" -gt 0 ]; then
    timeout "$timeout_seconds" "$@" >"$out" 2>&1 || rc=$?
  else
    "$@" >"$out" 2>&1 || rc=$?
  fi

  local expected_ok=1 expected
  IFS=',' read -r -a expected <<< "$expected_csv"
  expected_ok=0
  for code in "${expected[@]}"; do
    if [ "$rc" -eq "$code" ]; then
      expected_ok=1
      break
    fi
  done

  if [ "$expected_ok" -eq 1 ]; then
    echo "✓"
    PASSED=$((PASSED + 1))
  else
    echo "✗ FAILED (exit $rc, expected $expected_csv)"
    tail -40 "$out" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi

  rm -f "$out"
}

echo "=== CLI smoke checks ==="

# Basic dispatcher/help paths.
run_expect "baudbot --version" 15 0 baudbot --version
run_expect "baudbot --help" 15 0 baudbot --help
run_expect "baudbot env --help" 15 0 baudbot env --help

# Always-on PR CI flows.
run_expect "sudo baudbot start" 60 0 sudo baudbot start
run_expect "sudo baudbot status" 30 0 sudo baudbot status
run_expect "sudo baudbot sessions" 30 0 sudo baudbot sessions
run_expect "sudo baudbot logs (timeout expected)" 8 124 sudo baudbot logs
run_expect "sudo baudbot doctor" 60 0 sudo baudbot doctor
# audit can legitimately return 1 (warn) or 2 (critical) while still proving command execution.
run_expect "sudo baudbot audit --deep" 90 0,1,2 sudo baudbot audit --deep
run_expect "sudo baudbot restart" 60 0 sudo baudbot restart
run_expect "sudo baudbot stop" 60 0 sudo baudbot stop
run_expect "sudo baudbot start (again)" 60 0 sudo baudbot start
run_expect "sudo baudbot uninstall --dry-run" 60 0 sudo baudbot uninstall --dry-run

echo ""
echo "=== CLI smoke checks: $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
