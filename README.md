<img src="https://github.com/user-attachments/assets/cd13e86c-a11d-4dfc-89be-3b66637e0531" width="256" height="256"/>

# Baudbot

[![CI](https://github.com/modem-dev/baudbot/actions/workflows/ci.yml/badge.svg)](https://github.com/modem-dev/baudbot/actions/workflows/ci.yml)
[![Integration](https://github.com/modem-dev/baudbot/actions/workflows/integration.yml/badge.svg)](https://github.com/modem-dev/baudbot/actions/workflows/integration.yml)

**Like Openclaw, but for paranoid developer teams.**

Baudbot runs AI agents as isolated Linux processes with defense-in-depth security. Agents code, test, deploy, monitor, and triage. They work on real repos with real tools. The infrastructure assumes agents *will* be prompt-injected and layers OS-level isolation so damage is contained even when the LLM is compromised.

Built for Linux. Uses iptables, `/proc` hidepid, and Unix user isolation. Every PR is integration-tested on fresh Ubuntu 24.04 and Arch Linux droplets.

## Why

Every agent framework gives the model shell access and hopes for the best. Baudbot enforces:

- **OS-level isolation.** Dedicated Unix user, no sudo, can't see other processes.
- **Network control.** iptables per-UID port allowlist. Standard ports only (80/443/22/53). No listeners, no reverse shells on non-standard ports.
- **Source/runtime separation.** Agent can't read or modify its own infrastructure.
- **Dual-layer command blocking.** Dangerous patterns caught at two independent layers.
- **Self-healing.** Permissions hardened on every boot, secrets redacted from logs.

No sandbox friction. Agents make real branches, run real tests, push real PRs. But they can't escalate privileges or open reverse shells.

## Requirements

| | Minimum | Recommended |
|--|---------|-------------|
| **OS** | Ubuntu 24.04 or Arch Linux | Any systemd-based Linux |
| **RAM** | 4 GB (3 agents) | 8 GB (6 agents + builds/tests) |
| **CPU** | 2 vCPU | 4 vCPU |
| **Disk** | 20 GB | 40 GB+ (repos, node_modules, Docker images) |

## Quick Start

```bash
git clone https://github.com/modem-dev/baudbot.git ~/baudbot
sudo ~/baudbot/install.sh
```

The installer detects your distro, installs dependencies, creates the agent user, sets up the firewall, and walks you through API keys. Takes ~2 minutes.

<details>
<summary>Manual setup (without installer)</summary>

```bash
# Creates user, firewall, permissions (run as root)
sudo bash ~/baudbot/setup.sh <admin_username>

# Add secrets
sudo -u baudbot_agent vim ~/.config/.env

# Deploy source to agent runtime
~/baudbot/bin/deploy.sh

# Launch
sudo -u baudbot_agent ~/runtime/start.sh
```

See [CONFIGURATION.md](CONFIGURATION.md) for the full list of secrets and how to obtain them.
</details>

## Configuration

Secrets live in `~baudbot_agent/.config/.env` (not in repo, 600 perms).
See [CONFIGURATION.md](CONFIGURATION.md) for all keys and how to obtain each value.

## Agents

Baudbot ships three agent roles. The control agent starts automatically and spawns the others in tmux sessions.

| Role | What it does |
|------|-------------|
| **control-agent** | Monitors email inbox, triages requests, delegates to workers, runs Slack bridge |
| **dev-agent** | Full coding loop: branch, code, test, PR, fix CI, repeat |
| **sentry-agent** | Watches Sentry alerts, investigates via API, reports triage to control agent |

Agents can read/write files, run shell commands, create git branches and PRs, build Docker images (via a security wrapper), message each other across sessions, monitor email inboxes, automate cloud browsers, and manage shared todos.

## Integrations

| Integration | How |
|---|---|
| **Slack** | Socket Mode bridge. @mentions + channel monitoring. Rate-limited, content-wrapped. |
| **GitHub** | SSH + PAT. Branches, commits, PRs via `gh`. |
| **Email** | AgentMail inboxes. Send, receive, monitor. |
| **Sentry** | API integration. Alert forwarding from Slack channel. |
| **Docker** | Security wrapper blocks privilege escalation. |
| **Cloud browser** | Kernel browser + Playwright automation. |

Slack is the primary human interface. Email is for agent-to-agent and automated workflows.

## How it works

The control agent spawns sub-agents in tmux sessions and starts the Slack bridge. Messages flow through layered security:

```
Slack → bridge (access control + content wrapping) → pi agent → tools (tool-guard + safe-bash) → workspace
```

Every layer assumes the previous one failed. The bridge wraps content and rate-limits, but tool-guard blocks dangerous commands even if wrapping is bypassed. Safe-bash blocks patterns even if tool-guard is evaded. The firewall blocks non-standard ports even if all software layers fail.

### Heartbeat

The control agent runs a periodic heartbeat loop (default: every 10 minutes) that checks system health:

- Are all agent sessions alive?
- Is the Slack bridge responsive?
- Is the email monitor running?
- Are there stale worktrees or stuck todos?

The checklist lives in `HEARTBEAT.md` — edit it to add custom checks. The heartbeat extension (`heartbeat.ts`) handles scheduling, error backoff, and the `heartbeat` tool for runtime control. If the checklist is empty, no heartbeat fires (saves tokens).
### Persistent Memory

Agents maintain persistent memory across session restarts via Markdown files in `~/.pi/agent/memory/`:

| File | What it stores |
|------|---------------|
| `operational.md` | Infrastructure learnings, common errors and fixes |
| `repos.md` | Per-repo build quirks, CI gotchas, architecture notes |
| `users.md` | User preferences, timezone, communication style |
| `incidents.md` | Past incidents: what broke, root cause, how it was fixed |

Memory files are agent-owned — agents read them on startup and update them as they learn. Deploy seeds the files on first install but never overwrites existing content.

## Architecture

```
admin_user (your account)
├── ~/baudbot/                    ← source repo (agent CANNOT read)
│   ├── bin/                         deploy, firewall, security scripts
│   ├── pi/extensions/               🔒 tool-guard, auto-name, etc.
│   ├── pi/skills/                   agent skill templates
│   ├── slack-bridge/                🔒 bridge + security module
│   └── setup.sh / start.sh         system setup + launcher

baudbot_agent (unprivileged uid)
├── ~/runtime/                   ← deployed copies of bin/, bridge
├── ~/.pi/agent/
│   ├── extensions/                  deployed extensions (read-only)
│   ├── skills/                      agent-owned (can modify)
│   ├── HEARTBEAT.md                 periodic health check checklist
│   ├── memory/                      persistent agent memory (agent-owned)
│   └── baudbot-manifest.json        SHA256 integrity hashes
├── ~/workspace/                     project repos + worktrees
└── ~/.config/.env                   secrets (600 perms)
```

Deploy is a one-way push: `~/baudbot/bin/deploy.sh` stages source to `/tmp`, copies as `baudbot_agent` via `sudo -u`, stamps an integrity manifest, and cleans up.

## Control Plane

Admin-owned web server for monitoring agent status and configuration. Runs on port 28800 — intentionally outside the agent's firewall allowlist so the agent cannot reach it.

```bash
# Start the control plane (runs as admin, NOT as baudbot_agent)
~/baudbot/bin/control-plane.sh

# Or in tmux alongside the agent
tmux new-window -n control-plane '~/baudbot/bin/control-plane.sh'

# With auth token (recommended)
BAUDBOT_CP_TOKEN=$(openssl rand -hex 32) ~/baudbot/bin/control-plane.sh
```

Open `http://127.0.0.1:28800/dashboard` for the web UI, or use the JSON API:

```bash
curl http://127.0.0.1:28800/health          # liveness (no auth)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:28800/status    # agent status
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:28800/config    # config (secrets redacted)
```

## Operations

```bash
# Deploy after editing source
~/baudbot/bin/deploy.sh

# Launch agent (tmux for persistence)
tmux new-window -n baudbot 'sudo -u baudbot_agent ~/runtime/start.sh'

# Security audit
~/baudbot/bin/security-audit.sh
~/baudbot/bin/security-audit.sh --deep   # includes extension scanner

# Monitor agent sessions
sudo -u baudbot_agent tmux ls

# Kill everything
sudo -u baudbot_agent pkill -u baudbot_agent

# Uninstall
sudo ~/baudbot/bin/uninstall.sh --dry-run   # preview
sudo ~/baudbot/bin/uninstall.sh             # for real

# Check deployed version
sudo -u baudbot_agent cat ~/.pi/agent/baudbot-version.json
```

## Tests

```bash
# All tests across 8 suites
bin/test.sh

# JS/TS only
bin/test.sh js

# Shell only
bin/test.sh shell

# Lint + typecheck
npm run lint && npm run typecheck
```

## Adding agents

An agent role is a skill file. Baudbot ships three but you can add more.

1. Create `pi/skills/my-agent/SKILL.md` with role instructions.
2. Add a tmux session spawn for the new agent in `pi/skills/control-agent/SKILL.md` (the control agent manages sub-agent lifecycle).
3. Deploy: `~/baudbot/bin/deploy.sh`

See `pi/skills/dev-agent/SKILL.md` for the pattern.

## Security stack

| Layer | What | Survives prompt injection? |
|-------|------|---------------------------|
| **Source isolation** | Source repo is admin-owned. Agent has zero read access. Deploy is one-way. | ✅ Filesystem |
| **iptables egress** | Per-UID port allowlist (80/443/22/53 + DB ports). Blocks non-standard ports, listeners, raw sockets. | ✅ Kernel |
| **Process isolation** | `/proc` mounted `hidepid=2`. Agent can't see other PIDs. | ✅ Kernel |
| **File permissions** | Security-critical files deployed `chmod a-w`. Agent can't modify `tool-guard.ts`, `security.mjs`, etc. even via `sed` or `python`. | ✅ Filesystem |
| **Shell deny list** | `baudbot-safe-bash` blocks rm -rf, reverse shells, fork bombs, curl\|sh. Root-owned. Pattern-based — can't catch everything. | ✅ Root-owned |
| **Tool interception** | Pi extension blocks Edit/Write tools outside agent home + known dangerous bash patterns. Audit-logs all tool calls. Does NOT prevent arbitrary file writes through bash (that's what file permissions are for). | ✅ Read-only |
| **Integrity manifest** | Deploy stamps SHA256 hashes. Security audit verifies runtime files match. | ✅ Admin-signed |
| **Content wrapping** | External messages wrapped with security boundaries + homoglyph sanitization. | ⚠️ LLM-dependent |
| **Injection detection** | 12 regex patterns flag suspicious content. Log-only. | ⚠️ Detection only |
| **Filesystem hardening** | 700 dirs, 600 secrets, enforced on every boot. | ✅ Boot script |
| **Log redaction** | Scrubs API keys, tokens, private keys from session logs. | ✅ Boot script |
| **Extension scanning** | Static analysis for exfiltration, obfuscation, crypto-mining patterns. | ✅ Audit-time |

## Security details

See [SECURITY.md](SECURITY.md) for the full threat model and trust boundary diagram.

## License

MIT
