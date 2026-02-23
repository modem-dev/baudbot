#!/bin/bash
# Shared helpers for bin/doctor.sh

BB_DOCTOR_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/check-report-common.sh
source "$BB_DOCTOR_COMMON_DIR/check-report-common.sh"

doctor_init_counters() {
  bb_counter_reset_many PASS FAIL WARN
}

doctor_pass() {
  echo "  ✓ $1"
  bb_counter_inc PASS
}

doctor_fail() {
  echo "  ✗ $1"
  bb_counter_inc FAIL
}

doctor_warn() {
  echo "  ⚠ $1"
  bb_counter_inc WARN
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
