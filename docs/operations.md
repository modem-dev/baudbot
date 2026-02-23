# Operations

Day-2 operations for running Baudbot in production-like environments with predictable deploy, rollback, and health-check workflows.

## Core lifecycle commands

```bash
# Start / stop / restart service
sudo baudbot start
sudo baudbot stop
sudo baudbot restart

# Status and logs (status includes deployed version + broker connection/health state)
sudo baudbot status
sudo baudbot logs

# Attach / inspect active sessions
sudo baudbot attach
sudo baudbot sessions
```

## Deployment and upgrades

```bash
# Deploy source + config to runtime
sudo baudbot deploy

# Update from upstream with preflight checks and release publishing
sudo baudbot update

# Roll back to previous or specified release snapshot
sudo baudbot rollback previous
```

Provision with a pinned pi version (optional):

```bash
BAUDBOT_PI_VERSION=0.52.12 baudbot install
```

## Remote install and repair

`baudbot remote` is an opt-in operator workflow for remote provisioning/install/repair. It is local-CLI stateful (checkpoints + resume) and does not change normal runtime behavior unless you invoke it.

```bash
# New Hetzner host (provision + install)
baudbot remote install --mode hetzner --target team-bot

# Existing host install
baudbot remote install --mode host --target team-bot --host 203.0.113.10 --ssh-user root

# Enable Tailscale during install (interactive login unless auth key provided)
baudbot remote install --mode host --target team-bot --host 203.0.113.10 --tailscale
# Non-interactive auth-key path:
baudbot remote install --mode host --target team-bot --host 203.0.113.10 --tailscale --tailscale-auth-key tskey-...

# Checkpoint inspection and resume
baudbot remote list
baudbot remote status team-bot
baudbot remote resume team-bot

# Guided repair
baudbot remote repair --target team-bot
# or host-only targeting:
baudbot remote repair --host 203.0.113.10 --ssh-user root --non-interactive-safe
```

Install checkpoints are persisted under `~/.baudbot/remote/targets/<target>.json`. SSH host keys are stored in `~/.baudbot/remote/known_hosts` with `StrictHostKeyChecking=accept-new`.

## Updating API keys after install

```bash
# Prompt for value (hidden input)
sudo baudbot env set ANTHROPIC_API_KEY

# Or inline with immediate restart
sudo baudbot env set OPENAI_API_KEY sk-... --restart

# Inspect stored value source (prints value)
baudbot env get ANTHROPIC_API_KEY --admin
sudo baudbot env get ANTHROPIC_API_KEY --runtime

# Optional: switch admin source to command backend
sudo baudbot env backend set-command 'your-secret-tool export baudbot-prod'
sudo baudbot env sync --restart
```

## Slack broker registration

```bash
# Register this server to a broker workspace (after OAuth callback)
sudo baudbot broker register \
  --broker-url https://your-broker.example.com \
  --workspace-id T0123ABCD \
  --registration-token <token-from-dashboard-callback>
```

Do not use `baudbot setup --slack-broker` — `setup` is host provisioning only.

## Health and security checks

```bash
# Runtime/system health checks
sudo baudbot doctor

# Security posture audit
sudo baudbot audit

# Deep audit (extension scanner + extra checks)
sudo baudbot audit --deep
```

## Test commands

```bash
# Full test suite
npm test

# JS/TS only
npm run test:js

# Shell/security-script suites
npm run test:shell

# Coverage
npm run test:coverage

# Lint + typecheck
npm run lint
npm run typecheck
```

## Common runbook actions

- verify Slack bridge responsiveness
- verify control/sentry/dev sessions are healthy
- clean stale worktrees
- prune old session logs if needed (`sudo -u baudbot_agent ~/runtime/bin/prune-session-logs.sh --days 14`)
- verify deployed version/manifests
- perform rollback when upgrade regressions are detected

## Uninstall

```bash
# Preview
sudo baudbot uninstall --dry-run

# Execute
sudo baudbot uninstall
```

For architecture context, see [architecture.md](architecture.md). For threat model details, see [../SECURITY.md](../SECURITY.md).
