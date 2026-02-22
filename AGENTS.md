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
slack-bridge (broker pull-mode or legacy Socket Mode)
   ↓
control-agent (always-on, manages todo/routing/Slack threads)
   ├── dev-agent(s) — ephemeral coding workers in isolated worktrees
   └── sentry-agent — incident triage (Sentry alerts)
         ↓
git commits → PRs → CI feedback → thread updates back to Slack
```

**Deployment model:** Admin-managed source (this repo) is deployed as immutable, git-free release snapshots under `/opt/baudbot`. The agent runtime (`/home/baudbot_agent`) receives deployed extensions, skills, and bridge code. Updates and rollbacks are atomic symlink switches. See `docs/architecture.md` for full details.

## What this repo contains (high-level)

- `bin/` — operational shell CLI, deploy/update/rollback, security and health scripts
- `pi/extensions/` — tool extensions and runtime behaviors deployed into agent runtime
- `pi/skills/` — agent personas and behavior (`SKILL.md` defines each agent's identity, rules, and tools)
  - `control-agent/` — orchestration/triage persona + persistent memory seeds
  - `dev-agent/` — coding worker persona
  - `sentry-agent/` — incident triage persona
- `pi/settings.json` — pi agent settings
- `slack-bridge/` — Slack integration bridges + security module
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

## Non-negotiable guardrails

**Hard constraints (enforced by pre-commit hook or CI):**
- Never commit directly to `main`; use feature branches + PRs.
- Security-critical files are protected by `hooks/pre-commit` — the agent cannot modify them at runtime.
- Security-sensitive changes MUST include or update tests.
- Do NOT weaken runtime hardening (permissions, least privilege, egress restrictions).

**Strong defaults:**
- When behavior changes, update docs in the same PR (`README.md`, `docs/*`, `CONFIGURATION.md`, and relevant `AGENTS.md` files).
- Prefer distro-agnostic shell; distro-specific branches are acceptable when reliability improves.

## Tests and quality gates

Before merge, run at minimum: `npm run lint` and `npm test`.

## Git / PR expectations

- Use concise commit messages with area prefix (`security:`, `bridge:`, `deploy:`, `docs:`, `tests:`, ...).
- If a change is scoped to a subdirectory with its own `AGENTS.md`, follow that local file first.
