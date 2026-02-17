#!/bin/bash
# CI setup script for Ubuntu droplets.
# Runs as root on a fresh droplet. Tests the interactive installer,
# then runs the test suite.
#
# Expects: /tmp/baudbot-src.tar.gz already uploaded via scp.

set -euo pipefail

echo "=== [Ubuntu] Waiting for unattended-upgrades ==="
# Fresh DO droplets run unattended-upgrades on first boot which holds apt locks.
# Wait for all apt/dpkg processes to finish (up to 120s).
for _ in $(seq 1 60); do
  if ! pgrep -x 'apt|apt-get|dpkg|unattended-upgrade' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "=== [Ubuntu] Installing git (needed to init test repo) ==="
apt-get update -qq
apt-get install -y -qq git 2>&1 | tail -1

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
# start.sh has TMUX_TMPDIR set (so tmux works with systemd PrivateTmp)
grep -q "TMUX_TMPDIR" /home/baudbot_agent/runtime/start.sh
# start.sh has bridge auto-start function
grep -q "_start_bridge" /home/baudbot_agent/runtime/start.sh
# baudbot sessions runs without error
SESS_OUT=$(baudbot sessions 2>&1 || true)
echo "$SESS_OUT" | grep -q "tmux sessions"
echo "$SESS_OUT" | grep -q "pi sessions"
# baudbot attach gives helpful message when no sessions
ATTACH_OUT=$(baudbot attach 2>&1 || true)
echo "$ATTACH_OUT" | grep -qi "no tmux sessions"
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
echo "✅ All checks passed on Ubuntu"
