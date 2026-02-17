#!/bin/bash
# Baudbot Agent Setup Script
# Run as root or with sudo from the admin user account
#
# Prerequisites:
#   - Linux (tested on Arch and Ubuntu)
#   - Docker installed
#
# This script:
#   1. Creates the baudbot_agent user
#   2. Installs Node.js and pi
#   3. Sets up SSH key for GitHub
#   4. Installs the Docker wrapper
#   5. Installs the safe bash wrapper (tool deny list)
#   6. Configures sudoers
#   7. Creates runtime directories and deploys from source
#   8. Installs extension and bridge dependencies
#   9. Sets up firewall and makes it persistent
#  10. Enables /proc hidepid isolation (process visibility)
#  11. Makes ~/baudbot/ read-only to the agent
#
# ⚠️  If you add a step here, add the reverse to bin/uninstall.sh!
#
# After running, you still need to:
#   - Set the baudbot_agent password: sudo passwd baudbot_agent
#   - Add secrets to ~/.config/.env (see CONFIGURATION.md)
#   - Add the SSH public key to your GitHub account
#   - Add the admin user to baudbot_agent group (for file access): sudo usermod -aG baudbot_agent <admin_user>

set -euo pipefail

ADMIN_USER="${1:?Usage: $0 <admin_user>}"
BAUDBOT_HOME="/home/baudbot_agent"
# Source repo auto-detected from this script's location (can live anywhere)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_VERSION="22.14.0"

# Work from a neutral directory — sudo -u baudbot_agent inherits CWD, and
# git/find fail if CWD is a directory the agent can't access (e.g. /root).
cd /tmp

echo "=== Creating baudbot_agent user ==="
if id baudbot_agent &>/dev/null; then
  echo "User already exists, skipping"
else
  useradd -m -s /bin/bash baudbot_agent
  echo "User created. Run 'sudo passwd baudbot_agent' after setup."
fi
chmod 750 "$BAUDBOT_HOME"

echo "=== Ensuring .bashrc exists ==="
sudo -u baudbot_agent touch "$BAUDBOT_HOME/.bashrc"

echo "=== Adding $ADMIN_USER to baudbot_agent group ==="
usermod -aG baudbot_agent "$ADMIN_USER"

echo "=== Generating SSH key ==="
if [ ! -f "$BAUDBOT_HOME/.ssh/id_ed25519" ]; then
  sudo -u baudbot_agent bash -c '
    mkdir -p ~/.ssh
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    ssh-keygen -t ed25519 -C "baudbot-agent" -f ~/.ssh/id_ed25519 -N ""
    cat > ~/.ssh/config << SSHEOF
Host github.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
SSHEOF
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/id_ed25519 ~/.ssh/config
    chmod 644 ~/.ssh/id_ed25519.pub ~/.ssh/known_hosts
  '
  echo "SSH public key:"
  cat "$BAUDBOT_HOME/.ssh/id_ed25519.pub"
  echo "Add this to https://github.com/settings/keys for your agent's GitHub account"
else
  echo "SSH key already exists, skipping"
fi

echo "=== Installing Node.js $NODE_VERSION ==="
if [ ! -d "$BAUDBOT_HOME/opt/node-v$NODE_VERSION-linux-x64" ]; then
  sudo -u baudbot_agent bash -c "
    mkdir -p ~/opt
    curl -fsSL https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz -o /tmp/node.tar.xz
    tar xJf /tmp/node.tar.xz -C ~/opt/
    rm /tmp/node.tar.xz
  "
else
  echo "Node.js already installed, skipping"
fi

echo "=== Installing pi ==="
sudo -u baudbot_agent bash -c "
  export PATH=~/opt/node-v$NODE_VERSION-linux-x64/bin:\$PATH
  npm install -g @mariozechner/pi-coding-agent
"

echo "=== Configuring git identity ==="
GIT_USER_NAME="${GIT_USER_NAME:-baudbot-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-baudbot-agent@users.noreply.github.com}"
sudo -u baudbot_agent bash -c "
  git config --global user.name '$GIT_USER_NAME'
  git config --global user.email '$GIT_USER_EMAIL'
  git config --global init.defaultBranch main
"

echo "=== Configuring shared repo permissions ==="
# Set core.sharedRepository=group on all repos so git creates objects
# with group-write perms. Without this, umask 077 in start.sh causes
# new .git/objects to be owner-only, breaking group access (admin user).

# Source repo — set as admin user (agent can't access admin home, and root
# needs safe.directory due to different ownership)
if [ -d "$REPO_DIR/.git" ]; then
  sudo -u "$ADMIN_USER" git -C "$REPO_DIR" config core.sharedRepository group
  echo "  ✓ $REPO_DIR"
fi

# Agent workspace repos — set as agent
for repo in "$BAUDBOT_HOME/workspace/modem" "$BAUDBOT_HOME/workspace/website"; do
  if [ -d "$repo/.git" ]; then
    sudo -u baudbot_agent git -C "$repo" config core.sharedRepository group
    echo "  ✓ $repo"
  fi
done

echo "=== Adding PATH to bashrc ==="
if ! grep -q "node-v$NODE_VERSION" "$BAUDBOT_HOME/.bashrc"; then
  sudo -u baudbot_agent bash -c "echo 'export PATH=\$HOME/opt/node-v$NODE_VERSION-linux-x64/bin:\$PATH' >> ~/.bashrc"
fi

echo "=== Setting up secrets directory ==="
sudo -u baudbot_agent bash -c '
  mkdir -p ~/.config
  touch ~/.config/.env
  chmod 600 ~/.config/.env
'

echo "=== Installing pre-commit hook (root-owned, tamper-proof) ==="
cp "$REPO_DIR/hooks/pre-commit" "$REPO_DIR/.git/hooks/pre-commit"
chown root:root "$REPO_DIR/.git/hooks/pre-commit"
chmod 755 "$REPO_DIR/.git/hooks/pre-commit"
echo "Installed root-owned pre-commit hook — agent cannot modify protected security files"

echo "=== Installing Docker wrapper ==="
cp "$REPO_DIR/bin/baudbot-docker" /usr/local/bin/baudbot-docker
chown root:root /usr/local/bin/baudbot-docker
chmod 755 /usr/local/bin/baudbot-docker

echo "=== Installing safe bash wrapper ==="
cp "$REPO_DIR/bin/baudbot-safe-bash" /usr/local/bin/baudbot-safe-bash
chown root:root /usr/local/bin/baudbot-safe-bash
chmod 755 /usr/local/bin/baudbot-safe-bash
echo "Installed /usr/local/bin/baudbot-safe-bash (root-owned, not agent-writable)"

echo "=== Adding docker alias ==="
if ! grep -q "baudbot-docker" "$BAUDBOT_HOME/.bashrc"; then
  sudo -u baudbot_agent bash -c 'echo "alias docker=\"sudo /usr/local/bin/baudbot-docker\"" >> ~/.bashrc'
fi

echo "=== Configuring sudoers ==="
cat > /etc/sudoers.d/baudbot-agent << EOF
# Allow admin to manage baudbot
$ADMIN_USER ALL=(baudbot_agent) NOPASSWD: ALL

# Allow baudbot to use docker wrapper
baudbot_agent ALL=(root) NOPASSWD: /usr/local/bin/baudbot-docker
EOF
chmod 440 /etc/sudoers.d/baudbot-agent

echo "=== Setting up runtime directories ==="
# The agent runs from deployed copies, not from the source repo directly.
# Source: ~/baudbot/ (read-only to agent)
# Runtime: ~/.pi/agent/extensions/, ~/.pi/agent/skills/, ~/runtime/slack-bridge/
sudo -u baudbot_agent bash -c '
  mkdir -p ~/.pi/agent/extensions
  mkdir -p ~/.pi/agent/skills
  mkdir -p ~/.pi/agent/memory
  mkdir -p ~/runtime/slack-bridge
'

echo "=== Installing extension dependencies ==="
# npm install runs in source (admin-owned) then deploy copies to runtime
NODE_BIN="$BAUDBOT_HOME/opt/node-v$NODE_VERSION-linux-x64/bin"
export PATH="$NODE_BIN:$PATH"
while IFS= read -r dir; do
  echo "  Installing deps in $dir"
  (cd "$dir" && npm install)
done < <(find "$REPO_DIR/pi/extensions" -name package.json -not -path '*/node_modules/*' -exec dirname {} \;)

echo "=== Installing Slack bridge dependencies ==="
(cd "$REPO_DIR/slack-bridge" && npm install)

echo "=== Installing varlock ==="
if command -v varlock &>/dev/null; then
  echo "varlock already installed, skipping"
else
  curl -sSfL https://varlock.dev/install.sh | sh -s
fi

echo "=== Deploying from source to runtime ==="
# deploy.sh runs as admin (needs read access to source, write+chown to agent home).
# It copies extensions, skills, bridge, and utility scripts to runtime dirs.
"$REPO_DIR/bin/deploy.sh"
echo "Deployed extensions, skills, and bridge to runtime directories"

echo "=== Protecting source repo ==="
# Source is now admin-owned (outside baudbot_agent's home), so the agent
# cannot write to it by default. Tool-guard also blocks writes to REPO_DIR.
# If desired, a read-only bind mount can be added for defense-in-depth:
#   mount --bind "$REPO_DIR" "$REPO_DIR" && mount -o remount,bind,ro "$REPO_DIR"
echo "Source repo at $REPO_DIR is admin-owned (not writable by baudbot_agent)"

echo "=== Setting up firewall ==="
"$REPO_DIR/bin/setup-firewall.sh"

echo "=== Making firewall persistent ==="
sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/bin/baudbot-firewall.service" > /etc/systemd/system/baudbot-firewall.service
systemctl daemon-reload
systemctl enable baudbot-firewall
echo "Firewall will be restored on boot via systemd"

echo "=== Installing baudbot CLI ==="
if [ ! -f /usr/local/bin/baudbot ] || [ "$(readlink -f /usr/local/bin/baudbot 2>/dev/null)" != "$REPO_DIR/bin/baudbot" ]; then
  ln -sf "$REPO_DIR/bin/baudbot" /usr/local/bin/baudbot
  echo "Installed /usr/local/bin/baudbot → $REPO_DIR/bin/baudbot"
else
  echo "baudbot CLI already installed, skipping"
fi

echo "=== Installing baudbot systemd unit ==="
# Template the service file with the correct paths
sed \
  -e "s|/home/baudbot_agent|$BAUDBOT_HOME|g" \
  "$REPO_DIR/bin/baudbot.service" > /etc/systemd/system/baudbot.service
systemctl daemon-reload
systemctl enable baudbot
echo "Installed baudbot.service (enabled, not started)"
echo "Start with: baudbot start"

echo "=== Setting up /proc isolation (hidepid) ==="
# Create a group whose members can still see all processes.
# The admin user is added; baudbot_agent is NOT — it only sees its own processes.
PROC_GID_GROUP="procview"
if ! getent group "$PROC_GID_GROUP" &>/dev/null; then
  groupadd "$PROC_GID_GROUP"
  echo "Created group: $PROC_GID_GROUP"
fi
usermod -aG "$PROC_GID_GROUP" "$ADMIN_USER"
PROC_GID=$(getent group "$PROC_GID_GROUP" | cut -d: -f3)

# Apply immediately
mount -o remount,hidepid=2,gid="$PROC_GID" /proc
echo "Remounted /proc with hidepid=2,gid=$PROC_GID"

# Persist in /etc/fstab (idempotent)
if grep -q '^proc\s\+/proc' /etc/fstab; then
  # Update existing proc line
  sed -i "s|^proc\s\+/proc\s\+proc\s\+.*|proc /proc proc defaults,hidepid=2,gid=$PROC_GID 0 0|" /etc/fstab
  echo "Updated existing /proc entry in /etc/fstab"
else
  echo "proc /proc proc defaults,hidepid=2,gid=$PROC_GID 0 0" >> /etc/fstab
  echo "Added /proc entry to /etc/fstab"
fi
echo "Process isolation: baudbot_agent can only see its own processes"

echo "=== Hardening permissions ==="
sudo -u baudbot_agent bash -c "cd ~ && '$BAUDBOT_HOME/runtime/bin/harden-permissions.sh'"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Remaining manual steps:"
echo "  1. sudo passwd baudbot_agent"
echo "  2. Add secrets: sudo baudbot config"
echo "     Or manually edit: $BAUDBOT_HOME/.config/.env"
echo "  3. Add SSH key to your agent's GitHub account:"
echo "     cat $BAUDBOT_HOME/.ssh/id_ed25519.pub"
echo "  4. Log out and back in for group membership to take effect"
echo ""
echo "Commands:"
echo "  baudbot start        Start the agent"
echo "  baudbot stop         Stop the agent"
echo "  baudbot status       Check agent status"
echo "  baudbot logs         Tail agent logs"
echo "  baudbot deploy       Deploy source changes to agent runtime"
echo "  baudbot doctor       Health check"
echo "  baudbot audit        Security posture audit"
