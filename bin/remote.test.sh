#!/bin/bash
# Tests for bin/remote.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_CLI="$REPO_ROOT/bin/remote.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-remote-cli-test-output.XXXXXX)"
  if "$@" >"$out" 2>&1; then
    echo "✓"
    PASSED=$((PASSED + 1))
  else
    echo "✗ FAILED"
    tail -60 "$out" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
  rm -f "$out"
}

with_state_dir() {
  local tmp
  tmp="$(mktemp -d /tmp/baudbot-remote-cli.XXXXXX)"
  local rc=0
  (
    set -euo pipefail
    export BAUDBOT_REMOTE_DIR="$tmp"
    "$@"
  ) || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_install_requires_mode_non_interactive() {
  with_state_dir bash -c '
    set -euo pipefail
    if bash "$0" install --target demo >/tmp/baudbot-remote-missing-mode.out 2>&1; then
      exit 1
    fi
    grep -q -- "--mode is required" /tmp/baudbot-remote-missing-mode.out
    rm -f /tmp/baudbot-remote-missing-mode.out
  ' "$REMOTE_CLI"
}

test_install_host_dry_run_completes() {
  with_state_dir bash -c '
    set -euo pipefail
    bash "$0" install --mode host --target demo --host 198.51.100.10 --dry-run

    state_file="$BAUDBOT_REMOTE_DIR/targets/demo.json"
    [ -f "$state_file" ]
    [ "$(jq -r ".status" "$state_file")" = "ready" ]
    [ "$(jq -r ".mode" "$state_file")" = "host" ]
    [ "$(jq -r ".host" "$state_file")" = "198.51.100.10" ]
    [ "$(jq -r ".tailscale.enabled" "$state_file")" = "false" ]

    status_out="$(bash "$0" status demo)"
    next="$(printf "%s\n" "$status_out" | awk -F": " "/Next checkpoint/ {print \$2}")"
    [ "$next" = "completed" ]
    printf "%s\n" "$status_out" | grep -q "Tailscale:       false"
    printf "%s\n" "$status_out" | grep -q "tailscale_connected.*done"
  ' "$REMOTE_CLI"
}

test_resume_missing_target_fails() {
  with_state_dir bash -c '
    set -euo pipefail
    if bash "$0" resume missing-target >/tmp/baudbot-remote-resume-missing.out 2>&1; then
      exit 1
    fi
    grep -q "not found" /tmp/baudbot-remote-resume-missing.out
    rm -f /tmp/baudbot-remote-resume-missing.out
  ' "$REMOTE_CLI"
}

test_resume_existing_target_uses_saved_mode() {
  with_state_dir bash -c '
    set -euo pipefail
    bash "$0" install --mode host --target demo --host 198.51.100.10 --dry-run >/dev/null

    state_file="$BAUDBOT_REMOTE_DIR/targets/demo.json"
    tmp_file="$(mktemp /tmp/baudbot-remote-resume-state.XXXXXX)"
    jq ".checkpoints = [] | .status = \"failed\" | .last_error = \"interrupted\"" "$state_file" > "$tmp_file"
    mv "$tmp_file" "$state_file"

    bash "$0" resume demo --dry-run >/dev/null
    [ "$(jq -r ".status" "$state_file")" = "ready" ]
    [ "$(jq -r ".mode" "$state_file")" = "host" ]
  ' "$REMOTE_CLI"
}

test_list_and_status_output() {
  with_state_dir bash -c '
    set -euo pipefail
    bash "$0" install --mode host --target demo --host 198.51.100.10 --dry-run >/dev/null

    list_out="$(bash "$0" list)"
    status_out="$(bash "$0" status demo)"

    printf "%s\n" "$list_out" | grep -q "demo"
    printf "%s\n" "$status_out" | grep -q "Status:          ready"
  ' "$REMOTE_CLI"
}

test_repair_non_interactive_safe_dry_run() {
  with_state_dir bash -c '
    set -euo pipefail
    bash "$0" install --mode host --target demo --host 198.51.100.10 --dry-run >/dev/null
    bash "$0" repair --target demo --non-interactive-safe --dry-run >/tmp/baudbot-remote-repair.out

    state_file="$BAUDBOT_REMOTE_DIR/targets/demo.json"
    [ "$(jq -r ".status" "$state_file")" = "ready" ]
    grep -q "Repair Summary" /tmp/baudbot-remote-repair.out
    rm -f /tmp/baudbot-remote-repair.out
  ' "$REMOTE_CLI"
}

echo "=== remote cli tests ==="
echo ""

run_test "install requires mode in non-interactive" test_install_requires_mode_non_interactive
run_test "host install dry-run completes" test_install_host_dry_run_completes
run_test "resume missing target fails" test_resume_missing_target_fails
run_test "resume existing target uses saved mode" test_resume_existing_target_uses_saved_mode
run_test "list and status show target" test_list_and_status_output
run_test "repair safe dry-run" test_repair_non_interactive_safe_dry_run

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
