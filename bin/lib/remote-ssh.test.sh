#!/bin/bash
# Tests for bin/lib/remote-ssh.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/remote-ssh.sh
source "$SCRIPT_DIR/remote-ssh.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-remote-ssh-test-output.XXXXXX)"
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

with_mocked_ssh_tools() {
  local fail_until="${1:-0}"
  shift

  local tmp fakebin log_file count_file
  tmp="$(mktemp -d /tmp/baudbot-remote-ssh.XXXXXX)"
  fakebin="$tmp/fakebin"
  log_file="$tmp/log"
  count_file="$tmp/count"
  mkdir -p "$fakebin"

  cat > "$fakebin/ssh" <<'EOF_SSH'
#!/bin/bash
set -euo pipefail

count_file="${MOCK_SSH_COUNT_FILE}"
log_file="${MOCK_SSH_LOG}"
fail_until="${MOCK_SSH_FAIL_UNTIL:-0}"

count="0"
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"

echo "ssh $*" >> "$log_file"

if [ "$count" -le "$fail_until" ]; then
  exit 255
fi

exit 0
EOF_SSH

  cat > "$fakebin/scp" <<'EOF_SCP'
#!/bin/bash
set -euo pipefail
echo "scp $*" >> "${MOCK_SSH_LOG}"
exit 0
EOF_SCP

  chmod +x "$fakebin/ssh" "$fakebin/scp"

  local rc=0
  (
    set -euo pipefail
    export PATH="$fakebin:$PATH"
    hash -r
    export MOCK_SSH_LOG="$log_file"
    export MOCK_SSH_COUNT_FILE="$count_file"
    export MOCK_SSH_FAIL_UNTIL="$fail_until"
    export BAUDBOT_REMOTE_DIR="$tmp/state"
    "$@"
  ) || rc=$?

  rm -rf "$tmp"
  return "$rc"
}

test_ssh_exec_builds_expected_flags() {
  with_mocked_ssh_tools 0 _case_ssh_exec_flags
}

test_ssh_exec_tty_adds_tty_flag() {
  with_mocked_ssh_tools 0 _case_ssh_exec_tty
}

test_scp_wrappers_build_expected_targets() {
  with_mocked_ssh_tools 0 _case_scp_wrappers
}

test_wait_for_reachable_retries() {
  with_mocked_ssh_tools 2 _case_wait_retries
}

test_wait_for_reachable_timeout() {
  with_mocked_ssh_tools 10 _case_wait_timeout
}

_case_ssh_exec_flags() {
  set -euo pipefail
  remote_ssh_exec root 203.0.113.5 /tmp/key "echo hi"
  grep -q "StrictHostKeyChecking=accept-new" "$MOCK_SSH_LOG"
  grep -q "UserKnownHostsFile=$BAUDBOT_REMOTE_DIR/known_hosts" "$MOCK_SSH_LOG"
  grep -q -- "-i /tmp/key" "$MOCK_SSH_LOG"
  grep -q "root@203.0.113.5" "$MOCK_SSH_LOG"
}

_case_ssh_exec_tty() {
  set -euo pipefail
  remote_ssh_exec_tty root 203.0.113.5 /tmp/key "baudbot install"
  grep -q "ssh -tt" "$MOCK_SSH_LOG"
}

_case_scp_wrappers() {
  set -euo pipefail
  remote_scp_to root 203.0.113.5 /tmp/key /tmp/local /tmp/remote
  remote_scp_from root 203.0.113.5 /tmp/key /tmp/remote /tmp/local
  grep -q "scp .* /tmp/local root@203.0.113.5:/tmp/remote" "$MOCK_SSH_LOG"
  grep -q "scp .* root@203.0.113.5:/tmp/remote /tmp/local" "$MOCK_SSH_LOG"
}

_case_wait_retries() {
  set -euo pipefail
  remote_ssh_wait_for_reachable root 203.0.113.5 /tmp/key 5 0
  attempts="$(cat "$MOCK_SSH_COUNT_FILE")"
  [ "$attempts" = "3" ]
}

_case_wait_timeout() {
  set -euo pipefail
  if remote_ssh_wait_for_reachable root 203.0.113.5 /tmp/key 3 0; then
    exit 1
  fi
  attempts="$(cat "$MOCK_SSH_COUNT_FILE")"
  [ "$attempts" = "3" ]
}

echo "=== remote-ssh tests ==="
echo ""

run_test "ssh exec flags" test_ssh_exec_builds_expected_flags
run_test "ssh exec tty mode" test_ssh_exec_tty_adds_tty_flag
run_test "scp wrappers" test_scp_wrappers_build_expected_targets
run_test "wait retries until success" test_wait_for_reachable_retries
run_test "wait fails after timeout" test_wait_for_reachable_timeout

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
