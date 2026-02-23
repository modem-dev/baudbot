# Agents

Baudbot uses a small multi-agent architecture: one persistent orchestrator and task-scoped workers. This keeps the team-facing interface stable while allowing parallel execution in the background.

## Role overview

| Agent | Lifecycle | Primary responsibility |
|------|-----------|------------------------|
| `control-agent` | Persistent | Intake, triage, delegation, user communication, orchestration |
| `dev-agent` | Ephemeral per task | Code changes, tests, PRs, CI/review iteration |
| `sentry-agent` | Persistent/on-demand | Sentry alert triage and investigation support |

## Control-agent

The control-agent is the team-facing coordinator.

Responsibilities:

- monitor inbound requests (Slack; email only when experimental mode is enabled)
- create and manage todos
- select target repo(s)
- spawn and supervise dev-agent sessions
- relay progress/results to users
- enforce operational guardrails (cleanup, escalation)

It should remain lightweight on coding itself and focus on orchestration quality.

## Dev-agent

The dev-agent is a coding worker launched in a dedicated git worktree for each task.
Execution backend can be:
- native `pi`, or
- CLI (`claude` / `codex`) behind a session-control shim.

Responsibilities:

- read project guidance (`CODEX.md`, `AGENTS.md`, `CLAUDE.md` as available)
- implement requested changes
- run tests/build checks
- open PR and monitor CI
- fix failures and address review comments
- report completion details back to control-agent

Each dev-agent is task-scoped and should exit when work is done.

## Sentry-agent

The sentry-agent handles incident-oriented analysis.

Responsibilities:

- investigate Sentry issues by issue ID
- summarize likely impact and root cause
- provide actionable recommendations for fixes
- hand off coding tasks to dev-agent through control-agent

## Session model

- Control and sentry sessions are long-lived.
- Dev sessions are ephemeral and tied to todos.
- Session-control sockets allow inter-agent messaging (`send_to_session`) for both native and CLI-backed dev-agents.
- Naming conventions encode role and task context (for observability and cleanup).

## Concurrency

Baudbot limits concurrent dev agents to keep resource usage predictable and avoid context thrash.

Use this model when scaling:

- keep a fixed max active dev-agent count
- queue additional tasks
- prioritize by urgency or user/channel policy

## Communication contract

- **Users talk to control-agent**
- **Dev-agent reports to control-agent**
- **Control-agent reports back to users**

This keeps the external interface stable while allowing internal execution strategies to evolve.

For flow details, see [team-workflow.md](team-workflow.md).
