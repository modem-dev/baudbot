#!/bin/bash
# CI setup script for Ubuntu droplets.
# Runs as root on a fresh droplet. Tests the interactive installer,
# then runs the test suite.
#
# Expects: /tmp/baudbot-src.tar.gz already uploaded via scp.

set -euo pipefail

apt_background_procs() {
  # Ignore unattended-upgrade-shutdown --wait-for-signal. That service can stay
  # running while apt is actually idle and causes false "busy" detections.
  pgrep -f -a '(apt.systemd.daily|apt-get|dpkg|unattended-upgrade)' 2>/dev/null \
    | grep -v 'unattended-upgrade-shutdown --wait-for-signal' || true
}

wait_for_apt_idle() {
  # Fresh Ubuntu droplets may run unattended-upgrades on first boot.
  # Wait until real apt/dpkg workers are gone.
  for _ in $(seq 1 90); do
    if [ -z "$(apt_background_procs)" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo "=== [Ubuntu] Waiting for unattended-upgrades ==="
wait_for_apt_idle || echo "  continuing after timeout; will retry apt commands if lock is still held"

echo "=== [Ubuntu] Installing git (needed to init test repo) ==="
for attempt in $(seq 1 8); do
  if apt-get -o DPkg::Lock::Timeout=120 update -qq \
    && apt-get -o DPkg::Lock::Timeout=120 install -y -qq git 2>&1 | tail -1; then
    break
  fi

  if [ "$attempt" -eq 8 ]; then
    echo "apt failed after $attempt attempts" >&2
    apt_background_procs >&2 || true
    exit 1
  fi

  echo "  apt busy (attempt $attempt/8), retrying in 5s..."
  apt_background_procs || true
  wait_for_apt_idle || true
  sleep 5
done

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
# Simulate interactive input: admin user, provider + Slack mode selections,
# required secrets, skip optional integrations, decline launch.
# Prompts: admin user, LLM choice(1=Anthropic), Anthropic key,
# Slack mode(2=advanced), Slack bot, Slack app, Slack users,
# Browser?(n), Sentry?(n), launch(n)
printf 'baudbot_admin\n1\nsk-ant-testkey\n2\nxoxb-test\nxapp-test\nU01TEST\nn\nn\nn\n' \
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
