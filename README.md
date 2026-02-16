# 🐝 Hornet

**Hardened autonomous agent infrastructure. Careful — you might get stung.**

Hornet is an open framework for running AI coding agents as isolated Linux processes with defense-in-depth security. It assumes the worst: that the agent *will* be prompt-injected, and builds kernel-level walls that hold even when the LLM is fully compromised.

## Why

Every AI agent framework gives the model shell access and hopes for the best. Hornet doesn't hope — it enforces:

- **OS-level isolation** — dedicated Unix user, no sudo, can't see other processes
- **Kernel-enforced network control** — iptables per-UID egress allowlist
- **Tamper-proof security** — root-owned hooks prevent the agent from weakening its own defenses
- **Dual-layer command blocking** — dangerous shell patterns caught before execution at two independent layers
- **Self-healing** — permissions hardened on every boot, secrets redacted from logs automatically

## Security Stack

| Layer | What | Survives prompt injection? |
|-------|------|---------------------------|
| **iptables egress** | Per-UID firewall chain. Allowlisted ports only, no listeners, no reverse shells. | ✅ Kernel-enforced |
| **Process isolation** | `/proc` mounted `hidepid=2`. Agent can't see other PIDs. | ✅ Kernel-enforced |
| **Self-modification guard** | Root-owned pre-commit hook + tool-guard extension. Agent can't edit security files. | ✅ Root-owned |
| **Shell deny list** | `hornet-safe-bash` blocks rm -rf, reverse shells, fork bombs, curl\|sh. Root-owned. | ✅ Root-owned |
| **Tool call interception** | Pi extension blocks dangerous tool calls before they hit disk or shell. | ✅ Compiled into runtime |
| **Content wrapping** | External messages wrapped with security boundaries + Unicode homoglyph sanitization. | ⚠️ LLM-dependent |
| **Injection detection** | 12 regex patterns flag suspicious content. Log-only. | ⚠️ Detection, not prevention |
| **Filesystem hardening** | 700 dirs, 600 secrets, enforced on every boot. | ✅ Cron/boot script |
| **Log redaction** | Scrubs API keys, tokens, private keys from session logs. | ✅ Boot script |
| **Extension scanning** | Static analysis for exfiltration, obfuscation, crypto-mining patterns. | ✅ Audit-time |

**202 tests** across 6 test suites. CI runs all tests + `detect-secrets` on every push.

## Architecture

```
hornet_agent (unprivileged uid)
│
├── ~/hornet/                    ← this repo
│   ├── bin/                     ← 🔒 security scripts (all root-protected)
│   │   ├── security-audit.sh         24-check security audit
│   │   ├── setup-firewall.sh         iptables per-UID lockdown
│   │   ├── hornet-safe-bash           shell command deny list
│   │   ├── hornet-docker              Docker wrapper (blocks escalation)
│   │   ├── harden-permissions.sh      filesystem hardening
│   │   ├── scan-extensions.mjs        extension static analysis
│   │   └── redact-logs.sh             secret scrubber for logs
│   ├── hooks/pre-commit         ← 🔒 self-modification guardrail
│   ├── pi/extensions/
│   │   ├── tool-guard.ts        ← 🔒 tool call interception
│   │   └── ...                       agent-modifiable extensions
│   ├── pi/skills/                    agent-modifiable operational knowledge
│   ├── slack-bridge/
│   │   ├── bridge.mjs                Slack ↔ agent bridge
│   │   └── security.mjs        ← 🔒 content wrapping, rate limiting, auth
│   ├── setup.sh                 ← 🔒 system setup (creates user, firewall, etc.)
│   └── SECURITY.md              ← 🔒 threat model
│
├── ~/workspace/                      project repos + git worktrees
└── ~/.config/.env                    secrets (600 perms, not in repo)
```

🔒 = protected by root-owned pre-commit hook + tool-guard rules. Agent cannot modify.

## Quick Start

```bash
# Clone
sudo su - hornet_agent -c 'git clone git@github.com:modem-dev/hornet.git ~/hornet'

# Setup (creates user, firewall, permissions — run as root)
sudo bash /home/hornet_agent/hornet/setup.sh <admin_username>

# Add secrets
sudo su - hornet_agent -c 'vim ~/.config/.env'

# Launch
sudo -u hornet_agent /home/hornet_agent/hornet/start.sh
```

## Configuration

Secrets live in `~/.config/.env` (not in repo, 600 perms):

```bash
GITHUB_TOKEN=...
OPENCODE_ZEN_API_KEY=...
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_ALLOWED_USERS=U01234,U56789   # fail-closed: bridge exits if empty
AGENTMAIL_API_KEY=...
KERNEL_API_KEY=...
SENTRY_AUTH_TOKEN=...
HORNET_SECRET=...
HORNET_ALLOWED_EMAILS=you@example.com
```

## Operations

```bash
# Check security posture (24 checks + optional deep extension scan)
sudo -u hornet_agent ~/hornet/bin/security-audit.sh --deep

# Harden file permissions (runs on every boot)
sudo -u hornet_agent ~/hornet/bin/harden-permissions.sh

# Apply network firewall (run as root)
sudo ~/hornet/bin/setup-firewall.sh

# Redact secrets from session logs
sudo -u hornet_agent ~/hornet/bin/redact-logs.sh

# Monitor agent sessions
sudo -u hornet_agent tmux ls
sudo -u hornet_agent tmux attach -t dev-agent    # Ctrl+b d to detach

# Kill everything
sudo -u hornet_agent pkill -u hornet_agent

# Restart
sudo -u hornet_agent /home/hornet_agent/hornet/start.sh
```

## Tests

```bash
# All 202 tests
sudo -u hornet_agent bash -c "export PATH=~/opt/node-v22.14.0-linux-x64/bin:\$PATH && \
  cd ~/hornet/slack-bridge && node --test security.test.mjs && \
  cd ~/hornet/pi/extensions && node --test tool-guard.test.mjs && \
  cd ~/hornet/bin && node --test scan-extensions.test.mjs && \
  bash hornet-safe-bash.test.sh && bash redact-logs.test.sh && bash security-audit.test.sh"
```

## How It Works

Hornet runs a **control-agent** that spawns sub-agents (dev-agent, sentry-agent) in tmux sessions and starts a Slack bridge. Messages flow:

```
Slack → bridge (access control + content wrapping) → pi agent → tools (tool-guard + safe-bash) → workspace
```

Every layer assumes the previous one failed. The bridge wraps content and rate-limits, but tool-guard blocks dangerous commands even if wrapping is bypassed. Safe-bash blocks patterns even if tool-guard is somehow evaded. The firewall blocks exfiltration even if all software layers fail. Defense in depth, all the way down.

## Security Details

See [SECURITY.md](SECURITY.md) for the full threat model and trust boundary diagram.

## License

MIT
