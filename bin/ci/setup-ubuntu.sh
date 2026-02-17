#!/bin/bash
# CI setup script for Ubuntu droplets.
# Runs as root on a fresh droplet. Tests the interactive installer,
# then runs the test suite.
#
# Expects: /tmp/hornet-src.tar.gz already uploaded via scp.

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
useradd -m -s /bin/bash hornet_admin
mkdir -p /home/hornet_admin/hornet
cd /home/hornet_admin/hornet
tar xzf /tmp/hornet-src.tar.gz
chown -R hornet_admin:hornet_admin /home/hornet_admin/
sudo -u hornet_admin bash -c 'cd ~/hornet && git init -q && git config user.email "ci@test" && git config user.name "CI" && git add -A && git commit -q -m "init"'

echo "=== Running install.sh ==="
# Simulate interactive input: admin user, required secrets, skip optionals, decline launch
printf 'hornet_admin\nsk-test-key\nghp_testtoken\nxoxb-test\nxapp-test\nU01TEST\n\n\n\n\n\nn\n' \
  | bash /home/hornet_admin/hornet/install.sh

echo "=== Verifying install ==="
# .env exists with correct permissions
test -f /home/hornet_agent/.config/.env
test "$(stat -c '%a' /home/hornet_agent/.config/.env)" = "600"
test "$(stat -c '%U' /home/hornet_agent/.config/.env)" = "hornet_agent"
# Runtime deployed
test -f /home/hornet_agent/runtime/start.sh
test -d /home/hornet_agent/.pi/agent/extensions
# Required secrets written
grep -q "OPENCODE_ZEN_API_KEY=sk-test-key" /home/hornet_agent/.config/.env
grep -q "SLACK_BOT_TOKEN=xoxb-test" /home/hornet_agent/.config/.env
grep -q "HORNET_SOURCE_DIR=" /home/hornet_agent/.config/.env
echo "  ✓ install.sh verification passed"

echo "=== Installing test dependencies ==="
export PATH="/home/hornet_agent/opt/node-v22.14.0-linux-x64/bin:$PATH"
cd /home/hornet_admin/hornet
npm install --ignore-scripts 2>&1 | tail -1
cd slack-bridge && npm install 2>&1 | tail -1
cd ..

echo "=== Running tests ==="
bash bin/test.sh

echo ""
echo "✅ All checks passed on Ubuntu"
