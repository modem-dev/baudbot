#!/bin/bash
# Tests for prune-session-logs.sh
#
# Run: bash prune-session-logs.test.sh

set -euo pipefail

SCRIPT="$(dirname "$0")/prune-session-logs.sh"
PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

expect_exists() {
  local desc="$1"
  local path="$2"
  if [ -e "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

expect_not_exists() {
  local desc="$1"
  local path="$2"
  if [ ! -e "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
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

echo ""
echo "Testing prune-session-logs.sh"
echo "============================="
echo ""

# ── Test 1: Deletes old logs, keeps recent logs ─────────────────────────────

echo "Test: prune old logs only"
HOME1="$TMPDIR/home1"
SESS1="$HOME1/.pi/agent/sessions"
mkdir -p "$SESS1/old-session" "$SESS1/recent-session"

old_log="$SESS1/old-session/session.jsonl"
recent_log="$SESS1/recent-session/session.jsonl"

echo '{"msg":"old"}' > "$old_log"
echo '{"msg":"recent"}' > "$recent_log"

touch -d '30 days ago' "$old_log"
touch -d '2 days ago' "$recent_log"

output=$(HOME="$HOME1" bash "$SCRIPT" --days 14)
expect_contains "reports pruning summary" "$output" "Session log pruning complete"
expect_not_exists "old log deleted" "$old_log"
expect_exists "recent log kept" "$recent_log"

echo ""

# ── Test 2: Removes empty dirs after deleting logs ──────────────────────────

echo "Test: removes empty directories"
expect_not_exists "empty old session dir removed" "$SESS1/old-session"
expect_exists "recent session dir retained" "$SESS1/recent-session"

echo ""

# ── Test 3: Dry run does not modify files ───────────────────────────────────

echo "Test: dry-run"
HOME2="$TMPDIR/home2"
SESS2="$HOME2/.pi/agent/sessions"
mkdir -p "$SESS2/dry-run-session"

dry_log="$SESS2/dry-run-session/session.jsonl"
echo '{"msg":"dry"}' > "$dry_log"
touch -d '45 days ago' "$dry_log"

output=$(HOME="$HOME2" bash "$SCRIPT" --days 14 --dry-run)
expect_contains "dry run announces would delete" "$output" "WOULD DELETE:"
expect_exists "dry run keeps old log" "$dry_log"

echo ""

# ── Test 4: Missing sessions dir exits cleanly ──────────────────────────────

echo "Test: missing sessions dir"
HOME3="$TMPDIR/home3"
mkdir -p "$HOME3"
output=$(HOME="$HOME3" bash "$SCRIPT")
expect_contains "missing dir handled" "$output" "No sessions directory found"

echo ""

# ── Test 5: Invalid days value fails ────────────────────────────────────────

echo "Test: invalid --days"
set +e
HOME="$HOME1" bash "$SCRIPT" --days invalid >/dev/null 2>&1
code=$?
set -e
if [ "$code" -ne 0 ]; then
  echo "  PASS: invalid days exits non-zero"
  PASS=$((PASS + 1))
else
  echo "  FAIL: invalid days should fail"
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
