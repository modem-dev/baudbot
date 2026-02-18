# Operations

Day-2 operations for running Baudbot in production-like environments with predictable deploy, rollback, and health-check workflows.

## Core lifecycle commands

```bash
# Start / stop / restart service
sudo baudbot start
sudo baudbot stop
sudo baudbot restart

# Status and logs
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

## Health and security checks

```bash
# Runtime/system health checks
sudo baudbot doctor

# Security posture audit
sudo baudbot audit

# Deep audit (extension scanner + extra checks)
~/baudbot/bin/security-audit.sh --deep
```

## Test commands

```bash
# Full test suite
bin/test.sh

# JS/TS only
bin/test.sh js

# Shell only
bin/test.sh shell
```

## Control plane

Start admin-owned control plane dashboard/API:

```bash
~/baudbot/bin/control-plane.sh
```

Recommended with auth token:

```bash
BAUDBOT_CP_TOKEN=$(openssl rand -hex 32) ~/baudbot/bin/control-plane.sh
```

Default local dashboard:

- `http://127.0.0.1:28800/dashboard`

## Common runbook actions

- verify Slack bridge responsiveness
- verify control/sentry/dev sessions are healthy
- clean stale worktrees
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
