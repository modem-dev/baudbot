# Configuration

All secrets and configuration live in `~/.config/.env` on the agent's home directory (`/home/baudbot_agent/.config/.env`). This file is `600` permissions and never committed to the repo.

## Schema Validation

Baudbot uses [Varlock](https://varlock.dev) to validate environment variables at startup. The schema (`.env.schema`) is committed to the repo and deployed to `~/.config/.env.schema` alongside the secrets file. It defines types, required/optional status, and sensitivity for each variable.

`start.sh` runs `varlock load` to validate before launching — the agent won't start with missing or malformed variables. The bridge uses `varlock run` to inject validated env vars. Varlock must be installed on the agent system (`brew install dmno-dev/tap/varlock` or `curl -sSfL https://varlock.dev/install.sh | sh -s`).

## Required Variables

### LLM Access

Set at least one. Multiple can coexist — switch models at runtime via `/model`.

| Variable | Provider | How to get it |
|----------|----------|---------------|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| `OPENAI_API_KEY` | OpenAI (GPT, o-series) | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| `GEMINI_API_KEY` | Google Gemini | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| `OPENCODE_ZEN_API_KEY` | OpenCode Zen (multi-provider router) | [opencode.ai](https://opencode.ai) |

### GitHub

The agent uses the `gh` CLI for PRs, checks, and issues. Authenticate with:

```bash
sudo -u baudbot_agent gh auth login
```

This uses the device code flow — it shows a code, you visit [github.com/login/device](https://github.com/login/device) on your browser. The token is stored in `~/.config/gh/hosts.yml` (not in `.env`).

The agent also uses an SSH key (`~/.ssh/id_ed25519`) for git push. Setup generates one automatically. Add the public key to **Settings → SSH keys** on the GitHub account the agent will push as.

### Slack

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `SLACK_BOT_TOKEN` | Slack bot OAuth token (required for direct Socket Mode; ignored by broker pull mode) | Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps). Under **OAuth & Permissions**, add bot scopes: `app_mentions:read`, `chat:write`, `channels:history`, `channels:read`, `reactions:write`, `im:history`, `im:read`, `im:write`. Install the app to your workspace and copy the **Bot User OAuth Token**. |
| `SLACK_APP_TOKEN` | Slack app-level token (required for Socket Mode; not used by broker pull mode) | In your Slack app settings → **Basic Information** → **App-Level Tokens**, create a token with `connections:write` scope. |
| `SLACK_ALLOWED_USERS` | Comma-separated Slack user IDs | **Optional** — if not set, all workspace members can interact. Find your Slack user ID: click your profile → "..." → "Copy member ID". Example: `U01ABCDEF,U02GHIJKL` |

If you're using Slack broker mode (`SLACK_BROKER_*` vars), the runtime uses broker pull delivery and does not require Socket Mode callbacks.

If you're using the Slack broker OAuth flow, register this server after install:

```bash
sudo baudbot broker register \
  --broker-url https://your-broker.example.com \
  --workspace-id T0123ABCD \
  --registration-token <token-from-dashboard-callback>
```

`baudbot setup` is host provisioning only; do not use `baudbot setup --slack-broker`.

### Email Monitor (experimental-only)

Email tooling is disabled by default. To enable it, run setup/install in experimental mode (`baudbot setup --experimental` or `install.sh --experimental`) so `BAUDBOT_EXPERIMENTAL=1` is set.

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `BAUDBOT_EXPERIMENTAL` | Feature flag for risky integrations | Set to `1` to unlock experimental integrations (including email) |
| `AGENTMAIL_API_KEY` | AgentMail API key | [app.agentmail.to](https://app.agentmail.to) — sign up and create an API key |
| `BAUDBOT_EMAIL` | Agent's email address | The email address the control agent monitors (e.g. `your-agent@agentmail.to`). Create the inbox via the AgentMail dashboard or let the agent create it on startup. |
| `BAUDBOT_SECRET` | Shared secret for email authentication | Generate a random string: `openssl rand -hex 32`. Senders must include this in their email for it to be processed. |
| `BAUDBOT_ALLOWED_EMAILS` | Comma-separated sender allowlist | Email addresses allowed to send tasks. Example: `you@example.com,teammate@example.com` |

## Optional Variables

### Sentry Integration

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `SENTRY_AUTH_TOKEN` | Sentry API bearer token | [sentry.io/settings/account/api/auth-tokens](https://sentry.io/settings/account/api/auth-tokens/) — create a token with `project:read`, `event:read`, `issue:read` scopes |
| `SENTRY_ORG` | Sentry organization slug | The slug from your Sentry URL: `sentry.io/organizations/<this-part>/` |
| `SENTRY_CHANNEL_ID` | Slack channel ID for Sentry alerts | The Slack channel where Sentry posts alerts. Right-click the channel → "View channel details" → scroll to the bottom for the Channel ID. |

### Linear Integration

The `linear` extension provides a tool for interacting with the Linear issue tracker. The agent can search, list, create, update, and comment on issues via Linear's GraphQL API.

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `LINEAR_API_KEY` | Linear API key (personal or OAuth token) | Go to [Linear Settings → API](https://linear.app/settings/api), create a **Personal API key**. For workspace-wide access, create an OAuth application instead. The key needs read/write access to issues and comments. |

### Slack Channels

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `SLACK_CHANNEL_ID` | Additional monitored channel | If set, the bridge responds to all messages in this channel (not just @mentions). |

### Slack Broker Registration (optional)

Set by `sudo baudbot broker register` when using brokered Slack OAuth flow.

| Variable | Description |
|----------|-------------|
| `SLACK_BROKER_URL` | Broker base URL |
| `SLACK_BROKER_WORKSPACE_ID` | Slack workspace/team ID (`T...`) |
| `SLACK_BROKER_SERVER_PRIVATE_KEY` | Server X25519 private key (base64) |
| `SLACK_BROKER_SERVER_PUBLIC_KEY` | Server X25519 public key (base64) |
| `SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY` | Server Ed25519 private signing key (base64) |
| `SLACK_BROKER_SERVER_SIGNING_PUBLIC_KEY` | Server Ed25519 public signing key (base64) |
| `SLACK_BROKER_PUBLIC_KEY` | Broker X25519 public key (base64) |
| `SLACK_BROKER_SIGNING_PUBLIC_KEY` | Broker Ed25519 public signing key (base64) |
| `SLACK_BROKER_ACCESS_TOKEN` | Broker-issued bearer token for broker API auth (required for broker pull mode runtime) |
| `SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT` | ISO timestamp for broker token expiry (recommended; runtime exits if expired) |
| `SLACK_BROKER_ACCESS_TOKEN_SCOPES` | Comma-separated broker token scopes |
| `SLACK_BROKER_POLL_INTERVAL_MS` | Inbox poll interval in milliseconds (default: `3000`) |
| `SLACK_BROKER_MAX_MESSAGES` | Max leased messages per poll request (default: `10`) |
| `SLACK_BROKER_WAIT_SECONDS` | Long-poll wait window for `/api/inbox/pull` (default: `20`, set `0` for immediate short-poll, max `25`) |
| `SLACK_BROKER_DEDUPE_TTL_MS` | Dedupe cache TTL in milliseconds (default: `1200000`) |

### Kernel (Cloud Browsers)

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `KERNEL_API_KEY` | Kernel cloud browser API key | [kernel.computer](https://kernel.computer) — sign up and get an API key |

### Tool Guard

| Variable | Description | Default |
|----------|-------------|---------|
| `BAUDBOT_AGENT_USER` | Unix username of the agent | `baudbot_agent` |
| `BAUDBOT_AGENT_HOME` | Agent's home directory | `/home/$BAUDBOT_AGENT_USER` |
| `BAUDBOT_SOURCE_DIR` | Path to admin-owned source repo | *(empty — set this to enable source repo write protection)* |

### Release Updater / Rollback (CLI env overrides)

These are **command-time overrides** for `baudbot update` / `baudbot rollback` (or the underlying scripts). They are not required in `~/.config/.env`.

| Variable | Description | Default |
|----------|-------------|---------|
| `BAUDBOT_RELEASE_ROOT` | Root directory for git-free release snapshots | `/opt/baudbot` |
| `BAUDBOT_RELEASES_DIR` | Release snapshot directory | `$BAUDBOT_RELEASE_ROOT/releases` |
| `BAUDBOT_CURRENT_LINK` | Active release symlink | `$BAUDBOT_RELEASE_ROOT/current` |
| `BAUDBOT_PREVIOUS_LINK` | Previous release symlink | `$BAUDBOT_RELEASE_ROOT/previous` |
| `BAUDBOT_UPDATE_REPO` | Update source repo URL/path override | auto-detected / remembered |
| `BAUDBOT_UPDATE_BRANCH` | Update source branch override | remembered / `main` |

### Setup Overrides

Set during `setup.sh` / `baudbot install` via env vars:

| Variable | Description | Default |
|----------|-------------|---------|
| `BAUDBOT_PI_VERSION` | pi package version installed for `baudbot_agent` | `0.52.12` |
| `GIT_USER_NAME` | Git commit author name | `baudbot-agent` |
| `GIT_USER_EMAIL` | Git commit author email | `baudbot-agent@users.noreply.github.com` |

### Heartbeat

| Variable | Description | Default |
|----------|-------------|---------|
| `HEARTBEAT_INTERVAL_MS` | Interval between heartbeat checks (milliseconds) | `600000` (10 min) |
| `HEARTBEAT_FILE` | Path to heartbeat checklist file | `~/.pi/agent/HEARTBEAT.md` |
| `HEARTBEAT_ENABLED` | Set to `0` or `false` to disable heartbeats | enabled |

### Idle Compaction

| Variable | Description | Default |
|----------|-------------|---------|
| `IDLE_COMPACT_DELAY_MS` | Idle time before checking for compaction (milliseconds, min 60000) | `300000` (5 min) |
| `IDLE_COMPACT_THRESHOLD_PCT` | Context usage % to trigger compaction (10–90) | `25` |
| `IDLE_COMPACT_ENABLED` | Set to `0`, `false`, or `no` to disable idle compaction | enabled |

### Bridge

| Variable | Description | Default |
|----------|-------------|---------|
| `BRIDGE_API_PORT` | Local HTTP API port for outbound Slack messages | `7890` |
| `PI_SESSION_ID` | Target pi session ID for the bridge | Auto-detects control-agent |

## Example `.env` File

```bash
# LLM (set at least one)
ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# GEMINI_API_KEY=...
# OPENCODE_ZEN_API_KEY=...

# GitHub: authenticate with `sudo -u baudbot_agent gh auth login`

# Slack
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_ALLOWED_USERS=U01ABCDEF,U02GHIJKL
SENTRY_CHANNEL_ID=C0987654321

# Slack broker registration (optional, set by: sudo baudbot broker register)
SLACK_BROKER_URL=https://broker.example.com
SLACK_BROKER_WORKSPACE_ID=T0123ABCD
# Optional broker auth token fields (set by broker register when provided)
# SLACK_BROKER_ACCESS_TOKEN=...
# SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT=2026-02-22T22:15:00.000Z
# SLACK_BROKER_ACCESS_TOKEN_SCOPES=slack.send,inbox.pull,inbox.ack
SLACK_BROKER_POLL_INTERVAL_MS=3000
SLACK_BROKER_MAX_MESSAGES=10
SLACK_BROKER_WAIT_SECONDS=20
SLACK_BROKER_DEDUPE_TTL_MS=1200000

# Experimental features (required for email)
# BAUDBOT_EXPERIMENTAL=1
# AGENTMAIL_API_KEY=...
# BAUDBOT_EMAIL=my-agent@agentmail.to
# BAUDBOT_SECRET=<openssl rand -hex 32>
# BAUDBOT_ALLOWED_EMAILS=you@example.com

# Sentry (optional)
SENTRY_AUTH_TOKEN=sntrys_...
SENTRY_ORG=my-org

# Linear (optional)
LINEAR_API_KEY=lin_api_...

# Kernel (optional)
KERNEL_API_KEY=...

# Tool guard
BAUDBOT_SOURCE_DIR=/home/your_username/baudbot
```

## Applying Configuration

Quick key updates after setup (recommended):

```bash
# Update a key in file backend (and mirror runtime when run with sudo)
sudo baudbot env set ANTHROPIC_API_KEY

# Optional: pass value inline + restart automatically
sudo baudbot env set OPENAI_API_KEY sk-... --restart
```

### Optional: move source-of-truth away from `~/.baudbot/.env`

`baudbot env` supports a pluggable source backend:

```bash
# Show active backend
baudbot env backend show

# Use command backend (command must output KEY=VALUE lines)
sudo baudbot env backend set-command 'your-secret-tool export baudbot-prod'

# Sync rendered source env into runtime .env and restart
sudo baudbot env sync --restart
```

This keeps runtime compatibility (`~/.config/.env` is still rendered for varlock/startup) while moving authoritative storage to an external source.

Manual edits also work. After editing `~/.config/.env` directly:

```bash
# Re-deploy config and restart cleanly
sudo baudbot deploy
sudo baudbot restart
```

The bridge and all sub-agents load `~/.config/.env` on startup. If varlock is installed, variables are validated against `.env.schema` before injection.

Session logs are pruned on startup with a default 14-day retention window (`~/runtime/bin/prune-session-logs.sh --days 14`) and then redacted for common secret patterns.
