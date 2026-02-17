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
printf 'baudbot_admin\nsk-test-key\nghp_testtoken\nxoxb-test\nxapp-test\nU01TEST\n\n\n\n\n\nn\n' \
  | bash /home/baudbot_admin/baudbot/install.sh

echo "=== Verifying install ==="
# .env exists with correct permissions
test -f /home/baudbot_agent/.config/.env
test "$(stat -c '%a' /home/baudbot_agent/.config/.env)" = "600"
test "$(stat -c '%U' /home/baudbot_agent/.config/.env)" = "baudbot_agent"
# Runtime deployed
test -f /home/baudbot_agent/runtime/start.sh
test -d /home/baudbot_agent/.pi/agent/extensions
# Required secrets written
grep -q "OPENCODE_ZEN_API_KEY=sk-test-key" /home/baudbot_agent/.config/.env
grep -q "SLACK_BOT_TOKEN=xoxb-test" /home/baudbot_agent/.config/.env
grep -q "BAUDBOT_SOURCE_DIR=" /home/baudbot_agent/.config/.env
echo "  ✓ install.sh verification passed"

echo "=== Installing test dependencies ==="
export PATH="/home/baudbot_agent/opt/node-v22.14.0-linux-x64/bin:$PATH"
cd /home/baudbot_admin/baudbot
npm install --ignore-scripts 2>&1 | tail -1
cd slack-bridge && npm install 2>&1 | tail -1
cd ..

echo "=== Running tests ==="
bash bin/test.sh

echo ""
echo "✅ All checks passed on Ubuntu"
