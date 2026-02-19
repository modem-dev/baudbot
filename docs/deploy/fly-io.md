# Deploy Baudbot on Fly.io

This guide walks through deploying baudbot on Fly.io using Fly Machines — fast-launching VMs with persistent volume storage. Fly.io is a good fit for baudbot if you want per-second billing, global region options, and infrastructure-as-code style management through the `fly` CLI.

## Important: Fly.io is not a traditional VPS

Fly.io runs your workloads as Docker containers inside Firecracker microVMs. This means:

- You need a **Dockerfile** to define the Machine image
- Persistent data must live on a **Fly Volume** (the root filesystem is ephemeral and resets on redeploy)
- The Machine can be stopped/started, but redeploys replace the root filesystem
- You manage everything through the `fly` CLI or the Machines REST API

Baudbot's installer expects a standard Linux server with `apt`, `systemd`, and full root access. To make this work on Fly.io, you'll run a long-lived Machine with an attached volume for persistent state.

## Prerequisites

- A [Fly.io account](https://fly.io/app/sign-up) with a credit card on file
- The `flyctl` CLI installed:
  ```bash
  # macOS
  brew install flyctl

  # Linux
  curl -L https://fly.io/install.sh | sh
  ```
- Authenticated with Fly.io:
  ```bash
  fly auth login
  ```
- API keys ready for configuration (see [CONFIGURATION.md](../../CONFIGURATION.md)):
  - At least one LLM API key (Anthropic, OpenAI, Gemini, or OpenCode Zen)
  - Slack app tokens (bot token + app-level token)
  - GitHub account for the agent

## System requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 2 shared vCPU | 4 shared vCPU or 2 performance vCPU |
| RAM | 4 GB | 8 GB |
| Volume | 20 GB | 40 GB |

## Step 1: Create the app and volume

Create a Fly app (this is a logical container — no Machine is running yet):

```bash
fly apps create baudbot --org personal
```

> Replace `personal` with your Fly.io organization name if applicable.

Create a persistent volume in your preferred region:

```bash
# List available regions
fly platform regions

# Create a 40 GB volume (adjust size as needed)
fly volumes create baudbot_data --region iad --size 40 --app baudbot
```

> **Important**: The volume and Machine must be in the same region. Choose one close to you. Common regions: `iad` (Virginia), `ord` (Chicago), `lax` (LA), `lhr` (London), `fra` (Frankfurt), `nrt` (Tokyo).

## Step 2: Create the Dockerfile

Baudbot needs a full Ubuntu environment with systemd support. Create a `Dockerfile` for the Machine:

```dockerfile
FROM ubuntu:24.04

# Prevent interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies (baudbot install.sh will install the rest,
# but these are needed for the install script itself to run)
RUN apt-get update && apt-get install -y \
    git curl tmux iptables sudo docker.io gh \
    openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone baudbot source
RUN git clone https://github.com/modem-dev/baudbot.git /root/baudbot

# Create a startup script that handles volume-backed persistent state
COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
```

Create the `start.sh` entrypoint script:

```bash
#!/bin/bash
set -euo pipefail

VOLUME="/data"
BAUDBOT_HOME="/home/baudbot_agent"

# First-run: run the baudbot installer
if [ ! -f "$VOLUME/.baudbot-installed" ]; then
  echo "=== First run: installing baudbot ==="
  /root/baudbot/setup.sh root
  touch "$VOLUME/.baudbot-installed"

  # Move agent home to the volume so state persists across redeploys
  if [ -d "$BAUDBOT_HOME" ] && [ ! -L "$BAUDBOT_HOME" ]; then
    cp -a "$BAUDBOT_HOME" "$VOLUME/baudbot_agent_home"
  fi
fi

# Symlink agent home to volume (survives root filesystem replacement)
if [ -d "$VOLUME/baudbot_agent_home" ] && [ ! -L "$BAUDBOT_HOME" ]; then
  rm -rf "$BAUDBOT_HOME"
  ln -sf "$VOLUME/baudbot_agent_home" "$BAUDBOT_HOME"
fi

# Symlink source repo to volume for persistence
if [ ! -d "$VOLUME/baudbot-source" ]; then
  cp -a /root/baudbot "$VOLUME/baudbot-source"
fi
rm -rf /root/baudbot
ln -sf "$VOLUME/baudbot-source" /root/baudbot

# Re-run hardening and firewall on each boot
"$BAUDBOT_HOME/runtime/bin/harden-permissions.sh" 2>/dev/null || true
/root/baudbot/bin/setup-firewall.sh 2>/dev/null || true

# Start the agent in the foreground (keeps the Machine alive)
exec sudo -u baudbot_agent "$BAUDBOT_HOME/runtime/start.sh"
```

## Step 3: Configure the fly.toml

Create `fly.toml` in the same directory as your Dockerfile:

```toml
app = "baudbot"

[build]
  dockerfile = "Dockerfile"

[mounts]
  source = "baudbot_data"
  destination = "/data"

[[vm]]
  size = "shared-cpu-4x"
  memory = 4096       # 4 GB — increase to 8192 for heavier workloads

# No HTTP services needed — baudbot communicates outbound only
# (Slack Socket Mode, SSH for git, HTTPS for APIs)
```

> **Note**: Baudbot does not need any `[[services]]` or `[[http_service]]` blocks. It connects outbound to Slack via WebSocket and to GitHub via SSH/HTTPS. No inbound ports are required.

## Step 4: Set secrets

Store sensitive configuration as Fly.io secrets (available as environment variables inside the Machine):

```bash
# LLM API key (set at least one)
fly secrets set ANTHROPIC_API_KEY=sk-ant-... --app baudbot

# Slack
fly secrets set SLACK_BOT_TOKEN=xoxb-... --app baudbot
fly secrets set SLACK_APP_TOKEN=xapp-... --app baudbot
fly secrets set SLACK_ALLOWED_USERS=U01ABCDEF,U02GHIJKL --app baudbot

# Email (optional)
fly secrets set AGENTMAIL_API_KEY=... --app baudbot
fly secrets set BAUDBOT_EMAIL=my-agent@agentmail.to --app baudbot
fly secrets set BAUDBOT_SECRET=$(openssl rand -hex 32) --app baudbot

# List configured secrets (values are hidden)
fly secrets list --app baudbot
```

> **Important**: Fly.io secrets are injected as environment variables at Machine boot. Baudbot's installer also writes secrets to `~/.config/.env`. For the Fly.io deployment, you should populate both — the Fly secrets for the Machine environment and the `.env` file for the agent processes that read it directly. After first boot, SSH in and run `sudo baudbot config` to populate the `.env` file.

## Step 5: Deploy

```bash
fly deploy --app baudbot
```

This builds the Docker image, pushes it to Fly.io's registry, creates a Machine with the attached volume, and starts it.

Watch the deploy:

```bash
fly logs --app baudbot
```

## Step 6: Post-deploy setup

SSH into the running Machine to complete setup:

```bash
fly ssh console --app baudbot
```

Inside the Machine:

```bash
# Add the agent's SSH key to your GitHub account
cat /home/baudbot_agent/.ssh/id_ed25519.pub
# Copy and add at https://github.com/settings/keys

# Authenticate the GitHub CLI
sudo -u baudbot_agent gh auth login

# Populate the .env file (if not done during install)
sudo baudbot config
sudo baudbot deploy

# Verify everything is running
sudo baudbot doctor
sudo baudbot status
```

## Monitoring

### Logs

```bash
# Stream live logs
fly logs --app baudbot

# SSH in and check directly
fly ssh console --app baudbot
journalctl -u baudbot -f
sudo baudbot logs
```

### Machine status

```bash
# Check Machine state
fly machine list --app baudbot

# Get detailed Machine info
fly machine status <machine-id> --app baudbot
```

### Fly.io Metrics

Fly.io provides built-in metrics in the dashboard at [fly.io/apps/baudbot/monitoring](https://fly.io/apps/baudbot/monitoring), covering CPU, memory, and network usage.

## Networking

Baudbot on Fly.io communicates entirely outbound:

- **Slack**: Socket Mode WebSocket over port 443 (outbound)
- **GitHub**: SSH (port 22) and HTTPS (port 443) outbound
- **LLM APIs**: HTTPS (port 443) outbound
- **No inbound ports needed**: No `[[services]]` required in fly.toml

Fly Machines have unrestricted outbound networking by default. Baudbot's built-in iptables firewall adds per-user egress restrictions for the `baudbot_agent` user once set up.

### Private networking

If you run other services on Fly.io (databases, etc.), they can communicate over Fly's private WireGuard network (`.flycast` addresses, `fly-local-6pn` for IPv6) without traversing the public internet.

## Cost estimate

| Component | Spec | Monthly cost |
|-----------|------|-------------|
| **Machine (minimum)** | `shared-cpu-2x` / 4 GB | ~$21/mo |
| **Machine (recommended)** | `shared-cpu-4x` / 4 GB | ~$23/mo |
| **Machine (performance)** | `performance-2x` / 4 GB | ~$62/mo |
| Volume (40 GB) | Persistent storage | $6/mo |
| Volume snapshots | First 10 GB free | ~$0.08/GB/mo |
| Dedicated IPv4 (if needed) | Static IP | $2/mo |
| **Total (shared, minimum)** | | **~$27/mo** |
| **Total (shared, recommended)** | | **~$29/mo** |
| **Total (performance)** | | **~$68/mo** |

Billing is per-second. If you stop the Machine, you pay only for stopped rootfs storage ($0.15/GB/mo) plus the volume. Check [fly.io/docs/about/pricing](https://fly.io/docs/about/pricing/) for current rates.

> **Tip**: Fly.io offers reservation blocks for 40% savings on committed compute. A $36/year shared Machines block gives $5/mo in credits.

## Platform-specific tips

- **Volume backups**: Fly Volumes get automatic daily snapshots with 5-day retention by default. Check snapshots with `fly volumes snapshots list --app baudbot`.
- **Don't use autostop**: Baudbot is an always-on agent. Make sure your fly.toml does not configure `auto_stop_machines` or `auto_start_machines` — the Machine should run continuously.
- **Redeployment replaces root filesystem**: When you `fly deploy`, the root filesystem is rebuilt from the Docker image. All persistent state must live on the volume (`/data`). The `start.sh` script handles this by symlinking the agent home to the volume.
- **Scale vertically**: Change Machine size without redeploying:
  ```bash
  fly machine update <machine-id> --vm-size shared-cpu-4x --vm-memory 8192 --app baudbot
  ```
- **Region selection matters**: Pick a region close to you for lower latency when SSHing in. Baudbot's API calls go to external services, so the region has minimal impact on agent performance.
- **WireGuard tunnels**: For secure access without SSH, set up a Fly.io WireGuard tunnel: `fly wireguard create`. This lets you access the Machine's private IPv6 address directly.

## Updating baudbot

```bash
# SSH into the Machine
fly ssh console --app baudbot

# Update from git
sudo baudbot update

# Or rollback
sudo baudbot rollback previous
```

Alternatively, update the Dockerfile to pull a newer version and redeploy with `fly deploy`. The volume preserves agent state across redeploys.

## Stopping and destroying

```bash
# Stop the Machine (keeps volume, stops compute billing)
fly machine stop <machine-id> --app baudbot

# Start it back up
fly machine start <machine-id> --app baudbot

# Destroy everything (irreversible)
fly apps destroy baudbot
```

> **Warning**: `fly apps destroy` deletes the app, all Machines, and all volumes. All data is lost.
