# Architecture

Baudbot separates admin-owned source from agent-owned runtime to reduce blast radius while still enabling always-on autonomous execution.

## Source / release / runtime layout

```text
admin user
├── ~/baudbot/                     # source repo (admin-owned)
│   ├── bin/
│   ├── pi/extensions/
│   ├── pi/skills/
│   └── slack-bridge/              # direct Slack integration (Socket Mode)

root-managed releases
├── /opt/baudbot/
│   ├── releases/<sha>/            # immutable, git-free snapshots
│   ├── current -> releases/<sha>
│   └── previous -> releases/<sha>

baudbot_agent user
├── ~/runtime/                     # deployed runtime used by live agent
├── ~/.pi/agent/                   # skills/extensions/memory/manifests
└── ~/workspace/                   # project repos + task worktrees
```

## Deployment flow

1. Admin updates source repo.
2. Deploy/update scripts build a staged snapshot.
3. Snapshot is published to `/opt/baudbot/releases/<sha>`.
4. Runtime files are deployed for `baudbot_agent`.
5. Symlink switch (`current`) is updated atomically on success.

This allows reproducible releases and fast rollback.

## Agent topology

```text
control-agent (persistent)
├── sentry-agent (persistent/on-demand)
└── dev-agent-* (ephemeral task workers)
```

Inter-session communication is handled over pi session-control sockets.

## Data path summary

```text
Slack/Email → bridge + wrapping → control-agent
            → todo + delegation → dev-agent worktree execution
            → PR/CI outcomes → control-agent response in source thread
```

## Why this architecture

- clear trust boundaries between admin and agent runtime
- predictable operations for deploy/update/rollback
- support for concurrent, task-scoped coding workers
- safer enablement of high-privilege tools via layered controls

For security controls and known risks, see [../SECURITY.md](../SECURITY.md).
