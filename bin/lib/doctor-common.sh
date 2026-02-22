#!/bin/bash
# Shared helpers for bin/doctor.sh

doctor_init_counters() {
  PASS=0
  FAIL=0
  WARN=0
}

doctor_pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

doctor_fail() {
  echo "  ✗ $1"
  FAIL=$((FAIL + 1))
}

doctor_warn() {
  echo "  ⚠ $1"
  WARN=$((WARN + 1))
}

doctor_summary_and_exit() {
  echo ""
  echo "────────────────────────────"
  echo "  $PASS passed, $FAIL failed, $WARN warnings"

  if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Fix failures before starting the agent."
    exit 1
  fi

  if [ "$WARN" -gt 0 ]; then
    echo ""
    echo "Warnings are non-blocking but should be reviewed."
    exit 0
  fi

  echo ""
  echo "All checks passed."
  exit 0
}
