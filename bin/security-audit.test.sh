#!/bin/bash
# Tests for security-audit.sh
#
# Creates a mock baudbot_agent home directory and verifies the audit
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
  mkdir -p "$home/.config" "$home/.ssh" "$home/.pi" "$home/baudbot/slack-bridge" "$home/baudbot/.git"

  # Secrets file
  echo "SLACK_BOT_TOKEN=xoxb-test" > "$home/.config/.env"
  chmod 600 "$home/.config/.env"

  # SSH
  chmod 700 "$home/.ssh"

  # Pi state
  chmod 700 "$home/.pi"

  # Gitignore
  echo ".env" > "$home/baudbot/.gitignore"

  # Gitconfig (clean)
  echo -e "[user]\n\tname = test\n\temail = test@test.com" > "$home/.gitconfig"

  # Bridge security module
  echo "// security" > "$home/baudbot/slack-bridge/security.mjs"
  echo "// tests" > "$home/baudbot/slack-bridge/security.test.mjs"

  # Audit log (fallback location)
  mkdir -p "$home/logs"
  touch "$home/logs/commands.log"
  chmod 600 "$home/logs/commands.log"
}

run_audit() {
  local home="$1"
  shift
  BAUDBOT_HOME="$home" bash "$SCRIPT" "$@" 2>&1 || true
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
echo "SECRET=oops" > "$HOME5/baudbot/.env"

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
rm -f "$HOME7/baudbot/.gitignore"

output=$(run_audit "$HOME7")
expect_contains "reports no gitignore" "$output" "No .gitignore found"

echo ""

# ── Test 8: Missing bridge security module ────────────────────────────────────

echo "Test: missing bridge security module"
HOME8="$TMPDIR/no-bridge-sec"
setup_base "$HOME8"
rm -f "$HOME8/baudbot/slack-bridge/security.mjs"

output=$(run_audit "$HOME8")
expect_contains "reports missing security module" "$output" "Bridge security module not found"

echo ""

# ── Test 9: Missing bridge tests ──────────────────────────────────────────────

echo "Test: missing bridge tests"
HOME9="$TMPDIR/no-bridge-tests"
setup_base "$HOME9"
rm -f "$HOME9/baudbot/slack-bridge/security.test.mjs"

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

HOME11="$TMPDIR/exitcode"
setup_base "$HOME11"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME11/.config/.env"
set +e
BAUDBOT_HOME="$HOME11" bash "$SCRIPT" >/dev/null 2>&1
code=$?
set -e
if [ "$code" -le 2 ]; then
  echo "  PASS: clean config exits $code (0-2 OK in test env)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: clean config exits $code (expected 0, 1, or 2)"
  FAIL=$((FAIL + 1))
fi

HOME11b="$TMPDIR/exitcode-crit"
setup_base "$HOME11b"
chmod 644 "$HOME11b/.config/.env"
set +e
BAUDBOT_HOME="$HOME11b" bash "$SCRIPT" >/dev/null 2>&1
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

# ── Test 12: --fix on already-correct system is a no-op ──────────────────────

echo "Test: --fix on clean config (no-op)"
HOME12="$TMPDIR/fix-noop"
setup_base "$HOME12"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME12/.config/.env"

output=$(run_audit "$HOME12" --fix)
expect_contains "--fix shows fix summary" "$output" "Fixed:"
expect_contains "--fix shows zero fixes" "$output" "Fixed:    0"
expect_not_contains "--fix does not report FIXED action" "$output" "FIXED:"

echo ""

# ── Test 13: --fix corrects bad file permissions ─────────────────────────────

echo "Test: --fix corrects bad permissions"
HOME13="$TMPDIR/fix-perms"
setup_base "$HOME13"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME13/.config/.env"

# Break permissions
chmod 644 "$HOME13/.config/.env"
chmod 755 "$HOME13/.ssh"
chmod 755 "$HOME13/.pi"

output=$(run_audit "$HOME13" --fix)
expect_contains "--fix reports fixing" "$output" "FIXED:"

# Verify permissions were actually fixed
actual_env=$(stat -c '%a' "$HOME13/.config/.env")
actual_ssh=$(stat -c '%a' "$HOME13/.ssh")
actual_pi=$(stat -c '%a' "$HOME13/.pi")

if [ "$actual_env" = "600" ]; then
  echo "  PASS: .env fixed to 600"
  PASS=$((PASS + 1))
else
  echo "  FAIL: .env is $actual_env (expected 600)"
  FAIL=$((FAIL + 1))
fi

if [ "$actual_ssh" = "700" ]; then
  echo "  PASS: .ssh fixed to 700"
  PASS=$((PASS + 1))
else
  echo "  FAIL: .ssh is $actual_ssh (expected 700)"
  FAIL=$((FAIL + 1))
fi

if [ "$actual_pi" = "700" ]; then
  echo "  PASS: .pi fixed to 700"
  PASS=$((PASS + 1))
else
  echo "  FAIL: .pi is $actual_pi (expected 700)"
  FAIL=$((FAIL + 1))
fi

echo ""

# ── Test 14: --fix reports skipped items ─────────────────────────────────────

echo "Test: --fix reports skipped items (root-required fixes)"
HOME14="$TMPDIR/fix-skip"
setup_base "$HOME14"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME14/.config/.env"

output=$(run_audit "$HOME14" --fix)
expect_contains "--fix shows skipped count" "$output" "Skipped:"

echo ""

# ── Test 15: --fix summary format ───────────────────────────────────────────

echo "Test: --fix summary format"
HOME15="$TMPDIR/fix-summary"
setup_base "$HOME15"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME15/.config/.env"
chmod 644 "$HOME15/.config/.env"

output=$(run_audit "$HOME15" --fix)
expect_contains "--fix summary has Fixed" "$output" "Fixed:"
expect_contains "--fix summary has Skipped" "$output" "Skipped:"
expect_contains "--fix summary has Errors" "$output" "Errors:"
expect_contains "--fix mode banner" "$output" "auto-fix enabled"

echo ""

# ── Test 16: --fix corrects session log permissions ──────────────────────────

echo "Test: --fix corrects leaky session logs"
HOME16="$TMPDIR/fix-logs"
setup_base "$HOME16"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME16/.config/.env"
mkdir -p "$HOME16/.pi/agent/sessions/abc"
echo '{"msg":"test"}' > "$HOME16/.pi/agent/sessions/abc/session.jsonl"
chmod 644 "$HOME16/.pi/agent/sessions/abc/session.jsonl"

output=$(run_audit "$HOME16" --fix)
actual_log=$(stat -c '%a' "$HOME16/.pi/agent/sessions/abc/session.jsonl")
if [ "$actual_log" = "600" ]; then
  echo "  PASS: session log fixed to 600"
  PASS=$((PASS + 1))
else
  echo "  FAIL: session log is $actual_log (expected 600)"
  FAIL=$((FAIL + 1))
fi

echo ""

# ── Test 17: --fix re-run after fix shows clean ──────────────────────────────

echo "Test: --fix then re-audit shows clean"
HOME17="$TMPDIR/fix-rerun"
setup_base "$HOME17"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME17/.config/.env"
chmod 644 "$HOME17/.config/.env"
chmod 755 "$HOME17/.ssh"

# First run: fix
run_audit "$HOME17" --fix > /dev/null

# Second run: should be clean (perms-wise)
output=$(run_audit "$HOME17")
expect_contains "re-audit shows secrets file pass" "$output" "Secrets file (600)"
expect_contains "re-audit shows SSH dir pass" "$output" "SSH directory (700)"

echo ""

# ── Test 18: --fix without --fix does not fix ────────────────────────────────

echo "Test: audit without --fix does not modify files"
HOME18="$TMPDIR/no-fix"
setup_base "$HOME18"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME18/.config/.env"
chmod 644 "$HOME18/.config/.env"

run_audit "$HOME18" > /dev/null
actual=$(stat -c '%a' "$HOME18/.config/.env")
if [ "$actual" = "644" ]; then
  echo "  PASS: audit without --fix leaves files untouched"
  PASS=$((PASS + 1))
else
  echo "  FAIL: audit without --fix changed .env to $actual"
  FAIL=$((FAIL + 1))
fi

echo ""

# ── Test 19: Pre-commit hook section ─────────────────────────────────────────

echo "Test: pre-commit hook checks"
HOME19="$TMPDIR/hook-check"
setup_base "$HOME19"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME19/.config/.env"

output=$(run_audit "$HOME19")
expect_contains "reports missing hook" "$output" "Pre-commit hook not installed"

# Install a hook
mkdir -p "$HOME19/baudbot/.git/hooks"
echo "#!/bin/bash" > "$HOME19/baudbot/.git/hooks/pre-commit"
output=$(run_audit "$HOME19")
expect_contains "reports hook installed" "$output" "Pre-commit hook installed"

echo ""

# ── Test 20: Protected file ownership ────────────────────────────────────────

echo "Test: protected file ownership check detects agent-owned protected files"
HOME20="$TMPDIR/protected-own"
setup_base "$HOME20"
echo "SLACK_ALLOWED_USERS=U12345" >> "$HOME20/.config/.env"

# Create a protected file (will be owned by current user = baudbot_agent in test)
mkdir -p "$HOME20/baudbot/bin"
echo "#!/bin/bash" > "$HOME20/baudbot/bin/security-audit.sh"

output=$(run_audit "$HOME20")
# If running as baudbot_agent, should flag it
if [ "$(whoami)" = "baudbot_agent" ]; then
  expect_contains "flags agent-owned protected file" "$output" "Protected file owned by baudbot_agent"
else
  # Running as admin — file is admin-owned, should pass
  expect_contains "protected files pass" "$output" "All protected files are admin-owned"
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
