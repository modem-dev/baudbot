#!/bin/bash
# Tests for bin/lib/remote-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/remote-common.sh
source "$SCRIPT_DIR/remote-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-remote-common-test-output.XXXXXX)"
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

state_setup() {
  export BAUDBOT_REMOTE_DIR
  BAUDBOT_REMOTE_DIR="$(mktemp -d /tmp/baudbot-remote-common.XXXXXX)"
}

state_teardown() {
  rm -rf "$BAUDBOT_REMOTE_DIR"
  unset BAUDBOT_REMOTE_DIR
}

test_target_name_validation() {
  (
    set -euo pipefail
    remote_validate_target_name "valid-name-1"
    ! remote_validate_target_name ""
    ! remote_validate_target_name "UPPERCASE"
    ! remote_validate_target_name "bad_name"
  )
}

test_state_init_and_fields() {
  (
    set -euo pipefail
    state_setup
    trap state_teardown EXIT

    remote_state_init "demo-target" "host" "203.0.113.9" "root" "$BAUDBOT_REMOTE_DIR/key" "none" "" "" ""

    [ "$(remote_state_get_field "demo-target" '.name')" = "demo-target" ]
    [ "$(remote_state_get_field "demo-target" '.mode')" = "host" ]
    [ "$(remote_state_get_field "demo-target" '.host')" = "203.0.113.9" ]
    [ "$(remote_state_get_field "demo-target" '.status')" = "initialized" ]
  )
}

test_checkpoint_progression() {
  (
    set -euo pipefail
    state_setup
    trap state_teardown EXIT

    remote_state_init "demo-target" "host" "" "root" "$BAUDBOT_REMOTE_DIR/key" "none" "" "" ""

    [ "$(remote_next_install_checkpoint "demo-target" "host")" = "target_selected" ]

    remote_checkpoint_mark_complete "demo-target" "target_selected" 0
    [ "$(remote_next_install_checkpoint "demo-target" "host")" = "ssh_key_ready" ]

    remote_checkpoint_set_retry "demo-target" "ssh_key_ready" 2
    [ "$(remote_checkpoint_retry_count "demo-target" "ssh_key_ready")" = "2" ]

    remote_checkpoint_mark_complete "demo-target" "ssh_key_ready" 2
    [ "$(remote_next_install_checkpoint "demo-target" "host")" = "ssh_reachable" ]
  )
}

test_checkpoint_order_includes_tailscale() {
  (
    set -euo pipefail
    local host_order hetzner_order
    host_order="$(remote_install_checkpoint_order "host")"
    hetzner_order="$(remote_install_checkpoint_order "hetzner")"

    printf '%s\n' "$host_order" | grep -q '^tailscale_connected$'
    printf '%s\n' "$hetzner_order" | grep -q '^tailscale_connected$'
  )
}

test_reset_install_progress() {
  (
    set -euo pipefail
    state_setup
    trap state_teardown EXIT

    remote_state_init "demo-target" "host" "" "root" "$BAUDBOT_REMOTE_DIR/key" "none" "" "" ""
    remote_checkpoint_mark_complete "demo-target" "target_selected" 0
    remote_state_set_status "demo-target" "failed"
    remote_state_set_last_error "demo-target" "boom"

    remote_reset_install_progress "demo-target"

    [ "$(remote_state_get_field "demo-target" '.status')" = "initialized" ]
    [ -z "$(remote_state_get_field "demo-target" '.last_error')" ]
    [ "$(remote_next_install_checkpoint "demo-target" "host")" = "target_selected" ]
  )
}

test_ensure_local_ssh_key_generates_pair() {
  (
    set -euo pipefail
    state_setup
    trap state_teardown EXIT

    local key_path
    key_path="$BAUDBOT_REMOTE_DIR/keys/test-key"

    generated="$(remote_ensure_local_ssh_key "$key_path" "remote-common-test" 1)"
    [ "$generated" = "$key_path" ]
    [ -f "$key_path" ]
    [ -f "${key_path}.pub" ]

    reused="$(remote_ensure_local_ssh_key "$key_path" "remote-common-test" 1)"
    [ "$reused" = "$key_path" ]
  )
}

echo "=== remote-common tests ==="
echo ""

run_test "target name validation" test_target_name_validation
run_test "state init and fields" test_state_init_and_fields
run_test "checkpoint progression" test_checkpoint_progression
run_test "checkpoint order includes tailscale" test_checkpoint_order_includes_tailscale
run_test "reset install progress" test_reset_install_progress
run_test "ssh key generation" test_ensure_local_ssh_key_generates_pair

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
