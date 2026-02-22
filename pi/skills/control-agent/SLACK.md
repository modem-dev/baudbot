# Slack Integration Reference

## Sending Messages

**Primary — bridge local API** (works in both broker and Socket Mode):
```bash
curl -s -X POST http://127.0.0.1:7890/send \
  -H 'Content-Type: application/json' \
  -d '{"channel":"CHANNEL_ID","text":"your message","thread_ts":"optional"}'
```

**Add a reaction:**
```bash
curl -s -X POST http://127.0.0.1:7890/react \
  -H 'Content-Type: application/json' \
  -d '{"channel":"CHANNEL_ID","timestamp":"msg_ts","emoji":"white_check_mark"}'
```

**Fallback — direct Slack Web API** (only if bridge is down and `SLACK_BOT_TOKEN` is available; won't work in broker mode since the bot token lives on the broker):
```bash
source ~/.config/.env && curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"channel":"CHANNEL_ID","text":"your message","thread_ts":"optional"}'
```

## Known Channels

Channel IDs are configured via env vars in `~/.config/.env`:
| Channel | Env Var |
|---------|---------|
| Sentry alerts | `SENTRY_CHANNEL_ID` |

Reply to whichever channel the original request came from (thread context includes the channel ID).

## Message Context

Incoming Slack messages arrive wrapped with security boundaries. Extract **Channel** and **Thread** from the metadata:
```
<<<EXTERNAL_UNTRUSTED_CONTENT>>>
Source: Slack
From: <@UXXXXXXX>
Channel: <#C07ABCDEF>
Thread: 1739581234.567890
---
the actual user message here
<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>
```

Use the Thread value as `thread_ts` when calling `/send` to reply in the same thread.

## Response Guidelines

1. **Acknowledge immediately** — reply in the same thread so the user knows you received it.
2. **Always reply in-thread** — never post to channel top-level; always include `thread_ts`.
3. **Report results to the same thread** — don't just update the todo; the user is waiting in Slack.
4. **Keep it conversational** — Slack uses mrkdwn, not full markdown. Bullet points and bold are fine; skip headers and code blocks unless sharing actual code.
5. **Post progress updates** if work takes >2 minutes.
6. **Never silently fail** — if something breaks, tell the user in the thread.
7. **Vercel preview links** — share preview URLs from dev-agent completion reports in the Slack thread.

## Manual Bridge Restart

If the bridge needs manual restart (normally handled by `startup-cleanup.sh`):
```bash
MY_UUID=$(readlink ~/.pi/session-control/control-agent.alias | sed 's/.sock$//')
tmux kill-session -t slack-bridge 2>/dev/null || true
tmux new-session -d -s slack-bridge \
  "unset PKG_EXECPATH; export PATH=\$HOME/.varlock/bin:\$HOME/opt/node-v22.14.0-linux-x64/bin:\$PATH && export PI_SESSION_ID=$MY_UUID && cd ~/runtime/slack-bridge && exec varlock run --path ~/.config/ -- node broker-bridge.mjs"
```

Verify: `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:7890/send -H 'Content-Type: application/json' -d '{}'` → should return `400`.
