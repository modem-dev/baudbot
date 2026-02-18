# Team Workflow

This page explains how Baudbot handles work from first request to final delivery so teams get quick acknowledgment, autonomous execution, and clear status updates.

## High-level lifecycle

1. **Intake**
   - Request arrives from Slack, email, or direct chat.
   - Control agent treats all external content as untrusted and extracts intent.
2. **Acknowledge**
   - Immediate response in the originating channel/thread ("On it", "Looking now").
3. **Track**
   - Create a todo with source context (channel/thread or email metadata).
4. **Plan + route**
   - Choose the correct repository (or multiple repos if needed).
5. **Execute**
   - Spawn one or more task-scoped `dev-agent` sessions in git worktrees.
6. **Iterate**
   - Dev agent runs code/test/PR/CI loops and reports milestones.
7. **Relay**
   - Control agent posts progress and outcomes back to the same thread.
8. **Close out**
   - Mark todo done, capture results, clean up sessions/worktrees.

## Single-repo flow

```text
Slack thread
  → control-agent todo + ack
  → spawn dev-agent in worktree
  → code + tests + PR + CI fixes
  → completion report
  → control-agent posts PR/summary in same thread
```

## Multi-repo flow

Use either:

- **Sequential mode** for dependent tasks (repo B needs output from repo A)
- **Parallel mode** for independent tasks

Control agent coordinates fan-out/fan-in and keeps the user updated from one thread.

## Follow-up handling

When users add requirements mid-task ("also do X"):

- Keep the same todo and thread
- Forward the update to the active dev-agent
- Continue CI/review loop
- Report updated status

## Failure and escalation policy

If CI keeps failing or work gets stuck:

- Avoid infinite loops
- Post a clear status update with blocker context
- Ask the user to decide next step (scope cut, rollback, manual handoff)
- Preserve state in todo notes

## Operational expectations

- Always reply in-thread for Slack work
- Keep user-facing updates concise and frequent
- Prefer practical artifacts in status updates (PR link, failing check, preview URL)
- Clean up ephemeral resources after completion

For role-level behavior details, see [agents.md](agents.md). For commands and runbook tasks, see [operations.md](operations.md).
