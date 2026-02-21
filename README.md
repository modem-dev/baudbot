<img src="https://github.com/user-attachments/assets/66ab2c6d-2e21-48d0-b95f-0d9dbdb57384" width="256" height="256"/>

# Baudbot

[![CI](https://github.com/modem-dev/baudbot/actions/workflows/ci.yml/badge.svg)](https://github.com/modem-dev/baudbot/actions/workflows/ci.yml)
[![Integration](https://github.com/modem-dev/baudbot/actions/workflows/integration.yml/badge.svg)](https://github.com/modem-dev/baudbot/actions/workflows/integration.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/modem-dev/baudbot)](https://github.com/modem-dev/baudbot/commits/main)
[![Security Policy](https://img.shields.io/badge/security-policy-blue)](SECURITY.md)

**Always-on, multiplayer coding agent infrastructure for engineering teams.**

Baudbot runs a persistent AI control agent on Linux, connected to Slack, with worker agents that take tasks from request to PR. It works on real repositories with real tools (git, test runners, Docker wrapper, cloud browser automation), keeps persistent memory, and reports progress back in-thread.

Built for teams that want autonomous execution speed **without giving up operational control**.

## What Baudbot does

- **Shared Slack interface for the whole team.** Anyone in allowed channels can hand work to the same agent system.
- **Always-on response and fast handoffs.** The control agent stays live, triages work instantly, and spins up task-scoped coding agents.
- **End-to-end coding loop.** Branch, code, run tests, open PR, watch CI, push fixes, report status.
- **Linux-native execution.** Agents can run the same project commands your engineers run (including guarded container workflows).
- **Persistent team memory.** The system learns repo quirks, recurring fixes, and collaboration preferences across restarts.
- **Self-improving operations.** Agents can update non-security skills/extensions and propose upstream improvements via PRs.

## Team agent, not a personal copilot

Baudbot is designed as shared engineering infrastructure, not a single-user desktop assistant:

- multiplayer by default (Slack threads, shared todos, multiple sessions)
- persistent service, not one-shot chat
- autonomous task execution with humans in review loops
- admin-managed runtime with deployment + rollback controls

## How work flows (example)

1. A developer asks in Slack: "Fix flaky auth tests in `myapp`."
2. Baudbot acknowledges immediately in the same thread.
3. Control agent creates a todo and spawns a `dev-agent` in a fresh git worktree.
4. Dev agent fixes code, runs tests, opens a PR, and monitors CI.
5. If CI fails, the dev agent iterates and pushes fixes automatically.
6. Baudbot posts the PR link, CI status, and preview URL back to the original Slack thread.

## Requirements

| | Minimum | Recommended |
|--|---------|-------------|
| **OS** | Ubuntu 24.04 or Arch Linux | Any systemd-based Linux |
| **RAM** | 4 GB (3 agents) | 8 GB (6 agents + builds/tests) |
| **CPU** | 2 vCPU | 4 vCPU |
| **Disk** | 20 GB | 40 GB+ (repos, dependencies, Docker images) |

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/modem-dev/baudbot/main/bootstrap.sh | bash
baudbot install
```

`baudbot install` includes a guided config flow: pick an LLM provider, choose Slack integration mode (managed broker vs custom app), then opt into optional integrations (Kernel/Sentry). Email capabilities are disabled by default and only available in experimental mode (`baudbot setup --experimental` / `install.sh --experimental`). If [`gum`](https://github.com/charmbracelet/gum) is installed, prompts use richer TUI widgets; otherwise installer falls back to standard bash prompts.

After install:

```bash
# deploy latest source/config to runtime
sudo baudbot deploy

# start the service
sudo baudbot start

# check health
sudo baudbot status
sudo baudbot doctor
```

Upgrade later:

```bash
sudo baudbot update
```

Install with a specific pi version (optional):

```bash
BAUDBOT_PI_VERSION=0.52.12 baudbot install
```

Slack broker registration (after OAuth callback). When `SLACK_BROKER_*` variables are present, the runtime starts broker pull mode (no inbound callback port required):

```bash
sudo baudbot broker register \
  --broker-url https://your-broker.example.com \
  --workspace-id T0123ABCD \
  --auth-code <auth-code-from-oauth-callback>
```

See [CONFIGURATION.md](CONFIGURATION.md) for required environment variables and secret setup.

## Core agents

| Role | Purpose |
|------|---------|
| **control-agent** | Owns intake, triage, delegation, Slack comms, and lifecycle supervision |
| **dev-agent** | Ephemeral coding worker that executes branch → code → PR → CI loops |
| **sentry-agent** | On-demand incident investigator for Sentry alerts and triage support |

## Architecture at a glance

```text
Slack
   ↓
control-agent (always-on)
   ├─ todo + routing
   ├─ dev-agent(s) in isolated worktrees
   └─ sentry-agent for incident triage
        ↓
git commits, PRs, CI feedback, thread updates
```

Baudbot uses source/runtime separation: admin-managed source and immutable releases are deployed into an unprivileged agent runtime.

## Security as an enabling layer

Baudbot is built for utility **and** containment:

- isolated `baudbot_agent` Unix user (no general sudo)
- per-UID firewall controls + process isolation
- source/runtime separation with deploy manifests
- read-only protection for security-critical files
- session log hygiene (startup redaction + retention pruning)
- layered tool and shell guardrails (policy/guidance layer, not sole containment)

See [SECURITY.md](SECURITY.md) for full threat model, trust boundaries, and known risks. In particular: tool/shell guards are defense-in-depth policy layers; hard containment comes from OS/runtime boundaries.

## Documentation

- [docs/team-workflow.md](docs/team-workflow.md) — request lifecycle and orchestration model
- [docs/agents.md](docs/agents.md) — agent roles, responsibilities, and session model
- [docs/memory.md](docs/memory.md) — persistent memory design and operating rules
- [docs/linux-runtime.md](docs/linux-runtime.md) — Linux execution model, tools, and constraints
- [docs/operations.md](docs/operations.md) — day-2 operations (start/stop/update/rollback/audit)
- [docs/architecture.md](docs/architecture.md) — source/runtime/release architecture
- [CONFIGURATION.md](CONFIGURATION.md) — full env var reference
- [SECURITY.md](SECURITY.md) — deep security model and vulnerability reporting
- [CONTRIBUTING.md](CONTRIBUTING.md) — contribution workflow

## Tests

```bash
# All tests (unified Vitest runner)
npm test

# JS/TS suites only
npm run test:js

# Shell/security script suites only
npm run test:shell

# JS/TS coverage
npm run test:coverage

# Lint (Biome + ShellCheck) + typecheck
npm run lint && npm run typecheck

# ShellCheck only
npm run lint:shell
```

## License

MIT
