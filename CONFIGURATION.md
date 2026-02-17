# Configuration

All secrets and configuration live in `~/.config/.env` on the agent's home directory (`/home/baudbot_agent/.config/.env`). This file is `600` permissions and never committed to the repo.

## Schema Validation

Baudbot uses [Varlock](https://varlock.dev) to validate environment variables at startup. The schema (`.env.schema`) is committed to the repo and deployed to `~/.config/.env.schema` alongside the secrets file. It defines types, required/optional status, and sensitivity for each variable.

`start.sh` runs `varlock load` to validate before launching — the agent won't start with missing or malformed variables. The bridge uses `varlock run` to inject validated env vars. Varlock must be installed on the agent system (`brew install dmno-dev/tap/varlock` or `curl -sSfL https://varlock.dev/install.sh | sh -s`).

## Required Variables

### LLM Access

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `OPENCODE_ZEN_API_KEY` | API key for the LLM provider | Your LLM provider dashboard (e.g. Anthropic, OpenAI, or a proxy like OpenCode Zen) |

### GitHub

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `GITHUB_TOKEN` | GitHub Personal Access Token | [github.com/settings/tokens](https://github.com/settings/tokens) — create a fine-grained token scoped to the repos you want the agent to access. Minimum scopes: `contents: write`, `pull_requests: write`, `issues: write`. |

The agent also uses an SSH key (`~/.ssh/id_ed25519`) for git push. Setup generates one automatically. Add the public key to **Settings → SSH keys** on the GitHub account the agent will push as.

### Slack

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `SLACK_BOT_TOKEN` | Slack bot OAuth token | Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps). Under **OAuth & Permissions**, add bot scopes: `app_mentions:read`, `chat:write`, `channels:history`, `channels:read`, `reactions:write`, `im:history`, `im:read`, `im:write`. Install the app to your workspace and copy the **Bot User OAuth Token**. |
| `SLACK_APP_TOKEN` | Slack app-level token (Socket Mode) | In your Slack app settings → **Basic Information** → **App-Level Tokens**, create a token with `connections:write` scope. |
| `SLACK_ALLOWED_USERS` | Comma-separated Slack user IDs | **Required** — the bridge refuses to start without at least one user ID. Find your Slack user ID: click your profile → "..." → "Copy member ID". Example: `U01ABCDEF,U02GHIJKL` |

### Email Monitor

| Variable | Description | How to get it |
|----------|-------------|---------------|
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

### Slack Channels

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `SLACK_CHANNEL_ID` | Additional monitored channel | If set, the bridge responds to all messages in this channel (not just @mentions). |

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

### Git Identity

Set during `setup.sh` via env vars (or edit `~/.gitconfig` after):

| Variable | Description | Default |
|----------|-------------|---------|
| `GIT_USER_NAME` | Git commit author name | `baudbot-agent` |
| `GIT_USER_EMAIL` | Git commit author email | `baudbot-agent@users.noreply.github.com` |

### Bridge

| Variable | Description | Default |
|----------|-------------|---------|
| `BRIDGE_API_PORT` | Local HTTP API port for outbound Slack messages | `7890` |
| `PI_SESSION_ID` | Target pi session ID for the bridge | Auto-detects control-agent |

## Example `.env` File

```bash
# LLM
OPENCODE_ZEN_API_KEY=sk-...

# GitHub
GITHUB_TOKEN=ghp_...

# Slack
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_ALLOWED_USERS=U01ABCDEF,U02GHIJKL
SENTRY_CHANNEL_ID=C0987654321

# Email
AGENTMAIL_API_KEY=...
BAUDBOT_EMAIL=my-agent@agentmail.to
BAUDBOT_SECRET=<openssl rand -hex 32>
BAUDBOT_ALLOWED_EMAILS=you@example.com

# Sentry (optional)
SENTRY_AUTH_TOKEN=sntrys_...
SENTRY_ORG=my-org

# Kernel (optional)
KERNEL_API_KEY=...

# Tool guard
BAUDBOT_SOURCE_DIR=/home/your_username/baudbot
```

## Applying Configuration

After editing `~/.config/.env`:

```bash
# Restart the agent to pick up changes
sudo -u baudbot_agent pkill -u baudbot_agent
sudo -u baudbot_agent ~/runtime/start.sh
```

The bridge and all sub-agents load `~/.config/.env` on startup. If varlock is installed, variables are validated against `.env.schema` before injection.
