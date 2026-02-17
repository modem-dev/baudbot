# Hornet — Agent Guidelines

Hornet is hardened infrastructure for running always-on AI agents. Source is admin-owned; agents run from deployed copies.

## Repo Layout

```
bin/                        security & operations scripts
  deploy.sh                 stages source → /tmp → agent runtime (run as admin)
  security-audit.sh         24-check security posture audit
  setup-firewall.sh         iptables per-UID egress allowlist
  hornet-safe-bash          shell command deny list (installed to /usr/local/bin)
  hornet-docker             Docker wrapper (blocks privilege escalation)
  harden-permissions.sh     filesystem hardening (runs on boot)
  scan-extensions.mjs       extension static analysis
  redact-logs.sh            secret scrubber for session logs
  ci/                       CI integration scripts
    droplet.sh              ephemeral DigitalOcean droplet lifecycle (create/destroy/ssh)
    setup-ubuntu.sh         Ubuntu droplet: prereqs + setup + tests
    setup-arch.sh           Arch Linux droplet: prereqs + setup + tests
hooks/
  pre-commit                blocks agent from modifying security files in git
pi/
  extensions/               source of truth for pi agent extensions
    tool-guard.ts           🔒 tool call interception (blocks dangerous patterns)
    tool-guard.test.mjs     🔒 86 tests for tool-guard
    auto-name.ts            session naming
    control.ts              inter-session communication
    ...
  skills/                   source of truth for agent skill templates
    control-agent/          orchestration agent
    dev-agent/              coding agent
    sentry-agent/           monitoring/triage agent
  settings.json             pi agent settings
slack-bridge/
  bridge.mjs                Slack ↔ agent bridge
  security.mjs              🔒 content wrapping, rate limiting, auth
  security.test.mjs         🔒 tests for security module
setup.sh                    one-time system setup (creates user, firewall, etc.)
start.sh                    agent launcher (deployed to ~/runtime/start.sh)
```

🔒 = security-critical files. Protected at runtime (read-only perms + tool-guard blocks writes).

See [CONFIGURATION.md](CONFIGURATION.md) for all env vars and how to obtain them.

## Architecture: Source / Runtime Separation

The admin owns the source (`~/hornet/`). The agent (`hornet_agent` user) owns the runtime. The agent **cannot read the source repo** — admin home is `700`.

Deploy is a one-way push:
```
admin: ~/hornet/bin/deploy.sh
  → stages to /tmp/hornet-deploy.XXXXXX (world-readable)
  → copies as hornet_agent via sudo -u
  → stamps hornet-version.json + hornet-manifest.json (SHA256 hashes)
  → cleans up staging dir
```

Agent runtime layout:
```
/home/hornet_agent/
├── runtime/
│   ├── start.sh                deployed launcher
│   ├── bin/                    harden-permissions.sh, redact-logs.sh
│   └── slack-bridge/           deployed bridge
├── .pi/agent/
│   ├── extensions/             deployed extensions
│   ├── skills/                 agent-owned (can modify freely)
│   ├── hornet-version.json     deploy version (git SHA, timestamp)
│   └── hornet-manifest.json    SHA256 hashes of all deployed files
├── workspace/                  project repos + git worktrees
└── .config/.env                secrets (600 perms)
```

## Development Workflow

```bash
# Edit source files directly in ~/hornet/

# Deploy to agent runtime
~/hornet/bin/deploy.sh

# Launch agent
sudo -u hornet_agent ~/runtime/start.sh

# Or in tmux
tmux new-window -n hornet 'sudo -u hornet_agent ~/runtime/start.sh'
```

## Running Tests

```bash
# All tests (207 across 5 suites)
bin/test.sh

# Only JS/TS tests
bin/test.sh js

# Only shell tests
bin/test.sh shell
```

Add new test files to `bin/test.sh` — don't scatter test invocations across CI or docs.

## Conventions

- Security functions must be pure, testable modules (no side effects, no env vars at module scope).
- All security code must have tests before merging.
- Run `bin/security-audit.sh --deep` after any security-relevant changes.
- Protected files (`tool-guard.ts`, `security.mjs`, their tests) are deployed read-only. The agent cannot modify them at runtime.
- New integrations get their own subdirectory (e.g. `discord-bridge/`).
- Extensions are deployed from `pi/extensions/` → agent's `~/.pi/agent/extensions/`.
- Skills are deployed from `pi/skills/` → agent's `~/.pi/agent/skills/`.
- Agent commits operational learnings to its own skills dir (not back to source).
- **When changing behavior, update all docs.** Check and update: `README.md`, `CONFIGURATION.md`, skill files (`pi/skills/*/SKILL.md`), and `AGENTS.md`. Inline code examples in docs must match the actual implementation.
- **No distro-specific commands.** Scripts must work on both Arch and Ubuntu (and any standard Linux). Use `grep -E` (not `grep -P`), POSIX-compatible tools, and avoid package manager calls (`pacman`, `apt`, etc.). If a package is needed, document it as a prerequisite rather than auto-installing it.

## Security Notes

- `tool-guard.ts` blocks: writes outside `/home/hornet_agent/`, writes to source repo, writes to protected runtime files, dangerous bash patterns (reverse shells, fork bombs, rm -rf /, etc.), credential exfiltration.
- `hornet-safe-bash` (root-owned, `/usr/local/bin/`) is a second layer that blocks the same patterns at the shell level.
- The firewall (`setup-firewall.sh`) restricts `hornet_agent`'s network egress to an allowlist.
- `/proc` is mounted with `hidepid=2` — agent can only see its own processes.
- Secrets in `~/.config/.env` are `600` perms, never committed.
- Session logs are auto-redacted of API keys/tokens on boot.

## Git Workflow

- **Never commit directly to `main`.** All changes go on feature branches with PRs.
- One branch per todo/task. Branch names: `<gh-username>/<description>` (e.g. `benvinegar/add-uninstall-script`).
- Use `gh pr create` to open PRs (not the GitHub API with tokens).
- Concise, action-oriented commit messages: `security: add rate limiting to bridge API`
- Prefix with area: `security:`, `bridge:`, `deploy:`, `docs:`, `arch:`, `tests:`
