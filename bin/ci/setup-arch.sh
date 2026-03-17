#!/bin/bash
# CI setup script for Arch Linux droplets.
# Runs as root on a fresh droplet. Tests the interactive installer,
# then runs the test suite.
#
# Expects: /tmp/baudbot-src.tar.gz already uploaded via scp.

set -euo pipefail

echo "=== [Arch] Installing base CI deps ==="
pacman -Sy --noconfirm --needed git jq sudo 2>&1 | tail -3

echo "=== [Arch] Ensuring iptables backend works ==="
if iptables -w -L OUTPUT -n >/dev/null 2>&1; then
  echo "  iptables backend OK"
else
  IPTABLES_NFT_BIN="$(command -v iptables-nft 2>/dev/null || true)"
  if [ -n "$IPTABLES_NFT_BIN" ] && "$IPTABLES_NFT_BIN" -w -L OUTPUT -n >/dev/null 2>&1; then
    # Some Arch images ship iptables defaulting to legacy backend without
    # ip_tables support. Force nft backend so setup-firewall.sh can apply rules.
    ln -sf "$IPTABLES_NFT_BIN" /usr/local/sbin/iptables
    ln -sf "$IPTABLES_NFT_BIN" /usr/local/bin/iptables
    echo "  iptables legacy unavailable; forced iptables-nft shim"
  else
    echo "❌ No working iptables backend found" >&2
    exit 1
  fi
fi

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
# Simulate interactive input: admin user, auth tier + provider + Slack mode
# selections, required secrets, skip optional integrations, decline launch.
# Prompts: admin user, LLM auth tier(1=API key), LLM choice(1=Anthropic), Anthropic key,
# Slack mode(2=advanced), Slack bot, Slack app, Slack users,
# Browser?(n), Sentry?(n), launch(n)
# Arch CI droplets frequently lack netfilter modules required by setup-firewall;
# skip firewall bootstrap here to keep install/integration coverage stable.
printf 'baudbot_admin\n1\n1\nsk-ant-testkey\n2\nxoxb-test\nxapp-test\nU01TEST\nn\nn\nn\n' \
  | BAUDBOT_SKIP_FIREWALL=1 BAUDBOT_INSTALL_SCRIPT_URL="file:///home/baudbot_admin/baudbot/install.sh" baudbot install

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
# varlock installed for agent user (supports both legacy and current install paths)
test -x /home/baudbot_agent/.varlock/bin/varlock || test -x /home/baudbot_agent/.config/varlock/bin/varlock
# Agent can load env (smoke test — varlock validates schema + .env)
sudo -u baudbot_agent bash -c 'export PATH="$HOME/.varlock/bin:$HOME/.config/varlock/bin:$HOME/opt/node/bin:$PATH" && cd ~ && varlock load --path ~/.config/'
echo "  ✓ bootstrap + install verification passed"

echo "=== Running CLI smoke checks ==="
bash /home/baudbot_admin/baudbot/bin/ci/smoke-cli.sh

echo "=== Running runtime smoke checks ==="
bash /home/baudbot_admin/baudbot/bin/ci/smoke-agent-runtime.sh

echo "=== Running inference smoke check ==="
bash /home/baudbot_admin/baudbot/bin/ci/smoke-agent-inference.sh

echo "=== Installing test dependencies ==="
export PATH="/home/baudbot_agent/opt/node/bin:$PATH"
cd /home/baudbot_admin/baudbot
npm install --ignore-scripts 2>&1 | tail -1
cd gateway-bridge && npm install 2>&1 | tail -1
cd ..

echo "=== Running tests ==="
bash bin/test.sh

echo ""
echo "✅ All checks passed on Arch Linux"
