#!/bin/bash
# Hornet Agent Setup Script
# Run as root or with sudo from the admin user account
#
# Prerequisites:
#   - Arch Linux (or similar)
#   - Docker installed
#   - Node.js available in system PATH or will be installed
#
# This script:
#   1. Creates the hornet_agent user
#   2. Installs Node.js and pi
#   3. Sets up SSH key for GitHub
#   4. Installs the Docker wrapper
#   5. Configures sudoers
#   6. Symlinks pi config from the repo
#
# After running, you still need to:
#   - Set the hornet_agent password: sudo passwd hornet_agent
#   - Add secrets to ~/.config/.env (GITHUB_TOKEN, OPENCODE_ZEN_API_KEY, etc.)
#   - Add the SSH public key to the hornet-fw GitHub account
#   - Add the admin user to hornet_agent group (for file access): sudo usermod -aG hornet_agent <admin_user>

set -euo pipefail

ADMIN_USER="${1:?Usage: $0 <admin_user>}"
HORNET_HOME="/home/hornet_agent"
REPO_DIR="$HORNET_HOME/hornet"
NODE_VERSION="22.14.0"

echo "=== Creating hornet_agent user ==="
if id hornet_agent &>/dev/null; then
  echo "User already exists, skipping"
else
  useradd -m -s /bin/bash hornet_agent
  echo "User created. Run 'sudo passwd hornet_agent' after setup."
fi
chmod 750 "$HORNET_HOME"

echo "=== Adding $ADMIN_USER to hornet_agent group ==="
usermod -aG hornet_agent "$ADMIN_USER"

echo "=== Generating SSH key ==="
if [ ! -f "$HORNET_HOME/.ssh/id_ed25519" ]; then
  sudo -u hornet_agent bash -c '
    mkdir -p ~/.ssh
    ssh-keygen -t ed25519 -C "hornet-fw" -f ~/.ssh/id_ed25519 -N ""
    cat > ~/.ssh/config << SSHEOF
Host github.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
SSHEOF
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/id_ed25519 ~/.ssh/config
    chmod 644 ~/.ssh/id_ed25519.pub
  '
  echo "SSH public key:"
  cat "$HORNET_HOME/.ssh/id_ed25519.pub"
  echo "Add this to https://github.com/settings/keys for the hornet-fw account"
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
sudo -u hornet_agent bash -c '
  git config --global user.name "hornet-fw"
  git config --global user.email "hornet@modem.codes"
  git config --global init.defaultBranch main
'

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

echo "=== Installing Docker wrapper ==="
cp "$REPO_DIR/bin/hornet-docker" /usr/local/bin/hornet-docker
chown root:root /usr/local/bin/hornet-docker
chmod 755 /usr/local/bin/hornet-docker

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

echo "=== Symlinking pi config from repo ==="
sudo -u hornet_agent bash -c '
  mkdir -p ~/.pi/agent
  # Remove existing and symlink
  rm -rf ~/.pi/agent/skills ~/.pi/agent/extensions
  ln -sf ~/hornet/pi/skills ~/.pi/agent/skills
  ln -sf ~/hornet/pi/extensions ~/.pi/agent/extensions
  cp ~/hornet/pi/settings.json ~/.pi/agent/settings.json
'

echo "=== Installing extension dependencies ==="
sudo -u hornet_agent bash -c "
  export PATH=~/opt/node-v$NODE_VERSION-linux-x64/bin:\$PATH
  for dir in \$(find ~/hornet/pi/extensions -name package.json -not -path '*/node_modules/*' -exec dirname {} \;); do
    echo \"  Installing deps in \$dir\"
    cd \"\$dir\" && npm install
  done
"

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
echo "  3. Add SSH key to hornet-fw GitHub account"
echo "  4. Log out and back in for group membership to take effect"
echo "  5. Launch: sudo -u hornet_agent $HORNET_HOME/hornet/start.sh"
