#!/bin/bash
# Tests for redact-logs.sh
#
# Run: bash redact-logs.test.sh

set -euo pipefail

SCRIPT="$(dirname "$0")/redact-logs.sh"
PASS=0
FAIL=0

# Create a temp session dir structure
TMPDIR=$(mktemp -d)
SESSION_DIR="$TMPDIR/.pi/agent/sessions/test-session"
mkdir -p "$SESSION_DIR"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

check() {
  local desc="$1"
  local input="$2"
  local expected_pattern="$3"
  local not_expected="${4:-}"

  local logfile="$SESSION_DIR/test-$(date +%s%N).jsonl"
  echo "$input" > "$logfile"

  HOME="$TMPDIR" bash "$SCRIPT" >/dev/null 2>&1

  local result
  result=$(cat "$logfile")

  local passed=true

  if ! echo "$result" | grep -qF "$expected_pattern"; then
    echo "  FAIL: $desc"
    echo "        expected to contain: $expected_pattern"
    echo "        got: $result"
    FAIL=$((FAIL + 1))
    passed=false
  fi

  if [ -n "$not_expected" ]; then
    if echo "$result" | grep -qF "$not_expected"; then
      echo "  FAIL: $desc"
      echo "        should NOT contain: $not_expected"
      echo "        got: $result"
      if [ "$passed" = true ]; then
        FAIL=$((FAIL + 1))
      fi
      passed=false
    fi
  fi

  if [ "$passed" = true ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

check_unchanged() {
  local desc="$1"
  local input="$2"

  local logfile="$SESSION_DIR/test-unchanged-$(date +%s%N).jsonl"
  echo "$input" > "$logfile"

  HOME="$TMPDIR" bash "$SCRIPT" >/dev/null 2>&1

  local result
  result=$(cat "$logfile")

  if [ "$result" = "$input" ]; then
    echo "  PASS: $desc (unchanged)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        input:  $input"
    echo "        output: $result"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "Testing redact-logs.sh"
echo "======================"
echo ""

echo "Redaction tests:"
check "OpenAI API key" \
  '{"text":"key is sk-abcdefghijklmnopqrstuvwxyz1234567890"}' \
  "[REDACTED_API_KEY]" \
  "sk-abcdef"

check "Slack bot token" \
  '{"text":"token xoxb-12345678901-12345678901-abcdefghijklmnop"}' \
  "[REDACTED_SLACK_TOKEN]" \
  "xoxb-"

check "Slack app token" \
  '{"text":"xapp-1-A12345-12345678-abcdefghijklmnopqrstuv"}' \
  "[REDACTED_SLACK_TOKEN]" \
  "xapp-"

check "GitHub PAT" \
  '{"text":"ghp_abcdefghijklmnopqrstuvwxyz1234567890"}' \
  "[REDACTED_GITHUB_TOKEN]" \
  "ghp_"

check "GitHub fine-grained PAT" \
  '{"text":"github_pat_abcdefghijklmnopqrstuv_1234567890"}' \
  "[REDACTED_GITHUB_TOKEN]" \
  "github_pat_"

check "AWS access key" \
  '{"text":"AKIAIOSFODNN7EXAMPLE"}' \
  "[REDACTED_AWS_KEY]" \
  "AKIAIOSFODNN7"

check "Bearer token" \
  '{"text":"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkw"}' \
  "[REDACTED_BEARER]" \
  "eyJhbGci"

echo ""
echo "No-redaction tests (should be unchanged):"
check_unchanged "Clean log line" \
  '{"role":"assistant","content":"Hello, how can I help?"}'

check_unchanged "Short token-like string (too short)" \
  '{"text":"sk-abc"}'

check_unchanged "Normal code" \
  '{"text":"const result = await fetch(url);"}'

echo ""
echo "Dry-run test:"
dryrun_file="$SESSION_DIR/dryrun-test.jsonl"
echo '{"text":"sk-abcdefghijklmnopqrstuvwxyz1234567890"}' > "$dryrun_file"
HOME="$TMPDIR" bash "$SCRIPT" --dry-run >/dev/null 2>&1
dryrun_result=$(cat "$dryrun_file")
if echo "$dryrun_result" | grep -qF "sk-abcdef"; then
  echo "  PASS: dry-run does not modify files"
  PASS=$((PASS + 1))
else
  echo "  FAIL: dry-run modified the file"
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
