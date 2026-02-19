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

echo "=== Running bootstrap + baudbot install ==="
# Bootstrap installs /usr/local/bin/baudbot, then baudbot install runs install.sh.
# Use file:// URLs so CI tests the uploaded source bundle (not GitHub main).
BAUDBOT_CLI_URL="file:///home/baudbot_admin/baudbot/bin/baudbot" \
BAUDBOT_BOOTSTRAP_TARGET="/usr/local/bin/baudbot" \
  bash /home/baudbot_admin/baudbot/bootstrap.sh
# Simulate interactive input: admin user, required secrets, skip optionals, decline launch
# Prompts: admin user, Anthropic, OpenAI(skip), Gemini(skip), OpenCode(skip),
#   Slack bot, Slack app, Slack users, AgentMail(skip), email(skip), Sentry(skip), Kernel(skip), launch(n)
printf 'baudbot_admin\nsk-ant-testkey\n\n\n\nxoxb-test\nxapp-test\nU01TEST\n\n\n\n\nn\n' \
  | BAUDBOT_INSTALL_SCRIPT_URL="file:///home/baudbot_admin/baudbot/install.sh" baudbot install

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
# CLI installed and points at /opt release snapshot
test -L /usr/local/bin/baudbot
test -d /opt/baudbot/releases
test -L /opt/baudbot/current
CLI_TARGET=$(readlink -f /usr/local/bin/baudbot)
echo "$CLI_TARGET" | grep -qE '^/opt/baudbot/releases/.+/bin/baudbot$'
# /opt releases must be git-free
! find /opt/baudbot/releases -type d -name .git -print -quit | grep -q .
baudbot --version
HELP_OUT=$(baudbot --help)
echo "$HELP_OUT" | grep -q "baudbot"
# varlock installed for agent user
test -x /home/baudbot_agent/.varlock/bin/varlock
# Agent can load env (smoke test — varlock validates schema + .env)
sudo -u baudbot_agent bash -c 'export PATH="$HOME/.varlock/bin:$HOME/opt/node-v22.14.0-linux-x64/bin:$PATH" && cd ~ && varlock load --path ~/.config/'
echo "  ✓ bootstrap + install verification passed"

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
