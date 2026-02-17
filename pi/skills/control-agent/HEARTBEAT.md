# Heartbeat Checklist

Check each item and take action only if something is wrong.

- Check all agent sessions are alive (`list_sessions` — confirm `sentry-agent` exists, check for orphaned `dev-agent-*` sessions with no matching active todo)
- Verify Slack bridge is responsive (`curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7890/send -H 'Content-Type: application/json' -d '{}'` → should return 400)
- Check email monitor is running (`email_monitor status` — should show active)
- Check for stale worktrees in `~/workspace/worktrees/` that don't correspond to active in-progress todos — clean them up with `git worktree remove`
- Check for stuck todos (status `in-progress` for more than 2 hours with no corresponding dev-agent session) — escalate to user via Slack
