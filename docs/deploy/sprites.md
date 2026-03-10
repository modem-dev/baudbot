# Deploy Baudbot on Sprites.dev

This guide walks through deploying baudbot on [Sprites.dev](https://sprites.dev) — persistent, hardware-isolated Linux microVMs from the team behind Fly.io. Sprites are a good fit for baudbot because they provide a full, persistent Ubuntu environment with automatic idle/wake behavior and granular per-second billing.

## What is Sprites?

Sprites are stateful sandbox environments — essentially persistent Linux computers that hibernate when idle and wake on demand. Key properties:

- **Full Ubuntu 24.04 LTS** with Node.js, Python, Go, Git, and common dev tools preinstalled
- **Persistent ext4 filesystem**: files, installed packages, and data survive across sessions (unlike containers)
- **Hardware isolation**: each Sprite runs in a Firecracker microVM
- **Automatic idle behavior**: Sprites sleep when inactive and wake on the next command or HTTP request (~100–500ms warm, 1–2s cold)
- **Up to 8 CPUs and 16 GB RAM** dynamically available per Sprite
- **100 GB persistent storage** per Sprite
- **Checkpoint and restore**: snapshot your entire filesystem and roll back if needed

Sprites use your Fly.io account for authentication.

## Prerequisites

- A [Fly.io account](https://fly.io/app/sign-up) (Sprites uses Fly.io authentication)
- The `sprite` CLI installed:
  ```bash
  curl -fsSL https://sprites.dev/install.sh | sh
  ```
  This auto-detects your platform and installs to `~/.local/bin`.
- Authenticated:
  ```bash
  sprite org auth
  # Opens a browser to authenticate via Fly.io
  ```
- API keys ready for configuration (see [CONFIGURATION.md](../../CONFIGURATION.md)):
  - At least one LLM API key (Anthropic, OpenAI, Gemini, or OpenCode Zen)
  - Slack app tokens (bot token + app-level token)
  - GitHub account for the agent

## System requirements

Sprites provide up to 8 CPUs and 16 GB RAM dynamically — you don't choose a fixed plan. Baudbot will use what it needs:

| Resource | Baudbot needs | Sprites provides |
|----------|--------------|-----------------|
| OS | Ubuntu 24.04 | ✅ Preinstalled |
| RAM | 4–8 GB | Up to 16 GB |
| CPU | 2–4 vCPU | Up to 8 vCPU |
| Disk | 20–40 GB | 100 GB |
| Node.js | v22+ | ✅ Preinstalled |
| Git | Any | ✅ Preinstalled |

> **Note on always-on behavior**: Sprites automatically hibernate when idle to save costs. For an always-on agent like baudbot, you'll need a mechanism to keep the Sprite awake or accept that it may sleep between tasks. See [Keeping baudbot alive](#keeping-baudbot-alive) below.

## Step 1: Create the Sprite

```bash
sprite create baudbot
```

Set it as your active Sprite to avoid passing `-s baudbot` to every command:

```bash
sprite use baudbot
```

Verify it's running:

```bash
sprite list
```

## Step 2: Install system prerequisites

Sprites come with Node.js, Python, Go, and Git preinstalled. You need to install the remaining dependencies that baudbot's installer expects:

```bash
sprite exec sudo apt-get update
sprite exec sudo apt-get install -y tmux iptables docker.io gh sudo curl
```

## Step 3: Clone and install baudbot

```bash
# Clone the repo
sprite exec git clone https://github.com/modem-dev/baudbot.git /root/baudbot

# Run the installer
# Note: install.sh is interactive, so use a console session
sprite console
```

Inside the console:

```bash
sudo /root/baudbot/install.sh
```

The installer will:
- Detect Ubuntu 24.04
- Create the `baudbot_agent` user
- Install Node.js (baudbot's own version, separate from the preinstalled one)
- Generate an SSH key for GitHub
- Set up the firewall and process isolation
- Walk you through secrets configuration
- Deploy the agent runtime

When it finishes, complete the manual steps:

```bash
# 1. Copy the agent's SSH public key
cat /home/baudbot_agent/.ssh/id_ed25519.pub
# Add it at https://github.com/settings/keys

# 2. Authenticate the GitHub CLI
sudo -u baudbot_agent gh auth login
# Follow the device code flow

# Exit the console when done
exit
```

## Step 4: Configure secrets

If you skipped secrets during install:

```bash
sprite console
```

Inside:

```bash
sudo baudbot config
sudo baudbot deploy
```

Or edit the `.env` file directly:

```bash
sudo nano /home/baudbot_agent/.config/.env
sudo baudbot deploy
```

See [CONFIGURATION.md](../../CONFIGURATION.md) for all environment variables.

## Step 5: Start baudbot

```bash
sprite console
```

Inside:

```bash
sudo baudbot start
sudo baudbot status
sudo baudbot doctor
```

### Keeping baudbot alive

Sprites hibernate when there's no active process or connection. Since baudbot is an always-on agent, you need the Sprite to stay awake while baudbot is running. Two approaches:

#### Option A: Use Sprites Services (recommended)

Sprites has a built-in service manager that auto-restarts processes when the Sprite wakes:

```bash
sprite exec sprite-env services create baudbot-agent \
  --cmd sudo \
  --args "-u baudbot_agent /home/baudbot_agent/runtime/start.sh"
```

This ensures baudbot restarts automatically whenever the Sprite wakes from hibernation (e.g., when a Slack message triggers outbound activity). The Sprite will still hibernate when idle — baudbot's Slack connection will drop — but it will restart quickly when woken.

> **Trade-off**: With this approach, there will be a brief delay (seconds) when the Sprite wakes from hibernation before baudbot reconnects to Slack. For most teams this is acceptable. If you need instant response times, see Option B.

#### Option B: Keep a persistent session

Start baudbot in a detachable TTY session:

```bash
sprite exec -tty bash -c "sudo -u baudbot_agent /home/baudbot_agent/runtime/start.sh"
# The Sprite stays awake as long as this session is active
# Press Ctrl+\ to detach (keeps running)
```

List and reattach to sessions:

```bash
sprite sessions list
sprite sessions attach <session-id>
```

> **Note**: TTY sessions keep the Sprite awake and billing active. This gives you always-on behavior but at continuous compute cost.

## Networking

### Outbound (what baudbot needs)

Baudbot communicates entirely outbound:

- **Slack**: Socket Mode WebSocket over port 443
- **GitHub**: SSH (22) and HTTPS (443)
- **LLM APIs**: HTTPS (443)

Sprites have outbound internet access by default. Baudbot's built-in iptables firewall restricts the `baudbot_agent` user's egress to an allowlist.

### Inbound (not needed)

Baudbot does not need inbound connections. Sprites provide a public URL (`https://baudbot.sprites.app`) per Sprite, but you don't need to use it for baudbot.

If you do want to expose the control plane or any debug interface, Sprites route HTTP traffic to port 8080 by default:

```bash
# Check your Sprite's URL
sprite url

# Make it public (only if needed)
sprite url update --auth public
```

### Port forwarding for debugging

Forward ports from the Sprite to your local machine:

```bash
# Forward the Slack bridge port for debugging
sprite proxy 7890

# Forward multiple ports
sprite proxy 7890 9229
```

## Monitoring

### Check agent status

```bash
# Quick status check
sprite exec sudo baudbot status

# Full health check
sprite exec sudo baudbot doctor

# View recent logs
sprite exec sudo baudbot logs
```

### Interactive debugging

```bash
# Open a console
sprite console

# Inside, check processes and resources
ps aux | grep baudbot
df -h
free -h
journalctl -u baudbot --no-pager -n 50
```

### Sprite resource usage

```bash
sprite exec df -h     # disk space
sprite exec free -h   # memory
sprite exec ps aux    # processes
```

## Checkpoints (backups)

Sprites support filesystem checkpoints — full snapshots you can restore to:

```bash
# Create a checkpoint before updates
sprite checkpoint create --comment "before baudbot update"

# List checkpoints
sprite checkpoint list

# Restore to a checkpoint (replaces entire filesystem)
sprite restore <checkpoint-id>
```

> **Tip**: Always create a checkpoint before running `baudbot update` or making significant changes.

## Cost estimate

Sprites bill per-second for actual resource usage — you pay for CPU cycles, resident memory, and storage. Costs depend heavily on how active the agent is.

### Estimate: Moderate usage (handles ~10–20 tasks/day)

Assuming baudbot is awake ~12 hours/day, averaging 30% of 2 CPUs and 2 GB RAM, with idle time between tasks:

| Resource | Usage | Monthly cost |
|----------|-------|-------------|
| CPU | ~7.2 CPU-hrs/day × 30 days | ~$15.12 |
| Memory | ~24 GB-hrs/day × 30 days | ~$31.50 |
| Hot storage | 20 GB × ~360 hrs | ~$4.92 |
| Cold storage | 20 GB × ~372 hrs | ~$0.20 |
| **Total** | | **~$52/mo** |

### Estimate: Light usage (handles ~3–5 tasks/day)

Assuming baudbot is awake ~4 hours/day with the Sprite sleeping the rest:

| Resource | Usage | Monthly cost |
|----------|-------|-------------|
| CPU | ~2.4 CPU-hrs/day × 30 days | ~$5.04 |
| Memory | ~6 GB-hrs/day × 30 days | ~$7.88 |
| Hot storage | 20 GB × ~120 hrs | ~$1.64 |
| Cold storage | 20 GB × ~612 hrs | ~$0.33 |
| **Total** | | **~$15/mo** |

### Estimate: Always-on (persistent session)

If you keep a persistent session so the Sprite never sleeps, averaging 20% of 2 CPUs and 2 GB RAM continuously:

| Resource | Usage | Monthly cost |
|----------|-------|-------------|
| CPU | ~288 CPU-hrs/mo | ~$20.16 |
| Memory | ~1,464 GB-hrs/mo | ~$64.05 |
| Hot storage | 20 GB × 732 hrs | ~$10.00 |
| **Total** | | **~$94/mo** |

Pricing is usage-based. New accounts get $30 in trial credits. Check [sprites.dev](https://sprites.dev) for current rates.

> **Tip**: The idle/wake model can save significant money if your team doesn't need 24/7 instant response. Sprites wake in 100ms–2s, so the delay is minimal.

## Platform-specific tips

- **Sprites are persistent by default**: Unlike containers, everything you install or create stays. No need for Dockerfiles or volume management. This makes Sprites the simplest deployment option for baudbot.
- **Use checkpoints before risky changes**: `sprite checkpoint create --comment "pre-update"` gives you a one-command rollback path.
- **Services for auto-restart**: Use `sprite-env services create` to register baudbot as a service that starts automatically on wake. This is the recommended way to keep baudbot running across hibernate cycles.
- **SSHFS for local editing**: Mount the Sprite's filesystem locally for editing config files with your local editor. See the [Sprites docs on SSHFS](https://docs.sprites.dev/working-with-sprites/#mounting-filesystem-locally).
- **Storage is generous**: Each Sprite has 100 GB. You have plenty of room for repos, build artifacts, and Docker images.
- **Sprites run Ubuntu 24.04**: This matches baudbot's recommended OS exactly. No image selection or configuration needed.
- **TTY detach/reattach**: Press `Ctrl+\` to detach from a running session. Use `sprite sessions list` and `sprite sessions attach <id>` to reconnect.
- **Docker**: Sprites support Docker inside the VM. baudbot's guarded Docker wrapper (`baudbot-docker`) works as expected.

## Updating baudbot

```bash
sprite console
```

Inside:

```bash
# Create a checkpoint first
# (run this from your local machine)
# sprite checkpoint create --comment "before update"

sudo baudbot update

# Verify
sudo baudbot status
sudo baudbot doctor
```

Or from outside the Sprite:

```bash
sprite checkpoint create --comment "before update"
sprite exec sudo baudbot update
sprite exec sudo baudbot status
```

## Destroying the Sprite

```bash
sprite destroy -s baudbot
```

> **Warning**: Destruction is irreversible. All data, files, packages, and checkpoints are permanently deleted. Create a checkpoint first if you want to preserve anything.
