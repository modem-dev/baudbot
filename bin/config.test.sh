#!/bin/bash
# Tests for bin/config.sh guided branching flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_SCRIPT="$SCRIPT_DIR/config.sh"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

run_config() {
  local home="$1"
  local input="$2"
  local config_user
  # config.sh exits when run as root unless BAUDBOT_CONFIG_USER is set.
  # CI shell tests run as root on droplets, so force an explicit target user.
  config_user="$(id -un)"
  mkdir -p "$home"
  printf "%b" "$input" \
    | HOME="$home" BAUDBOT_CONFIG_USER="$config_user" BAUDBOT_TRY_INSTALL_GUM=0 bash "$CONFIG_SCRIPT" \
      >/tmp/baudbot-config-test.out 2>/tmp/baudbot-config-test.err
}

write_existing_env() {
  local home="$1"
  local content="$2"
  mkdir -p "$home/.baudbot"
  printf "%b" "$content" > "$home/.baudbot/.env"
}

expect_file_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        expected pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

expect_file_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then
    echo "  FAIL: $desc"
    echo "        unexpected pattern: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

expect_exit_nonzero() {
  local desc="$1" home="$2" input="$3"
  local config_user
  # Same reason as run_config(): make behavior deterministic under root CI runs.
  config_user="$(id -un)"
  set +e
  printf "%b" "$input" \
    | HOME="$home" BAUDBOT_CONFIG_USER="$config_user" BAUDBOT_TRY_INSTALL_GUM=0 bash "$CONFIG_SCRIPT" \
      >/tmp/baudbot-config-test.out 2>/tmp/baudbot-config-test.err
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "Testing config.sh"
echo "================="
echo ""

# Test 1: Advanced Slack path writes socket-mode keys only
HOME1="$TMPDIR/advanced"
run_config "$HOME1" '1\nsk-ant-test\n2\nxoxb-test\nxapp-test\n\nn\nn\nn\n'
ENV1="$HOME1/.baudbot/.env"
expect_file_contains "advanced path writes Anthropic key" "$ENV1" "ANTHROPIC_API_KEY=sk-ant-test"
expect_file_contains "advanced path writes SLACK_BOT_TOKEN" "$ENV1" "SLACK_BOT_TOKEN=xoxb-test"
expect_file_contains "advanced path writes SLACK_APP_TOKEN" "$ENV1" "SLACK_APP_TOKEN=xapp-test"
expect_file_not_contains "advanced path does not write OPENAI key" "$ENV1" "OPENAI_API_KEY="

# Test 2: Easy Slack path avoids socket-mode keys
HOME2="$TMPDIR/easy"
run_config "$HOME2" '2\nsk-openai-test\n1\n\nn\nn\nn\n'
ENV2="$HOME2/.baudbot/.env"
expect_file_contains "easy path writes OpenAI key" "$ENV2" "OPENAI_API_KEY=sk-openai-test"
expect_file_not_contains "easy path omits SLACK_BOT_TOKEN" "$ENV2" "SLACK_BOT_TOKEN="
expect_file_not_contains "easy path omits SLACK_APP_TOKEN" "$ENV2" "SLACK_APP_TOKEN="

# Test 3: Optional integration toggle prompts conditionally
HOME3="$TMPDIR/kernel"
run_config "$HOME3" '3\ngem-key\n2\nxoxb-test\nxapp-test\n\ny\nkernel-key\nn\nn\n'
ENV3="$HOME3/.baudbot/.env"
expect_file_contains "kernel enabled writes key" "$ENV3" "KERNEL_API_KEY=kernel-key"
expect_file_not_contains "sentry skipped omits token" "$ENV3" "SENTRY_AUTH_TOKEN="
expect_file_not_contains "email skipped omits AgentMail" "$ENV3" "AGENTMAIL_API_KEY="

# Test 4: Selected LLM key is required
HOME4="$TMPDIR/missing-llm"
expect_exit_nonzero "fails when selected provider key is missing" "$HOME4" '1\n\n'

# Test 5: Re-run preserves existing selected LLM key when input is blank
HOME5="$TMPDIR/rerun-keep-llm"
write_existing_env "$HOME5" 'ANTHROPIC_API_KEY=sk-ant-existing\n'
run_config "$HOME5" '1\n\n1\n\nn\nn\nn\n'
ENV5="$HOME5/.baudbot/.env"
expect_file_contains "rerun keeps existing Anthropic key" "$ENV5" "ANTHROPIC_API_KEY=sk-ant-existing"

# Test 6: Advanced Slack mode clears stale broker registration keys
HOME6="$TMPDIR/clear-broker"
write_existing_env "$HOME6" 'OPENAI_API_KEY=sk-old\nSLACK_BROKER_URL=https://broker.example.com\nSLACK_BROKER_WORKSPACE_ID=T0123\nSLACK_BROKER_PUBLIC_KEY=abc\n'
run_config "$HOME6" '2\nsk-openai-new\n2\nxoxb-new\nxapp-new\n\nn\nn\nn\n'
ENV6="$HOME6/.baudbot/.env"
expect_file_not_contains "advanced clears broker URL" "$ENV6" "SLACK_BROKER_URL="
expect_file_not_contains "advanced clears broker workspace" "$ENV6" "SLACK_BROKER_WORKSPACE_ID="
expect_file_contains "advanced retains socket bot token" "$ENV6" "SLACK_BOT_TOKEN=xoxb-new"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
