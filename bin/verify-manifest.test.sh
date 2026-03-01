#!/bin/bash
# Tests for verify-manifest.sh

set -euo pipefail

SCRIPT="$(dirname "$0")/verify-manifest.sh"
PASS=0
FAIL=0

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

expect_eq() {
  local desc="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

make_manifest() {
  local manifest_file="$1"
  local home_dir="$2"
  local release_dir="$3"

  local ext_file="$home_dir/.pi/agent/extensions/test.ts"
  local runtime_file="$home_dir/runtime/bin/helper.sh"
  local bridge_file="$release_dir/gateway-bridge/bridge.mjs"
  local log_file="$home_dir/.pi/agent/logs/bridge.log"

  cat >"$manifest_file" <<EOF
{
  "generated_at": "2026-02-23T00:00:00Z",
  "files": {
    ".pi/agent/extensions/test.ts": "$(hash_file "$ext_file")",
    "runtime/bin/helper.sh": "$(hash_file "$runtime_file")",
    "release/gateway-bridge/bridge.mjs": "$(hash_file "$bridge_file")",
    ".pi/agent/logs/bridge.log": "$(hash_file "$log_file")"
  }
}
EOF
}

status_field() {
  local status_file="$1"
  local field="$2"
  jq -r ".$field" "$status_file"
}

echo ""
echo "Testing verify-manifest.sh"
echo "=========================="
echo ""

HOME1="$TMPDIR/home1"
RELEASE1="$TMPDIR/release1"
mkdir -p "$HOME1/.pi/agent/extensions" "$HOME1/runtime/bin" "$HOME1/.pi/agent/logs" "$RELEASE1/gateway-bridge"

printf 'console.log("ok");\n' > "$HOME1/.pi/agent/extensions/test.ts"
printf '#!/bin/bash\necho helper\n' > "$HOME1/runtime/bin/helper.sh"
printf 'export const bridge = true;\n' > "$RELEASE1/gateway-bridge/bridge.mjs"
printf 'mutable log\n' > "$HOME1/.pi/agent/logs/bridge.log"

MANIFEST1="$HOME1/.pi/agent/baudbot-manifest.json"
STATUS1="$HOME1/.pi/agent/manifest-integrity-status.json"
make_manifest "$MANIFEST1" "$HOME1" "$RELEASE1"

BAUDBOT_HOME="$HOME1" \
BAUDBOT_CURRENT_LINK="$RELEASE1" \
BAUDBOT_MANIFEST_FILE="$MANIFEST1" \
BAUDBOT_INTEGRITY_STATUS_FILE="$STATUS1" \
BAUDBOT_STARTUP_INTEGRITY_MODE="warn" \
bash "$SCRIPT" >/dev/null

expect_eq "matching manifest passes" "$(status_field "$STATUS1" status)" "pass"
expect_eq "mutable log path was skipped" "$(status_field "$STATUS1" skipped_files)" "1"

echo ""
echo "Test: warn mode does not fail startup"
printf 'tampered\n' > "$HOME1/.pi/agent/extensions/test.ts"

BAUDBOT_HOME="$HOME1" \
BAUDBOT_CURRENT_LINK="$RELEASE1" \
BAUDBOT_MANIFEST_FILE="$MANIFEST1" \
BAUDBOT_INTEGRITY_STATUS_FILE="$STATUS1" \
BAUDBOT_STARTUP_INTEGRITY_MODE="warn" \
bash "$SCRIPT" >/dev/null

expect_eq "warn mode records warn status" "$(status_field "$STATUS1" status)" "warn"

echo ""
echo "Test: strict mode fails on mismatch"
set +e
BAUDBOT_HOME="$HOME1" \
BAUDBOT_CURRENT_LINK="$RELEASE1" \
BAUDBOT_MANIFEST_FILE="$MANIFEST1" \
BAUDBOT_INTEGRITY_STATUS_FILE="$STATUS1" \
BAUDBOT_STARTUP_INTEGRITY_MODE="strict" \
bash "$SCRIPT" >/dev/null 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  pass "strict mode exits non-zero on mismatch"
else
  fail "strict mode should exit non-zero on mismatch"
fi
expect_eq "strict mode records fail status" "$(status_field "$STATUS1" status)" "fail"

echo ""
echo "Test: off mode skips verification"
BAUDBOT_HOME="$HOME1" \
BAUDBOT_CURRENT_LINK="$RELEASE1" \
BAUDBOT_MANIFEST_FILE="$MANIFEST1" \
BAUDBOT_INTEGRITY_STATUS_FILE="$STATUS1" \
BAUDBOT_STARTUP_INTEGRITY_MODE="off" \
bash "$SCRIPT" >/dev/null

expect_eq "off mode records skipped status" "$(status_field "$STATUS1" status)" "skipped"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "ALL PASSED"
