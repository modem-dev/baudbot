#!/bin/bash
# CI setup script for Arch Linux droplets.
# Runs as root on a fresh droplet. Tests the interactive installer,
# then runs the test suite.
#
# Expects: /tmp/baudbot-src.tar.gz already uploaded via scp.

set -euo pipefail

echo "=== [Arch] Installing git (needed to init test repo) ==="
pacman -Sy --noconfirm --needed git sudo 2>&1 | tail -3

echo "=== Preparing source ==="
useradd -m -s /bin/bash baudbot_admin
mkdir -p /home/baudbot_admin/baudbot
cd /home/baudbot_admin/baudbot
tar xzf /tmp/baudbot-src.tar.gz
chown -R baudbot_admin:baudbot_admin /home/baudbot_admin/
sudo -u baudbot_admin bash -c 'cd ~/baudbot && git init -q && git config user.email "ci@test" && git config user.name "CI" && git add -A && git commit -q -m "init"'

echo "=== Running install.sh ==="
# Simulate interactive input: admin user, required secrets, skip optionals, decline launch
printf 'baudbot_admin\nsk-ant-testkey\n\n\n\nghp_testtoken\nxoxb-test\nxapp-test\nU01TEST\n\n\n\n\nn\n' \
  | bash /home/baudbot_admin/baudbot/install.sh

echo "=== Verifying install ==="
# .env exists with correct permissions
test -f /home/baudbot_agent/.config/.env
test "$(stat -c '%a' /home/baudbot_agent/.config/.env)" = "600"
test "$(stat -c '%U' /home/baudbot_agent/.config/.env)" = "baudbot_agent"
# Runtime deployed
test -f /home/baudbot_agent/runtime/start.sh
test -d /home/baudbot_agent/.pi/agent/extensions
# Admin config written
test -f /home/baudbot_admin/.baudbot/.env
grep -q "ANTHROPIC_API_KEY=sk-ant-testkey" /home/baudbot_admin/.baudbot/.env
# Deployed to agent
grep -q "ANTHROPIC_API_KEY=sk-ant-testkey" /home/baudbot_agent/.config/.env
grep -q "SLACK_BOT_TOKEN=xoxb-test" /home/baudbot_agent/.config/.env
grep -q "BAUDBOT_SOURCE_DIR=" /home/baudbot_agent/.config/.env
# CLI installed
test -L /usr/local/bin/baudbot
baudbot --version
HELP_OUT=$(baudbot --help)
echo "$HELP_OUT" | grep -q "baudbot"
# varlock installed for agent user
test -x /home/baudbot_agent/.varlock/bin/varlock
# Agent can load env (smoke test — varlock validates schema + .env)
# varlock load may return non-zero for undefined optional vars; capture and check output
VARLOCK_OUT=$(sudo -u baudbot_agent bash -c 'export PATH="$HOME/.varlock/bin:$HOME/opt/node-v22.14.0-linux-x64/bin:$PATH" && cd ~ && varlock load --path ~/.config/ 2>&1' || true)
echo "$VARLOCK_OUT"
# Fail only if there's an actual validation error (❌)
if echo "$VARLOCK_OUT" | grep -q "❌"; then
  echo "varlock validation failed"
  exit 1
fi
echo "  varlock check passed"
# start.sh has TMUX_TMPDIR set (so tmux works with systemd PrivateTmp)
echo "  checking TMUX_TMPDIR in start.sh..."
grep -q "TMUX_TMPDIR" /home/baudbot_agent/runtime/start.sh || { echo "FAIL: TMUX_TMPDIR not found in start.sh"; exit 1; }
echo "  checking _start_bridge in start.sh..."
grep -q "_start_bridge" /home/baudbot_agent/runtime/start.sh || { echo "FAIL: _start_bridge not found in start.sh"; exit 1; }
echo "  checking baudbot sessions..."
SESS_OUT=$(baudbot sessions 2>&1 || true)
echo "$SESS_OUT" | grep -q "tmux sessions" || { echo "FAIL: sessions output missing 'tmux sessions'"; echo "$SESS_OUT"; exit 1; }
echo "$SESS_OUT" | grep -q "pi sessions" || { echo "FAIL: sessions output missing 'pi sessions'"; echo "$SESS_OUT"; exit 1; }
echo "  checking baudbot attach..."
ATTACH_OUT=$(baudbot attach 2>&1 || true)
echo "$ATTACH_OUT" | grep -qi "no tmux sessions\|start the agent" || { echo "FAIL: attach output unexpected"; echo "$ATTACH_OUT"; exit 1; }
echo "  ✓ install.sh verification passed"

echo "=== Installing test dependencies ==="
export PATH="/home/baudbot_agent/opt/node-v22.14.0-linux-x64/bin:$PATH"
cd /home/baudbot_admin/baudbot
npm install --ignore-scripts 2>&1 | tail -1
cd slack-bridge && npm install 2>&1 | tail -1
cd ../control-plane && npm install 2>&1 | tail -1
cd ..

echo "=== Running tests ==="
bash bin/test.sh

echo ""
echo "✅ All checks passed on Arch Linux"
