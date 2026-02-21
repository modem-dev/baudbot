# Deploy Baudbot on DigitalOcean

This guide walks through deploying baudbot on a DigitalOcean Droplet — a Linux virtual machine with dedicated resources and a static IP. Droplets are a good fit for baudbot because they give you a full Linux server with root access, persistent storage, and straightforward networking.

## Prerequisites

- A [DigitalOcean account](https://cloud.digitalocean.com/registrations/new) with a payment method on file
- An SSH key pair on your local machine (`ssh-keygen -t ed25519` if you don't have one)
- Your SSH public key uploaded to DigitalOcean: **Settings → Security → SSH Keys → Add SSH Key**
- API keys ready for configuration (see [CONFIGURATION.md](../../CONFIGURATION.md)):
  - At least one LLM API key (Anthropic, OpenAI, Gemini, or OpenCode Zen)
  - Slack app tokens (bot token + app-level token)
  - GitHub account for the agent

## System requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| RAM | 4 GB | 8 GB |
| CPU | 2 vCPU | 4 vCPU |
| Disk | 20 GB SSD | 40 GB+ SSD |

## Step 1: Create the Droplet

### Option A: DigitalOcean Console

1. Log in to [cloud.digitalocean.com](https://cloud.digitalocean.com)
2. Click **Create → Droplets**
3. **Region**: Choose the datacenter nearest to you (e.g. `nyc1`, `sfo3`, `ams3`)
4. **Image**: Ubuntu 24.04 (LTS) x64
5. **Size**: Basic → Regular → **4 GB / 2 vCPUs / 80 GB SSD ($24/mo)** or **8 GB / 4 vCPUs / 160 GB SSD ($48/mo)**
6. **Authentication**: Select your SSH key
7. **Hostname**: `baudbot` (or whatever you prefer)
8. Click **Create Droplet**

### Option B: `doctl` CLI

Install the DigitalOcean CLI:

```bash
# macOS
brew install doctl

# Linux (snap)
sudo snap install doctl

# Or download from https://docs.digitalocean.com/reference/doctl/how-to/install/
```

Authenticate:

```bash
doctl auth init
# Paste your API token from https://cloud.digitalocean.com/account/api/tokens
```

Create the Droplet:

```bash
# List your SSH key fingerprints
doctl compute ssh-key list

# Create a 4 GB / 2 vCPU Droplet (Basic, Regular)
doctl compute droplet create baudbot \
  --image ubuntu-24-04-x64 \
  --size s-2vcpu-4gb \
  --region nyc1 \
  --ssh-keys <your-ssh-key-fingerprint> \
  --wait

# Or 8 GB / 4 vCPU for heavier workloads
doctl compute droplet create baudbot \
  --image ubuntu-24-04-x64 \
  --size s-4vcpu-8gb \
  --region nyc1 \
  --ssh-keys <your-ssh-key-fingerprint> \
  --wait
```

Get the IP address:

```bash
doctl compute droplet list --format Name,PublicIPv4
```

## Step 2: Connect and install baudbot

SSH into the Droplet:

```bash
ssh root@<droplet-ip>
```

Clone and install:

```bash
git clone https://github.com/modem-dev/baudbot.git ~/baudbot
sudo ~/baudbot/install.sh
```

The installer handles everything:
- Installs prerequisites (git, curl, tmux, iptables, Docker, gh)
- Creates the `baudbot_agent` user
- Installs Node.js and the pi agent
- Generates an SSH key for GitHub
- Sets up the firewall and process isolation
- Walks you through secrets configuration

After the installer finishes, complete the manual steps it prints:

```bash
# 1. Add the agent's SSH key to your GitHub account
cat /home/baudbot_agent/.ssh/id_ed25519.pub
# Copy this and add it at https://github.com/settings/keys

# 2. Authenticate the GitHub CLI
sudo -u baudbot_agent gh auth login
# Follow the device code flow
```

## Step 3: Configure secrets

If you skipped secrets during install, or need to update them:

```bash
sudo baudbot config
sudo baudbot deploy
```

Or edit the secrets file directly:

```bash
sudo nano /home/baudbot_agent/.config/.env
sudo baudbot deploy
```

See [CONFIGURATION.md](../../CONFIGURATION.md) for the full list of environment variables.

## Step 4: Networking and firewall

### Baudbot's built-in firewall

Baudbot's installer sets up `iptables` rules that restrict the `baudbot_agent` user's network access to an allowlist of ports:

- **Outbound internet**: HTTP/S (80/443), SSH (22), DNS (53), cloud databases (3306, 5432, 6379, 27017)
- **Localhost**: dev server ports (3000–5999), databases, the Slack bridge (7890)
- **Everything else**: blocked and logged

These rules persist across reboots via a systemd unit (`baudbot-firewall.service`).

### DigitalOcean Cloud Firewall (optional, recommended)

Add a DigitalOcean Cloud Firewall for defense-in-depth. Since baudbot communicates outbound only (via Slack Socket Mode and SSH for git), you need very few inbound rules:

```bash
doctl compute firewall create \
  --name baudbot-fw \
  --droplet-ids <droplet-id> \
  --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0"
```

**Inbound rules**:
| Protocol | Port | Source | Purpose |
|----------|------|--------|---------|
| TCP | 22 | Your IP (or `0.0.0.0/0`) | SSH access for admin |

> **Tip**: Restrict SSH to your IP address for better security. Update the firewall when your IP changes.

**Outbound rules**: Allow all (baudbot's iptables handles per-user egress filtering).

No other inbound ports are needed — baudbot uses Slack's Socket Mode (outbound WebSocket on port 443), not incoming webhooks.

### Console alternative

1. Go to **Networking → Firewalls → Create Firewall**
2. Add an inbound rule for SSH (TCP 22)
3. Keep all outbound rules (or allow all)
4. Under **Apply to Droplets**, select your baudbot Droplet

## Step 5: Start baudbot

```bash
# Start the agent (uses systemd)
sudo baudbot start

# Check status
sudo baudbot status

# View logs
sudo baudbot logs
```

## Step 6: Verify it's working

```bash
# Run the health check
sudo baudbot doctor

# Check the systemd service
systemctl status baudbot

# Check the firewall is active
sudo iptables -L BAUDBOT_OUTPUT -n -v --line-numbers
```

If you configured Slack, send a message mentioning @baudbot in an allowed channel — it should respond.

## Monitoring

### Logs

```bash
# Tail live logs
sudo baudbot logs

# View systemd journal
journalctl -u baudbot -f

# Check firewall blocked connections
journalctl -k | grep BAUDBOT_BLOCKED
```

### DigitalOcean Monitoring

Enable DigitalOcean's built-in monitoring for CPU, memory, and disk alerts:

```bash
doctl compute droplet create baudbot \
  ... \
  --enable-monitoring
```

Or enable it on an existing Droplet from the **Monitoring** tab in the console. Set up alert policies under **Monitoring → Create Alert Policy** for:
- CPU usage > 80% sustained
- Memory usage > 90%
- Disk usage > 80%

### Automatic backups

Enable weekly backups when creating the Droplet (`--enable-backups` with doctl), or enable them later from the **Backups** tab. Backups cost 20% of the Droplet price (e.g. $4.80/mo for a $24/mo Droplet).

## Cost estimate

| Component | Spec | Monthly cost |
|-----------|------|-------------|
| **Droplet (minimum)** | 4 GB / 2 vCPU Basic | $24/mo |
| **Droplet (recommended)** | 8 GB / 4 vCPU Basic | $48/mo |
| Backups (optional) | Weekly | +20% of Droplet |
| Cloud Firewall | — | Free |
| Snapshots (optional) | Per GB | $0.06/GB/mo |
| **Total (minimum)** | | **~$24/mo** |
| **Total (recommended)** | | **~$48–58/mo** |

Pricing as of January 2026. Effective January 1, 2026, DigitalOcean uses per-second billing with a minimum charge of 60 seconds or $0.01. Check [digitalocean.com/pricing/droplets](https://www.digitalocean.com/pricing/droplets) for current rates.

## Platform-specific tips

- **Snapshots before updates**: Take a snapshot before running `baudbot update` — it's cheap insurance. From the console: **Droplet → Snapshots → Take Snapshot**, or via CLI: `doctl compute droplet-action snapshot <droplet-id> --snapshot-name baudbot-pre-update`.
- **Resize without downtime**: If the agent needs more RAM, power off and resize the Droplet from the console. CPU/RAM-only resizes (no disk increase) are reversible.
- **Droplet Console**: If you lose SSH access, use the **Access → Droplet Console** in the DigitalOcean web UI for emergency access.
- **User data for automation**: For repeatable installs, use `--user-data-file` to pass a cloud-init script that clones and runs the installer automatically:
  ```bash
  doctl compute droplet create baudbot \
    --image ubuntu-24-04-x64 \
    --size s-2vcpu-4gb \
    --region nyc1 \
    --ssh-keys <fingerprint> \
    --user-data-file baudbot-init.sh \
    --wait
  ```
- **VPC networking**: Droplets are automatically placed in a default VPC. If you run other services (databases, etc.) on DigitalOcean, they can communicate over the private network without traversing the public internet.
- **IPv6**: Enable IPv6 on the Droplet if your team needs it (`--enable-ipv6` with doctl).

## Updating baudbot

```bash
ssh root@<droplet-ip>

# Pull latest and redeploy
sudo baudbot update

# Or rollback if something breaks
sudo baudbot rollback previous
```

## Destroying the Droplet

```bash
# Via CLI
doctl compute droplet delete baudbot --force

# Don't forget to clean up the firewall too
doctl compute firewall delete <firewall-id>
```

Or from the console: **Droplet → Destroy → Destroy this Droplet**.

> **Warning**: Destroying a Droplet deletes all data. Take a snapshot first if you want to preserve anything.
