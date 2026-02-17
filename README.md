# 🐝 Hornet

[![CI](https://github.com/modem-dev/hornet/actions/workflows/ci.yml/badge.svg)](https://github.com/modem-dev/hornet/actions/workflows/ci.yml)
[![Integration](https://github.com/modem-dev/hornet/actions/workflows/integration.yml/badge.svg)](https://github.com/modem-dev/hornet/actions/workflows/integration.yml)

**Hardened autonomous agent infrastructure. Careful — you might get stung.**

Hornet is an open framework for running always-on AI agents that support software teams — coding agents, automated SREs, QA bots, monitoring, triage, and more. Agents run as isolated Linux processes with defense-in-depth security. Hornet assumes the worst: that an agent *will* be prompt-injected, and builds kernel-level walls that hold even when the LLM is fully compromised.

**Built for Linux.** Hornet uses kernel-level features (iptables, `/proc` hidepid, Unix users) that don't exist on macOS or Windows. Every PR is integration-tested on fresh **Ubuntu 24.04** and **Arch Linux** droplets.

## Why

Every AI agent framework gives the model shell access and hopes for the best. Hornet doesn't hope — it enforces:

- **OS-level isolation** — dedicated Unix user, no sudo, can't see other processes
- **Kernel-enforced network control** — iptables per-UID egress allowlist
- **Source/runtime separation** — agent can't read or modify its own infrastructure code
- **Dual-layer command blocking** — dangerous shell patterns caught before execution at two independent layers
- **Self-healing** — permissions hardened on every boot, secrets redacted from logs automatically

Agents work on real files in real repos — no sandbox friction. They make real git branches, run real tests, and push real PRs. But they can't exfiltrate data, escalate privileges, or phone home.

## Requirements

| | Minimum | Recommended |
|--|---------|-------------|
| **OS** | Ubuntu 24.04 or Arch Linux | Any systemd-based Linux |
| **RAM** | 4 GB (3 agents) | 8 GB (6 agents + builds/tests) |
| **CPU** | 2 vCPU | 4 vCPU |
| **Disk** | 20 GB | 40 GB+ (repos, node_modules, Docker images) |

## Quick Start

```bash
git clone https://github.com/modem-dev/hornet.git ~/hornet
sudo ~/hornet/install.sh
```

The installer detects your distro, installs dependencies, creates the agent user, sets up the firewall, and walks you through API keys interactively. Takes ~2 minutes.

<details>
<summary>Manual setup (without installer)</summary>

```bash
# Setup (creates user, firewall, permissions — run as root)
sudo bash ~/hornet/setup.sh <admin_username>

# Add secrets
sudo -u hornet_agent vim ~/.config/.env

# Deploy source → agent runtime
~/hornet/bin/deploy.sh

# Launch
sudo -u hornet_agent ~/runtime/start.sh
```

See [CONFIGURATION.md](CONFIGURATION.md) for the full list of secrets and how to obtain them.
</details>

## Configuration

Secrets and configuration live in `~hornet_agent/.config/.env` (not in repo, 600 perms).
See [CONFIGURATION.md](CONFIGURATION.md) for the full list and how to obtain each value.

## Operations

```bash
# Deploy after editing source
~/hornet/bin/deploy.sh

# Launch agent (in tmux for persistence)
tmux new-window -n hornet 'sudo -u hornet_agent ~/runtime/start.sh'

# Check security posture
~/hornet/bin/security-audit.sh
~/hornet/bin/security-audit.sh --deep   # includes extension scanner

# Monitor agent sessions
sudo -u hornet_agent tmux ls

# Kill everything
sudo -u hornet_agent pkill -u hornet_agent

# Uninstall (reverses setup.sh)
sudo ~/hornet/bin/uninstall.sh --dry-run   # preview
sudo ~/hornet/bin/uninstall.sh             # for real

# Check deployed version
sudo -u hornet_agent cat ~/.pi/agent/hornet-version.json
```

## Tests

```bash
# All 207 tests across 5 suites
bin/test.sh

# JS/TS only
bin/test.sh js

# Shell only
bin/test.sh shell

# Lint + typecheck
npm run lint && npm run typecheck
```

## How It Works

Hornet runs a **control-agent** that spawns specialized sub-agents in tmux sessions and starts a Slack bridge. Out of the box it ships with a dev-agent (coding), sentry-agent (monitoring/triage), and a control-agent (orchestration) — but you can add any agent role. Messages flow:

```
Slack → bridge (access control + content wrapping) → pi agent → tools (tool-guard + safe-bash) → workspace
```

Every layer assumes the previous one failed. The bridge wraps content and rate-limits, but tool-guard blocks dangerous commands even if wrapping is bypassed. Safe-bash blocks patterns even if tool-guard is somehow evaded. The firewall blocks exfiltration even if all software layers fail. Defense in depth, all the way down.

## Architecture

```
admin_user (your account)
├── ~/hornet/                    ← source repo (agent CANNOT read)
│   ├── bin/                         deploy, firewall, security scripts
│   ├── pi/extensions/               🔒 tool-guard, auto-name, etc.
│   ├── pi/skills/                   agent skill templates
│   ├── slack-bridge/                🔒 bridge + security module
│   └── setup.sh / start.sh         system setup + launcher

hornet_agent (unprivileged uid)
├── ~/runtime/                   ← deployed copies of bin/, bridge
├── ~/.pi/agent/
│   ├── extensions/                  deployed extensions (read-only)
│   ├── skills/                      agent-owned (can modify)
│   └── hornet-manifest.json         SHA256 integrity hashes
├── ~/workspace/                     project repos + worktrees
└── ~/.config/.env                   secrets (600 perms)
```

Deploy is a one-way push: `~/hornet/bin/deploy.sh` stages source → `/tmp` → copies as `hornet_agent` via `sudo -u` → stamps integrity manifest → cleans up.

## Security Stack

| Layer | What | Survives prompt injection? |
|-------|------|---------------------------|
| **Source isolation** | Source repo is admin-owned, agent has zero read access. Deploy is one-way. | ✅ Filesystem-enforced |
| **iptables egress** | Per-UID firewall chain. Allowlisted ports only, no listeners, no reverse shells. | ✅ Kernel-enforced |
| **Process isolation** | `/proc` mounted `hidepid=2`. Agent can't see other PIDs. | ✅ Kernel-enforced |
| **Shell deny list** | `hornet-safe-bash` blocks rm -rf, reverse shells, fork bombs, curl\|sh. Root-owned. | ✅ Root-owned |
| **Tool call interception** | Pi extension blocks dangerous tool calls before they hit disk or shell. | ✅ Compiled into runtime |
| **Integrity manifest** | Deploy stamps SHA256 hashes of all files. Agent can verify its own runtime hasn't been tampered with. | ✅ Admin-signed |
| **Content wrapping** | External messages wrapped with security boundaries + Unicode homoglyph sanitization. | ⚠️ LLM-dependent |
| **Injection detection** | 12 regex patterns flag suspicious content. Log-only. | ⚠️ Detection, not prevention |
| **Filesystem hardening** | 700 dirs, 600 secrets, enforced on every boot. | ✅ Boot script |
| **Log redaction** | Scrubs API keys, tokens, private keys from session logs. | ✅ Boot script |
| **Extension scanning** | Static analysis for exfiltration, obfuscation, crypto-mining patterns. | ✅ Audit-time |

## Security Details

See [SECURITY.md](SECURITY.md) for the full threat model and trust boundary diagram.

## License

MIT
