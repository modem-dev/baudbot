#!/bin/bash
# Hornet Agent Setup Script
# Run as root or with sudo from the admin user account
#
# Prerequisites:
#   - Arch Linux (or similar)
#   - Docker installed
#
# This script:
#   1. Creates the hornet_agent user
#   2. Installs Node.js and pi
#   3. Sets up SSH key for GitHub
#   4. Installs the Docker wrapper
#   5. Installs the safe bash wrapper (tool deny list)
#   6. Configures sudoers
#   7. Creates runtime directories and deploys from source
#   8. Installs extension and bridge dependencies
#   9. Sets up firewall and makes it persistent
#  10. Enables /proc hidepid isolation (process visibility)
#  11. Makes ~/hornet/ read-only to the agent
#
# ⚠️  If you add a step here, add the reverse to bin/uninstall.sh!
#
# After running, you still need to:
#   - Set the hornet_agent password: sudo passwd hornet_agent
#   - Add secrets to ~/.config/.env (see CONFIGURATION.md)
#   - Add the SSH public key to your GitHub account
#   - Add the admin user to hornet_agent group (for file access): sudo usermod -aG hornet_agent <admin_user>

set -euo pipefail

ADMIN_USER="${1:?Usage: $0 <admin_user>}"
HORNET_HOME="/home/hornet_agent"
# Source repo auto-detected from this script's location (can live anywhere)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_VERSION="22.14.0"

echo "=== Creating hornet_agent user ==="
if id hornet_agent &>/dev/null; then
  echo "User already exists, skipping"
else
  useradd -m -s /bin/bash hornet_agent
  echo "User created. Run 'sudo passwd hornet_agent' after setup."
fi
chmod 750 "$HORNET_HOME"

echo "=== Ensuring .bashrc exists ==="
sudo -u hornet_agent touch "$HORNET_HOME/.bashrc"

echo "=== Adding $ADMIN_USER to hornet_agent group ==="
usermod -aG hornet_agent "$ADMIN_USER"

echo "=== Generating SSH key ==="
if [ ! -f "$HORNET_HOME/.ssh/id_ed25519" ]; then
  sudo -u hornet_agent bash -c '
    mkdir -p ~/.ssh
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    ssh-keygen -t ed25519 -C "hornet-agent" -f ~/.ssh/id_ed25519 -N ""
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
  cat "$HORNET_HOME/.ssh/id_ed25519.pub"
  echo "Add this to https://github.com/settings/keys for your agent's GitHub account"
else
  echo "SSH key already exists, skipping"
fi

echo "=== Installing Node.js $NODE_VERSION ==="
if [ ! -d "$HORNET_HOME/opt/node-v$NODE_VERSION-linux-x64" ]; then
  sudo -u hornet_agent bash -c "
    mkdir -p ~/opt
    curl -fsSL https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz -o /tmp/node.tar.xz
    tar xJf /tmp/node.tar.xz -C ~/opt/
    rm /tmp/node.tar.xz
  "
else
  echo "Node.js already installed, skipping"
fi

echo "=== Installing pi ==="
sudo -u hornet_agent bash -c "
  export PATH=~/opt/node-v$NODE_VERSION-linux-x64/bin:\$PATH
  npm install -g @mariozechner/pi-coding-agent
"

echo "=== Configuring git identity ==="
GIT_USER_NAME="${GIT_USER_NAME:-hornet-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-hornet-agent@users.noreply.github.com}"
sudo -u hornet_agent bash -c "
  git config --global user.name '$GIT_USER_NAME'
  git config --global user.email '$GIT_USER_EMAIL'
  git config --global init.defaultBranch main
"

echo "=== Configuring shared repo permissions ==="
# Set core.sharedRepository=group on all repos so git creates objects
# with group-write perms. Without this, umask 077 in start.sh causes
# new .git/objects to be owner-only, breaking group access (admin user).
for repo in "$REPO_DIR" "$HORNET_HOME/workspace/modem" "$HORNET_HOME/workspace/website"; do
  if [ -d "$repo/.git" ]; then
    sudo -u hornet_agent git -C "$repo" config core.sharedRepository group
    echo "  ✓ $repo"
  fi
done

echo "=== Adding PATH to bashrc ==="
if ! grep -q "node-v$NODE_VERSION" "$HORNET_HOME/.bashrc"; then
  sudo -u hornet_agent bash -c "echo 'export PATH=\$HOME/opt/node-v$NODE_VERSION-linux-x64/bin:\$PATH' >> ~/.bashrc"
fi

echo "=== Setting up secrets directory ==="
sudo -u hornet_agent bash -c '
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
cp "$REPO_DIR/bin/hornet-docker" /usr/local/bin/hornet-docker
chown root:root /usr/local/bin/hornet-docker
chmod 755 /usr/local/bin/hornet-docker

echo "=== Installing safe bash wrapper ==="
cp "$REPO_DIR/bin/hornet-safe-bash" /usr/local/bin/hornet-safe-bash
chown root:root /usr/local/bin/hornet-safe-bash
chmod 755 /usr/local/bin/hornet-safe-bash
echo "Installed /usr/local/bin/hornet-safe-bash (root-owned, not agent-writable)"

echo "=== Adding docker alias ==="
if ! grep -q "hornet-docker" "$HORNET_HOME/.bashrc"; then
  sudo -u hornet_agent bash -c 'echo "alias docker=\"sudo /usr/local/bin/hornet-docker\"" >> ~/.bashrc'
fi

echo "=== Configuring sudoers ==="
cat > /etc/sudoers.d/hornet-agent << EOF
# Allow admin to manage hornet
$ADMIN_USER ALL=(hornet_agent) NOPASSWD: ALL

# Allow hornet to use docker wrapper
hornet_agent ALL=(root) NOPASSWD: /usr/local/bin/hornet-docker
EOF
chmod 440 /etc/sudoers.d/hornet-agent

echo "=== Setting up runtime directories ==="
# The agent runs from deployed copies, not from the source repo directly.
# Source: ~/hornet/ (read-only to agent)
# Runtime: ~/.pi/agent/extensions/, ~/.pi/agent/skills/, ~/runtime/slack-bridge/
sudo -u hornet_agent bash -c '
  mkdir -p ~/.pi/agent/extensions
  mkdir -p ~/.pi/agent/skills
  mkdir -p ~/runtime/slack-bridge
'

echo "=== Installing extension dependencies ==="
# npm install runs in source (admin-owned) then deploy copies to runtime
NODE_BIN="$HORNET_HOME/opt/node-v$NODE_VERSION-linux-x64/bin"
export PATH="$NODE_BIN:$PATH"
for dir in $(find "$REPO_DIR/pi/extensions" -name package.json -not -path '*/node_modules/*' -exec dirname {} \;); do
  echo "  Installing deps in $dir"
  (cd "$dir" && npm install)
done

echo "=== Installing Slack bridge dependencies ==="
(cd "$REPO_DIR/slack-bridge" && npm install)

echo "=== Deploying from source to runtime ==="
# deploy.sh runs as admin (needs read access to source, write+chown to agent home).
# It copies extensions, skills, bridge, and utility scripts to runtime dirs.
"$REPO_DIR/bin/deploy.sh"
echo "Deployed extensions, skills, and bridge to runtime directories"

echo "=== Protecting source repo ==="
# Source is now admin-owned (outside hornet_agent's home), so the agent
# cannot write to it by default. Tool-guard also blocks writes to REPO_DIR.
# If desired, a read-only bind mount can be added for defense-in-depth:
#   mount --bind "$REPO_DIR" "$REPO_DIR" && mount -o remount,bind,ro "$REPO_DIR"
echo "Source repo at $REPO_DIR is admin-owned (not writable by hornet_agent)"

echo "=== Setting up firewall ==="
"$REPO_DIR/bin/setup-firewall.sh"

echo "=== Making firewall persistent ==="
sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/bin/hornet-firewall.service" > /etc/systemd/system/hornet-firewall.service
systemctl daemon-reload
systemctl enable hornet-firewall
echo "Firewall will be restored on boot via systemd"

echo "=== Setting up /proc isolation (hidepid) ==="
# Create a group whose members can still see all processes.
# The admin user is added; hornet_agent is NOT — it only sees its own processes.
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
echo "Process isolation: hornet_agent can only see its own processes"

echo "=== Hardening permissions ==="
sudo -u hornet_agent bash -c "'$REPO_DIR/bin/harden-permissions.sh'"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Remaining manual steps:"
echo "  1. sudo passwd hornet_agent"
echo "  2. Add secrets to $HORNET_HOME/.config/.env:"
echo "     GITHUB_TOKEN=..."
echo "     OPENCODE_ZEN_API_KEY=..."
echo "     AGENTMAIL_API_KEY=..."
echo "     KERNEL_API_KEY=..."
echo "     HORNET_SECRET=..."
echo "     SLACK_BOT_TOKEN=..."
echo "     SLACK_APP_TOKEN=..."
echo "     SLACK_ALLOWED_USERS=U...  (REQUIRED — bridge refuses to start without this)"
echo "     SENTRY_CHANNEL_ID=C...  (Slack channel ID for Sentry alerts)"
echo "     SENTRY_ORG=...  (Sentry organization slug)"
echo "     HORNET_EMAIL=...  (AgentMail address for email monitor)"
echo "     HORNET_ALLOWED_EMAILS=you@example.com  (comma-separated sender allowlist)"
echo "     HORNET_SOURCE_DIR=$REPO_DIR  (admin source repo path, for tool-guard)"
echo "  3. Add SSH key to your agent's GitHub account"
echo "  4. Log out and back in for group membership to take effect"
echo "     (both hornet_agent group and procview group)"
echo "  5. Launch: sudo -u hornet_agent ~/runtime/start.sh"
echo ""
echo "To update runtime after editing source:"
echo "  $REPO_DIR/bin/deploy.sh"
echo ""
echo "To verify security posture:"
echo "  $REPO_DIR/bin/security-audit.sh"
