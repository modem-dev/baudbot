# Linux Runtime

Baudbot is designed to run as Linux-native infrastructure, not a browser-only assistant, so it can execute against your real stack instead of a simulated environment.

## Execution model

- runs as unprivileged `baudbot_agent` user
- operates in real filesystem workspaces and git worktrees
- executes shell commands, test suites, and build pipelines directly
- supports container workflows via guarded Docker wrapper

## What this enables for teams

- run actual project commands (lint/test/build/migrate)
- validate fixes against real local/runtime dependencies
- automate browser tasks through cloud browser tooling
- handle long-running operational loops in tmux/systemd

## Docker support

Agents must use:

```bash
sudo /usr/local/bin/baudbot-docker
```

This wrapper blocks common privilege-escalation patterns (for example, privileged mode and unsafe host mounts).

## Process and workspace model

```text
/home/baudbot_agent/
├── runtime/           # deployed runtime files
├── .pi/agent/         # extensions, skills, memory, manifests
└── workspace/         # repos + git worktrees used by dev agents
```

Dev agents work inside `~/workspace/worktrees/<branch>` and should not commit directly from base repo checkouts.

## Platform support

Validated in CI against:

- Ubuntu 24.04
- Arch Linux

Baudbot scripts aim to remain distro-agnostic across standard Linux environments.

## Operational boundaries

Linux-native does not mean unrestricted root access:

- no general sudo for agents
- security-critical files are read-only at runtime
- network controls can restrict outbound traffic
- source/runtime separation limits self-tampering blast radius

See [SECURITY.md](../SECURITY.md) for threat model details.
