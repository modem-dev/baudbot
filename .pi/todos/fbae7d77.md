{
  "id": "fbae7d77",
  "title": "README: Add \"Integrations\" section (Slack, GitHub, email, Sentry, etc.)",
  "tags": [
    "readme"
  ],
  "status": "done",
  "created_at": "2026-02-17T05:03:25.858Z"
}

OpenClaw prominently lists its channels (WhatsApp, Telegram, Slack, etc.). We should do the same for our integrations, but honestly — we have fewer, so keep it tight.

Add an "Integrations" section (after Capabilities, before Requirements):

| Integration | How | Status |
|---|---|---|
| **Slack** | Socket Mode bridge, @mentions + channel monitoring, rate-limited | ✅ Built-in |
| **GitHub** | SSH + PAT, PRs via `gh`, branch/commit/push | ✅ Built-in |
| **Email** | AgentMail inboxes, send/receive/monitor | ✅ Built-in |
| **Sentry** | API integration, alert triage from Slack channel | ✅ Built-in |
| **Docker** | Security wrapper blocks privilege escalation | ✅ Built-in |
| **Cloud Browser** | Kernel browser, Playwright automation | ✅ Extension |

Note: Unlike OpenClaw which supports 15+ messaging platforms, Baudbot focuses on Slack as the primary human interface. Email (AgentMail) is for agent-to-agent and automated workflows. Adding more channels (Discord, Teams) is straightforward — the bridge pattern is extensible.
