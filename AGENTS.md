# Baudbot — Agent Guidelines

Baudbot is hardened infrastructure for running always-on AI agents.

Use this file for **repo-wide** guidance. For directory-specific rules, use the nearest nested `AGENTS.md`:
- [`bin/AGENTS.md`](bin/AGENTS.md)
- [`pi/extensions/AGENTS.md`](pi/extensions/AGENTS.md)
- [`slack-bridge/AGENTS.md`](slack-bridge/AGENTS.md)

## How Baudbot works

Baudbot is a persistent, team-facing coding agent system. It connects to Slack, receives work requests from developers, and autonomously executes coding tasks (branch, code, test, PR, CI) on a Linux server.

**Runtime model:** A long-running **control agent** stays connected to Slack, triages incoming requests, and delegates work to ephemeral **dev agents** that each run in isolated git worktrees. A **sentry agent** handles on-demand incident triage. All agents run as an unprivileged `baudbot_agent` Unix user.

```text
Slack
   ↓
Gateway bridge (slack-bridge dir; broker pull-mode or legacy Socket Mode)
   ↓
control-agent (always-on, manages todo/routing/Slack threads)
   ├── dev-agent(s) — ephemeral coding workers in isolated worktrees
   └── sentry-agent — incident triage (Sentry alerts)
         ↓
git commits → PRs → CI feedback → thread updates back to Slack
```

**Deployment model:** Admin-managed source (this repo) is deployed as immutable, git-free release snapshots under `/opt/baudbot`. The agent runtime (`/home/baudbot_agent`) receives deployed extensions, skills, and bridge code. Updates and rollbacks are atomic symlink switches. See `docs/architecture.md` for full details.

## Startup boundary: `start.sh` vs agent

There are two startup phases with distinct ownership:

| Phase | Owner | Scope |
|-------|-------|-------|
| **OS boot** (`start.sh`) | Admin | Env validation, permissions, secrets, socket cleanup, launch `pi` |
| **Agent boot** (`startup-pi.sh`) | Agent | Gateway bridge, sentry-agent, dev-agents, session wiring |

**Rule: `start.sh` must never spawn tmux sessions or background processes that need pi runtime state** (session UUIDs, socket paths, etc.). Those only exist after pi starts. All tmux sessions (bridge, sentry-agent, dev-agents) are owned and managed by the agent via `startup-pi.sh` or extensions. `start.sh` may only *kill* stale processes as pre-cleanup.

## What this repo contains (high-level)

- `bin/` — operational shell CLI, deploy/update/rollback, security and health scripts
- `pi/extensions/` — tool extensions and runtime behaviors deployed into agent runtime
- `pi/skills/` — agent personas and behavior (`SKILL.md` defines each agent's identity, rules, and tools)
  - `control-agent/` — orchestration/triage persona + persistent memory seeds
  - `dev-agent/` — coding worker persona
  - `sentry-agent/` — incident triage persona
- `pi/settings.json` — pi agent settings
- `slack-bridge/` — Gateway bridge runtime + security module
- `docs/` — architecture/operations/security documentation
- `test/` — vitest wrappers for shell scripts, integration, and legacy Node tests
- `hooks/` — git hooks (security-critical `pre-commit` protecting admin-managed files)
- `.github/` — CI workflows, PR template, issue templates
- `.env.schema` — canonical schema for all environment variables (see `CONFIGURATION.md`)
- `bootstrap.sh`, `setup.sh`, `install.sh`, `start.sh` — bootstrap installer, system setup, interactive install, and runtime launcher

## Core workflow

```bash
# JS/TS + shell tests + lint
npm test
npm run lint

# Source-only deploy (extensions/skills/bridge changes)
./bin/deploy.sh

# Live operational update/rollback
sudo baudbot update
sudo baudbot rollback previous
```

## Real Linux verification (DigitalOcean)

When you have a DigitalOcean API credential available, you are encouraged to validate behavior on a real Linux VPS (not only local/sandbox runs), especially for runtime, process, tmux/session-control, networking, firewall, installer, or permissions-related changes.

- Treat `DO_API_KEY` as a DigitalOcean token alias. This repo's scripts use `DO_API_TOKEN` as the canonical variable.
- Prefer **Arch Linux** for first-pass verification when possible (lighter/faster CI baseline in this repo).
- Reuse existing droplet helpers instead of ad-hoc scripts:
  - `bin/ci/droplet.sh create ...`
  - `bin/ci/droplet.sh wait-ssh ...`
  - `bin/ci/droplet.sh run ... bin/ci/setup-arch.sh`
  - `bin/ci/droplet.sh destroy ...`
- For Arch image defaults, use the same image/version strategy as `.github/workflows/integration.yml`.
- Always destroy temporary droplets/SSH keys/images after verification to avoid cost leaks.
- Never print or persist DigitalOcean credentials in logs, commits, or memory files.

## Non-negotiable guardrails

**Hard constraints (enforced by pre-commit hook or CI):**
- Never commit directly to `main`; use feature branches + PRs.
- Security-critical files are protected by `hooks/pre-commit` — the agent cannot modify them at runtime.
- Security-sensitive changes MUST include or update tests.
- Do NOT weaken runtime hardening (permissions, least privilege, egress restrictions).

**Strong defaults:**
- When behavior changes, update docs in the same PR (`README.md`, `docs/*`, `CONFIGURATION.md`, and relevant `AGENTS.md` files).
- Prefer distro-agnostic shell; distro-specific branches are acceptable when reliability improves.
- Prefer explicit, domain-aware naming for shared code (`FooRequestBody`, `SlackWorkspaceKVRecord`, `BrokerHttpResponse`, etc.).
- Keep action names semantic (`activateWorkspace`), and use storage/runtime qualifiers on read/write helpers when helpful (`getWorkspaceKVRecord`, `putWorkspaceDBRow`).
- Local variables may be lighter-weight when scope is short and context is obvious, but avoid ambiguous names (`data`, `payload`, `body`, `response`) when crossing boundaries.

## Tests and quality gates

Before merge, run at minimum: `npm run lint` and `npm test`.

## Git / PR expectations

- Use concise commit messages with area prefix (`security:`, `bridge:`, `deploy:`, `docs:`, `tests:`, ...).
- If a change is scoped to a subdirectory with its own `AGENTS.md`, follow that local file first.
