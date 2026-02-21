#!/bin/bash
# Tests for bin/env.sh and bin/render-env.sh helpers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_SCRIPT="$SCRIPT_DIR/env.sh"
RENDER_SCRIPT="$SCRIPT_DIR/render-env.sh"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

ADMIN_HOME="$TMPDIR/admin"
AGENT_HOME="$TMPDIR/agent"
mkdir -p "$ADMIN_HOME/.baudbot" "$AGENT_HOME/.config"

ADMIN_ENV="$ADMIN_HOME/.baudbot/.env"
RUNTIME_ENV="$AGENT_HOME/.config/.env"
BACKEND_CONF="$ADMIN_HOME/.baudbot/env-store.conf"

touch "$ADMIN_ENV" "$RUNTIME_ENV"

run_env() {
  BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_AGENT_HOME="$AGENT_HOME" BAUDBOT_AGENT_USER="$(id -un)" bash "$ENV_SCRIPT" "$@"
}

run_render() {
  BAUDBOT_ADMIN_HOME="$ADMIN_HOME" BAUDBOT_CONFIG_USER="$(id -un)" bash "$RENDER_SCRIPT" "$@"
}

expect_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

expect_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

echo ""
echo "Testing env helpers"
echo "==================="
echo ""

# file backend set writes admin env
run_env set ANTHROPIC_API_KEY sk-ant-test >/dev/null
expect_contains "set writes admin env" "$ADMIN_ENV" "ANTHROPIC_API_KEY=sk-ant-test"

# get returns value
GET_OUT="$(run_env get ANTHROPIC_API_KEY --admin)"
if [ "$GET_OUT" = "sk-ant-test" ]; then
  echo "  PASS: get returns admin value"
  PASS=$((PASS + 1))
else
  echo "  FAIL: get returns admin value"
  FAIL=$((FAIL + 1))
fi

# set replaces existing value (no duplicates)
run_env set ANTHROPIC_API_KEY sk-ant-new >/dev/null
COUNT="$(grep -c '^ANTHROPIC_API_KEY=' "$ADMIN_ENV" || true)"
if [ "$COUNT" = "1" ]; then
  echo "  PASS: set replaces existing key"
  PASS=$((PASS + 1))
else
  echo "  FAIL: set replaces existing key"
  FAIL=$((FAIL + 1))
fi
expect_contains "updated key value present" "$ADMIN_ENV" "ANTHROPIC_API_KEY=sk-ant-new"

# command backend render + get
run_env backend set-command 'printf "ANTHROPIC_API_KEY=sk-ant-cmd\\nOPENAI_API_KEY=sk-cmd\\n"' >/dev/null
expect_contains "backend conf stores command backend" "$BACKEND_CONF" "BAUDBOT_ENV_BACKEND=command"
RENDERED_KEY="$(run_render --get ANTHROPIC_API_KEY)"
if [ "$RENDERED_KEY" = "sk-ant-cmd" ]; then
  echo "  PASS: render-env reads command backend"
  PASS=$((PASS + 1))
else
  echo "  FAIL: render-env reads command backend"
  FAIL=$((FAIL + 1))
fi

# set should fail on command backend
set +e
run_env set ANTHROPIC_API_KEY sk-ant-should-fail >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "  PASS: set rejected on command backend"
  PASS=$((PASS + 1))
else
  echo "  FAIL: set rejected on command backend"
  FAIL=$((FAIL + 1))
fi

# switch back to file backend + unset works
run_env backend set-file >/dev/null
run_env unset ANTHROPIC_API_KEY >/dev/null
expect_not_contains "unset removes key" "$ADMIN_ENV" "ANTHROPIC_API_KEY="

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
