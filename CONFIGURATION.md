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
| `GATEWAY_BOT_TOKEN` | **Preferred** bot OAuth token for Socket Mode (ignored by broker pull mode) | Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps). Under **OAuth & Permissions**, add bot scopes: `app_mentions:read`, `chat:write`, `channels:history`, `channels:read`, `reactions:write`, `im:history`, `im:read`, `im:write`. Install the app to your workspace and copy the **Bot User OAuth Token**. |
| `SLACK_BOT_TOKEN` | Legacy alias for `GATEWAY_BOT_TOKEN` (still supported) | Same token as above; migrate to `GATEWAY_BOT_TOKEN` over time. |
| `GATEWAY_APP_TOKEN` | **Preferred** app-level token for Socket Mode | In your Slack app settings → **Basic Information** → **App-Level Tokens**, create a token with `connections:write` scope. |
| `SLACK_APP_TOKEN` | Legacy alias for `GATEWAY_APP_TOKEN` (still supported) | Same token as above; migrate to `GATEWAY_APP_TOKEN` over time. |
| `GATEWAY_ALLOWED_USERS` | **Preferred** comma-separated Slack user IDs allowlist | **Optional** — if not set, all workspace members can interact. Find your Slack user ID: click your profile → "..." → "Copy member ID". Example: `U01ABCDEF,U02GHIJKL` |
| `SLACK_ALLOWED_USERS` | Legacy alias for `GATEWAY_ALLOWED_USERS` (still supported) | Same value as above; migrate to `GATEWAY_ALLOWED_USERS` over time. |

If both alias forms are present, `GATEWAY_*` takes precedence.

If you're using broker mode (`GATEWAY_BROKER_*` preferred, `SLACK_BROKER_*` legacy), the runtime uses broker pull delivery and does not require Socket Mode callbacks.

If you're using the Slack broker OAuth flow, register this server after install:

```bash
sudo baudbot broker register \
  --broker-url https://your-broker.example.com \
  --org-id org_1234abcd \
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

### Notion Integration

The `notion` extension provides a read-only tool for accessing your Notion workspace. The agent can search for pages and databases, retrieve full page content (including nested blocks), query database entries, and inspect database schemas.

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `NOTION_API_KEY` | Notion integration secret (internal integration token) | Go to [Notion → My integrations](https://www.notion.so/my-integrations), create a new **Internal Integration**. Copy the **Internal Integration Token** (starts with `secret_`). After creating the integration, share the pages/databases you want the agent to access by clicking **"•••"** → **Add connections** → select your integration. The integration can only read content explicitly shared with it. |

**Capabilities:**
- `search` — Find pages and databases by text query or type filter
- `get` — Read full page content with all blocks (paragraphs, headings, lists, code, callouts, etc.)
- `list` — Query database entries with filters and sorting
- `database` — Inspect database schema and property types

**Permissions:**  
The integration token only provides read access to pages/databases explicitly shared with the integration. It cannot create, update, or delete content.

### Slack Channels

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `GATEWAY_CHANNEL_ID` | **Preferred** additional monitored channel | If set, the bridge responds to all messages in this channel (not just @mentions). |
| `SLACK_CHANNEL_ID` | Legacy alias for `GATEWAY_CHANNEL_ID` (still supported) | Same value as above; migrate to `GATEWAY_CHANNEL_ID` over time. |

### Slack Broker Registration (optional)

Set by `sudo baudbot broker register` when using brokered Slack OAuth flow.

| Variable | Description |
|----------|-------------|
| `GATEWAY_BROKER_URL` | **Preferred** broker base URL |
| `SLACK_BROKER_URL` | Legacy alias for `GATEWAY_BROKER_URL` (still supported) |
| `GATEWAY_BROKER_ORG_ID` | **Preferred** broker org ID |
| `SLACK_BROKER_ORG_ID` | Legacy alias for `GATEWAY_BROKER_ORG_ID` |
| `GATEWAY_BROKER_WORKSPACE_ID` | Deprecated workspace/team ID alias (still accepted for migration) |
| `SLACK_BROKER_WORKSPACE_ID` | Deprecated alias for `GATEWAY_BROKER_WORKSPACE_ID` |
| `GATEWAY_BROKER_SERVER_PRIVATE_KEY` | **Preferred** server X25519 private key (base64) |
| `SLACK_BROKER_SERVER_PRIVATE_KEY` | Legacy alias for `GATEWAY_BROKER_SERVER_PRIVATE_KEY` |
| `GATEWAY_BROKER_SERVER_PUBLIC_KEY` | **Preferred** server X25519 public key (base64) |
| `SLACK_BROKER_SERVER_PUBLIC_KEY` | Legacy alias for `GATEWAY_BROKER_SERVER_PUBLIC_KEY` |
| `GATEWAY_BROKER_SERVER_SIGNING_PRIVATE_KEY` | **Preferred** server Ed25519 private signing key (base64) |
| `SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY` | Legacy alias for `GATEWAY_BROKER_SERVER_SIGNING_PRIVATE_KEY` |
| `GATEWAY_BROKER_SERVER_SIGNING_PUBLIC_KEY` | **Preferred** server Ed25519 public signing key (base64) |
| `SLACK_BROKER_SERVER_SIGNING_PUBLIC_KEY` | Legacy alias for `GATEWAY_BROKER_SERVER_SIGNING_PUBLIC_KEY` |
| `GATEWAY_BROKER_PUBLIC_KEY` | **Preferred** broker X25519 public key (base64) |
| `SLACK_BROKER_PUBLIC_KEY` | Legacy alias for `GATEWAY_BROKER_PUBLIC_KEY` |
| `GATEWAY_BROKER_SIGNING_PUBLIC_KEY` | **Preferred** broker Ed25519 public signing key (base64) |
| `SLACK_BROKER_SIGNING_PUBLIC_KEY` | Legacy alias for `GATEWAY_BROKER_SIGNING_PUBLIC_KEY` |
| `GATEWAY_BROKER_ACCESS_TOKEN` | **Preferred** broker-issued bearer token for broker API auth (required for broker pull mode runtime) |
| `SLACK_BROKER_ACCESS_TOKEN` | Legacy alias for `GATEWAY_BROKER_ACCESS_TOKEN` |
| `GATEWAY_BROKER_ACCESS_TOKEN_EXPIRES_AT` | **Preferred** ISO timestamp for broker token expiry (runtime exits if expired) |
| `SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT` | Legacy alias for `GATEWAY_BROKER_ACCESS_TOKEN_EXPIRES_AT` |
| `GATEWAY_BROKER_ACCESS_TOKEN_SCOPES` | **Preferred** comma-separated broker token scopes |
| `SLACK_BROKER_ACCESS_TOKEN_SCOPES` | Legacy alias for `GATEWAY_BROKER_ACCESS_TOKEN_SCOPES` |
| `GITHUB_IGNORED_USERS` | Optional comma-separated GitHub logins to ignore when forwarding broker GitHub events (`baudbot-agent` is always ignored) |
| `GATEWAY_BROKER_POLL_INTERVAL_MS` | **Preferred** inbox poll interval in milliseconds (default: `3000`) |
| `SLACK_BROKER_POLL_INTERVAL_MS` | Legacy alias for `GATEWAY_BROKER_POLL_INTERVAL_MS` |
| `GATEWAY_BROKER_MAX_MESSAGES` | **Preferred** max leased messages per poll request (default: `10`) |
| `SLACK_BROKER_MAX_MESSAGES` | Legacy alias for `GATEWAY_BROKER_MAX_MESSAGES` |
| `GATEWAY_BROKER_WAIT_SECONDS` | **Preferred** long-poll wait window for `/api/inbox/pull` (default: `20`, set `0` for immediate short-poll, max `25`) |
| `SLACK_BROKER_WAIT_SECONDS` | Legacy alias for `GATEWAY_BROKER_WAIT_SECONDS` |
| `GATEWAY_BROKER_DEDUPE_TTL_MS` | **Preferred** dedupe cache TTL in milliseconds (default: `1200000`) |
| `SLACK_BROKER_DEDUPE_TTL_MS` | Legacy alias for `GATEWAY_BROKER_DEDUPE_TTL_MS` |
| `BAUDBOT_AGENT_VERSION` | Optional override for broker observability `meta.agent_version` (otherwise read from `~/.pi/agent/baudbot-version.json` when available) |

If both alias forms are set, `GATEWAY_BROKER_*` takes precedence.

Broker mode also emits best-effort context usage telemetry in inbox pull `meta` by reading `~/.pi/agent/context-usage.json` (written by the `context` extension on session start/turn end/tool results).

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
| `BAUDBOT_RUNTIME_NODE_VERSION` | embedded Node.js version downloaded to `~/opt/node-v<version>-linux-x64` (with stable symlink `~/opt/node`) | `22.14.0` |
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

### Startup Integrity

| Variable | Description | Default |
|----------|-------------|---------|
| `BAUDBOT_STARTUP_INTEGRITY_MODE` | Startup manifest verification mode: `off`, `warn`, `strict` | `warn` |

On startup, Baudbot verifies deployed runtime files against `~/.pi/agent/baudbot-manifest.json` and records the result in `~/.pi/agent/manifest-integrity-status.json`.

- `warn`: log high-severity warnings but continue startup
- `strict`: fail startup on missing/mismatched files or unreadable manifest
- `off`: skip verification (not recommended)

### Bridge

| Variable | Description | Default |
|----------|-------------|---------|
| `BRIDGE_API_PORT` | Local HTTP API port for outbound Slack messages | `7890` |
| `PI_SESSION_ID` | Target pi session ID for the bridge | Auto-detects control-agent |
| `BAUDBOT_BRIDGE_RESTART_POLICY` | Bridge supervisor mode (`legacy` or `adaptive`) | auto (`legacy` unless adaptive knobs are set) |
| `BAUDBOT_BRIDGE_RESTART_BASE_DELAY_SECONDS` | Adaptive mode base restart delay | `5` |
| `BAUDBOT_BRIDGE_RESTART_MAX_DELAY_SECONDS` | Adaptive mode max backoff delay | `300` |
| `BAUDBOT_BRIDGE_RESTART_STABLE_WINDOW_SECONDS` | Runtime window that resets failure/backoff counters | `120` |
| `BAUDBOT_BRIDGE_RESTART_MAX_CONSECUTIVE_FAILURES` | Threshold that marks supervisor state as degraded (`threshold_exceeded`) | `5` |
| `BAUDBOT_BRIDGE_RESTART_JITTER_SECONDS` | Random jitter added to each adaptive restart sleep | `2` |

## Example `.env` File

```bash
# LLM (set at least one)
ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# GEMINI_API_KEY=...
# OPENCODE_ZEN_API_KEY=...

# GitHub: authenticate with `sudo -u baudbot_agent gh auth login`

# Gateway bridge (legacy SLACK_* aliases are still supported)
GATEWAY_BOT_TOKEN=xoxb-...
GATEWAY_APP_TOKEN=xapp-...
GATEWAY_ALLOWED_USERS=U01ABCDEF,U02GHIJKL
SENTRY_CHANNEL_ID=C0987654321

# Gateway broker registration (optional, set by: sudo baudbot broker register)
GATEWAY_BROKER_URL=https://broker.example.com
GATEWAY_BROKER_ORG_ID=org_1234abcd
# Optional broker auth token fields (set by broker register when provided)
# GATEWAY_BROKER_ACCESS_TOKEN=...
# GATEWAY_BROKER_ACCESS_TOKEN_EXPIRES_AT=2026-02-22T22:15:00.000Z
# GATEWAY_BROKER_ACCESS_TOKEN_SCOPES=slack.send,inbox.pull,inbox.ack
# Optional GitHub bot/user filters for broker-delivered GitHub webhook events
# GITHUB_IGNORED_USERS=dependabot[bot],renovate[bot]
GATEWAY_BROKER_POLL_INTERVAL_MS=3000
GATEWAY_BROKER_MAX_MESSAGES=10
GATEWAY_BROKER_WAIT_SECONDS=20
GATEWAY_BROKER_DEDUPE_TTL_MS=1200000

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
