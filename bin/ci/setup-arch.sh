#!/bin/bash
# CI setup script for Arch Linux droplets.
# Runs as root on a fresh droplet. Installs prereqs, uploads source,
# runs setup.sh, and executes the test suite.
#
# Expects: /tmp/hornet-src.tar.gz already uploaded via scp.

set -euo pipefail

echo "=== [Arch] Installing prerequisites ==="
pacman -Syu --noconfirm --needed git curl tmux iptables docker sudo 2>&1 | tail -10

echo "=== Preparing source ==="
useradd -m -s /bin/bash hornet_admin
mkdir -p /home/hornet_admin/hornet
cd /home/hornet_admin/hornet
tar xzf /tmp/hornet-src.tar.gz
chown -R hornet_admin:hornet_admin /home/hornet_admin/
sudo -u hornet_admin bash -c 'cd ~/hornet && git init -q && git config user.email "ci@test" && git config user.name "CI" && git add -A && git commit -q -m "init"'

echo "=== Running setup.sh ==="
cd /
bash /home/hornet_admin/hornet/setup.sh hornet_admin

echo "=== Installing test dependencies ==="
export PATH="/home/hornet_agent/opt/node-v22.14.0-linux-x64/bin:$PATH"
cd /home/hornet_admin/hornet
npm install --ignore-scripts 2>&1 | tail -1
cd slack-bridge && npm install 2>&1 | tail -1
cd ..

echo "=== Running tests ==="
bash bin/test.sh

echo ""
echo "✅ All checks passed on Arch Linux"
