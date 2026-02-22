<img src="https://github.com/user-attachments/assets/66ab2c6d-2e21-48d0-b95f-0d9dbdb57384" width="256" height="256"/>

# Baudbot

[![CI](https://github.com/modem-dev/baudbot/actions/workflows/ci.yml/badge.svg)](https://github.com/modem-dev/baudbot/actions/workflows/ci.yml)
[![Integration](https://github.com/modem-dev/baudbot/actions/workflows/integration.yml/badge.svg)](https://github.com/modem-dev/baudbot/actions/workflows/integration.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/modem-dev/baudbot)](https://github.com/modem-dev/baudbot/commits/main)
[![Security](https://img.shields.io/badge/security-model-blue)](SECURITY.md)

**Hardened, always-on multi-agent coding infrastructure for teams.**

Baudbot runs a persistent control agent on Linux, connected to Slack, that can dispatch task-scoped coding agents in isolated git worktrees. It is designed for autonomous execution with clear operational controls (deploy/update/rollback, health checks, security audits, runtime hardening).

_⚠️ Alpha software: expect sharp edges, validate in non-critical environments first._

---

## What Baudbot does today

- **Shared team interface in Slack** (threaded intake, status updates, closeout)
- **Persistent orchestration** via `control-agent`
- **Task-scoped coding workers** (`dev-agent`) that run branch → code → test → PR → CI loops
- **Release-based runtime ops** (`/opt/baudbot/releases/<sha>` + atomic `current`/`previous` links)
- **Linux-native execution** (real shell/tools, guarded Docker wrapper, optional cloud browser tooling)
- **Persistent memory and skills** under `~/.pi/agent/`
- **Defense-in-depth controls** (tool/shell policy layers + OS boundaries + runtime hardening)

## What Baudbot is not

- Not a desktop copilot
- Not a stateless chat bot
- Not “agents with unrestricted root”

Baudbot is intended to run as managed infra with explicit trust boundaries.

---

## Architecture (current)

```text
Slack (Socket Mode or broker pull mode)
   ↓
control-agent (persistent)
   ├─ todo tracking + routing
   ├─ dev-agent-* (ephemeral coding workers in worktrees)
   └─ sentry-agent (persistent/on-demand incident triage)
   ↓
PRs, CI outcomes, thread replies
```

### Source / release / runtime separation

```text
admin source checkout:   ~/baudbot/
release snapshots:       /opt/baudbot/releases/<sha>
active release link:     /opt/baudbot/current
previous release link:   /opt/baudbot/previous
agent runtime:           /home/baudbot_agent/{runtime,.pi/agent,workspace}
```

`baudbot update` publishes a git-free snapshot, deploys runtime files, runs health checks, and atomically flips `current`.

---

## Requirements

| | Minimum | Recommended |
|--|---------|-------------|
| **OS** | Ubuntu 24.04 or Arch Linux | systemd-based Linux |
| **RAM** | 4 GB | 8 GB |
| **CPU** | 2 vCPU | 4 vCPU |
| **Disk** | 20 GB | 40 GB+ |

Installer-managed dependencies include: `git`, `curl`, `tmux`, `iptables`, `docker`, `gh`, `jq`, `sudo`.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/modem-dev/baudbot/main/bootstrap.sh | bash
baudbot install
```

The installer performs setup, guided configuration, initial release deployment, and optional launch.

After install:

```bash
sudo baudbot status
sudo baudbot logs
sudo baudbot doctor
```

If the installer skipped launch, start manually:

```bash
sudo baudbot start
```

### Optional: pin pi version during install

```bash
BAUDBOT_PI_VERSION=0.52.12 baudbot install
```

---

## Slack integration modes

### 1) Direct Slack Socket Mode
Use `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN`.

### 2) Broker pull mode (preferred for managed setups)
Register after OAuth callback:

```bash
sudo baudbot broker register \
  --broker-url https://your-broker.example.com \
  --workspace-id T0123ABCD \
  --registration-token <token-from-dashboard-callback>
```

Then restart:

```bash
sudo baudbot restart
```

> `baudbot setup --slack-broker` is deprecated. Use `baudbot broker register`.

---

## Core operations

```bash
# Lifecycle
sudo baudbot start
sudo baudbot stop
sudo baudbot restart
sudo baudbot status
sudo baudbot logs

# Sessions
sudo baudbot sessions
sudo baudbot attach

# Deploy / upgrade / rollback
sudo baudbot deploy
sudo baudbot update
sudo baudbot rollback previous

# Health + security
sudo baudbot doctor
sudo baudbot audit

# Remove
sudo baudbot uninstall --dry-run
sudo baudbot uninstall
```

---

## Secrets and configuration

- Runtime secrets file: `/home/baudbot_agent/.config/.env`
- Validation schema: `.env.schema` (validated via Varlock at startup)
- Manage keys with:

```bash
sudo baudbot env set ANTHROPIC_API_KEY
sudo baudbot env set OPENAI_API_KEY sk-... --restart
sudo baudbot env backend show
sudo baudbot env backend set-command 'your-secret-tool export baudbot-prod'
sudo baudbot env sync --restart
```

Full variable reference: [CONFIGURATION.md](CONFIGURATION.md)

---

## Development and tests

```bash
# All tests
npm test

# JS/TS only
npm run test:js

# Shell/security script tests
npm run test:shell

# Coverage
npm run test:coverage

# Lint + typecheck
npm run lint
npm run typecheck
```

For real distro validation, use ephemeral droplets via `bin/ci/droplet.sh`.

---

## Security model summary

Baudbot uses layered controls:

- unprivileged `baudbot_agent` runtime user
- firewall egress restrictions by UID
- source/runtime separation + immutable release snapshots
- runtime file hardening + read-only protection for security-critical files
- tool-call and shell deny-list policy layers (`tool-guard`, `baudbot-safe-bash`)
- startup log pruning and secret redaction

Important: guard layers are policy/defense-in-depth helpers, **not** the primary sandbox boundary. Hard containment is provided by OS/runtime permissions and deployment architecture.

See [SECURITY.md](SECURITY.md) for full threat model and risk notes.

---

## Documentation

- [docs/team-workflow.md](docs/team-workflow.md) — intake → execution → closeout lifecycle
- [docs/agents.md](docs/agents.md) — control/dev/sentry role contracts
- [docs/memory.md](docs/memory.md) — memory model and persistence rules
- [docs/linux-runtime.md](docs/linux-runtime.md) — runtime behavior and constraints
- [docs/operations.md](docs/operations.md) — day-2 runbook
- [docs/architecture.md](docs/architecture.md) — release/runtime architecture
- [CONFIGURATION.md](CONFIGURATION.md) — env vars and setup details
- [SECURITY.md](SECURITY.md) — security boundaries and known risks
- [CONTRIBUTING.md](CONTRIBUTING.md) — contribution workflow
- [AGENTS.md](AGENTS.md) — maintainer/agent development conventions

## License

MIT
