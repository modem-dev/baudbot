# Architecture

Baudbot runs live operations from release snapshots under `/opt/baudbot`, with an agent-owned runtime under `/home/baudbot_agent`.

## Release / runtime layout (production)

```text
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

## Deployment source vs live runtime

`baudbot update` publishes a git-free snapshot into `/opt/baudbot/releases/<sha>` and runs live execution from that release path.

## Deployment flow

1. Update is initiated from a target ref/repo.
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

Dev agents can run on:
- native `pi` sessions, or
- CLI backends (`claude`, `codex`) wrapped by a session-control compatibility shim.

Inter-session communication remains socket-based in both cases, so control-agent keeps using the same `send_to_session` / `list_sessions` workflow.

## Data path summary

```text
Slack (email optional via experimental mode) → bridge + wrapping → control-agent
            → todo + delegation → dev-agent worktree execution
            → PR/CI outcomes → control-agent response in source thread
```

## Why this architecture

- clear trust boundaries between admin and agent runtime
- predictable operations for deploy/update/rollback
- support for concurrent, task-scoped coding workers
- safer enablement of high-privilege tools via layered controls (policy layers plus OS-level boundaries)

For security controls and known risks, see [../SECURITY.md](../SECURITY.md).
