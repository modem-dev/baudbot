#!/bin/bash
# Tests for security-audit.sh
#
# Creates a mock hornet_agent home directory and verifies the audit
# reports correct findings for various configurations.
#
# Run: bash security-audit.test.sh

set -euo pipefail

SCRIPT="$(dirname "$0")/security-audit.sh"
PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

setup_base() {
  local home="$1"
  rm -rf "$home"
  mkdir -p "$home/.config" "$home/.ssh" "$home/.pi" "$home/hornet/slack-bridge" "$home/hornet/.git"

  # Secrets file
  echo "SLACK_BOT_TOKEN=xoxb-test" > "$home/.config/.env"
  chmod 600 "$home/.config/.env"

  # SSH
  chmod 700 "$home/.ssh"

  # Pi state
  chmod 700 "$home/.pi"

  # Gitignore
  echo ".env" > "$home/hornet/.gitignore"

  # Gitconfig (clean)
  echo -e "[user]\n\tname = test\n\temail = test@test.com" > "$home/.gitconfig"

  # Bridge security module
  echo "// security" > "$home/hornet/slack-bridge/security.mjs"
  echo "// tests" > "$home/hornet/slack-bridge/security.test.mjs"
}

run_audit() {
  local home="$1"
  shift
  HORNET_HOME="$home" bash "$SCRIPT" "$@" 2>&1 || true
}

expect_contains() {
  local desc="$1"
  local output="$2"
  local pattern="$3"

  if echo "$output" | grep -qF "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        expected to find: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

expect_not_contains() {
  local desc="$1"
  local output="$2"
  local pattern="$3"

  if echo "$output" | grep -qF "$pattern"; then
    echo "  FAIL: $desc"
    echo "        should NOT contain: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

echo ""
echo "Testing security-audit.sh"
echo "========================="
echo ""

# ── Test 1: Clean config ─────────────────────────────────────────────────────

echo "Test: clean base config"
HOME1="$TMPDIR/clean"
setup_base "$HOME1"
# Add SLACK_ALLOWED_USERS so bridge config check passes
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME1/.config/.env"

output=$(run_audit "$HOME1")
expect_contains "reports secrets file pass" "$output" "Secrets file (600)"
expect_contains "reports SSH dir pass" "$output" "SSH directory (700)"
expect_contains "reports pi state pass" "$output" "Pi state directory (700)"
expect_contains "reports no credentials in gitconfig" "$output" "No credentials in .gitconfig"
expect_contains "reports gitignore covers .env" "$output" ".gitignore excludes .env"
expect_contains "reports bridge security module" "$output" "Bridge security module exists"
expect_contains "reports bridge tests exist" "$output" "Bridge security tests exist"
expect_contains "reports SLACK_ALLOWED_USERS configured" "$output" "SLACK_ALLOWED_USERS configured"

echo ""

# ── Test 2: Secrets file too open ─────────────────────────────────────────────

echo "Test: secrets file world-readable"
HOME2="$TMPDIR/open-secrets"
setup_base "$HOME2"
chmod 644 "$HOME2/.config/.env"

output=$(run_audit "$HOME2")
expect_contains "reports secrets file wrong perms" "$output" "Secrets file is 644"

echo ""

# ── Test 3: Missing SLACK_ALLOWED_USERS ───────────────────────────────────────

echo "Test: missing SLACK_ALLOWED_USERS"
HOME3="$TMPDIR/no-allowed"
setup_base "$HOME3"
# .env has no SLACK_ALLOWED_USERS

output=$(run_audit "$HOME3")
expect_contains "reports missing SLACK_ALLOWED_USERS" "$output" "SLACK_ALLOWED_USERS not set"

echo ""

# ── Test 4: Empty SLACK_ALLOWED_USERS ─────────────────────────────────────────

echo "Test: empty SLACK_ALLOWED_USERS"
HOME4="$TMPDIR/empty-allowed"
setup_base "$HOME4"
echo "SLACK_ALLOWED_USERS=" >> "$HOME4/.config/.env"

output=$(run_audit "$HOME4")
expect_contains "reports empty SLACK_ALLOWED_USERS" "$output" "SLACK_ALLOWED_USERS is empty"

echo ""

# ── Test 5: Stale .env file ──────────────────────────────────────────────────

echo "Test: stale .env outside .config"
HOME5="$TMPDIR/stale-env"
setup_base "$HOME5"
echo "SECRET=oops" > "$HOME5/hornet/.env"

output=$(run_audit "$HOME5")
expect_contains "reports stale .env" "$output" "Found .env file"

echo ""

# ── Test 6: Credentials in gitconfig ──────────────────────────────────────────

echo "Test: credentials in gitconfig"
HOME6="$TMPDIR/gitconfig-creds"
setup_base "$HOME6"
echo -e "[credential]\n\thelper = store\n\ttoken = ghp_abc123" > "$HOME6/.gitconfig"

output=$(run_audit "$HOME6")
expect_contains "reports credentials in gitconfig" "$output" "Possible credentials in .gitconfig"

echo ""

# ── Test 7: Missing .gitignore ────────────────────────────────────────────────

echo "Test: missing .gitignore"
HOME7="$TMPDIR/no-gitignore"
setup_base "$HOME7"
rm -f "$HOME7/hornet/.gitignore"

output=$(run_audit "$HOME7")
expect_contains "reports no gitignore" "$output" "No .gitignore found"

echo ""

# ── Test 8: Missing bridge security module ────────────────────────────────────

echo "Test: missing bridge security module"
HOME8="$TMPDIR/no-bridge-sec"
setup_base "$HOME8"
rm -f "$HOME8/hornet/slack-bridge/security.mjs"

output=$(run_audit "$HOME8")
expect_contains "reports missing security module" "$output" "Bridge security module not found"

echo ""

# ── Test 9: Missing bridge tests ──────────────────────────────────────────────

echo "Test: missing bridge tests"
HOME9="$TMPDIR/no-bridge-tests"
setup_base "$HOME9"
rm -f "$HOME9/hornet/slack-bridge/security.test.mjs"

output=$(run_audit "$HOME9")
expect_contains "reports missing tests" "$output" "No tests for bridge security"

echo ""

# ── Test 10: Summary counts ──────────────────────────────────────────────────

echo "Test: summary counts"
HOME10="$TMPDIR/summary"
setup_base "$HOME10"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME10/.config/.env"

output=$(run_audit "$HOME10")
expect_contains "shows pass count" "$output" "Pass:"
expect_contains "shows critical count" "$output" "Critical:"
expect_contains "shows warn count" "$output" "Warn:"

echo ""

# ── Test 11: Exit codes ──────────────────────────────────────────────────────

echo "Test: exit codes"

# Clean should exit 0 (or 1 for warnings from network/firewall checks)
HOME11="$TMPDIR/exitcode"
setup_base "$HOME11"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME11/.config/.env"
set +e
HORNET_HOME="$HOME11" bash "$SCRIPT" >/dev/null 2>&1
code=$?
set -e
# Might get warnings (no firewall, etc.) so accept 0 or 1
if [ "$code" -le 1 ]; then
  echo "  PASS: clean config exits $code (0 or 1 OK)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: clean config exits $code (expected 0 or 1)"
  FAIL=$((FAIL + 1))
fi

# Critical finding should exit 2
HOME11b="$TMPDIR/exitcode-crit"
setup_base "$HOME11b"
chmod 644 "$HOME11b/.config/.env"
set +e
HORNET_HOME="$HOME11b" bash "$SCRIPT" >/dev/null 2>&1
code=$?
set -e
if [ "$code" -eq 2 ]; then
  echo "  PASS: critical finding exits 2"
  PASS=$((PASS + 1))
else
  echo "  FAIL: critical finding exits $code (expected 2)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
