# 🐝 Hornet

**Hardened autonomous agent infrastructure. Careful — you might get stung.**

Hornet is an open framework for running always-on AI agents that support software teams — coding agents, automated SREs, QA bots, monitoring, triage, and more. Agents run as isolated Linux processes with defense-in-depth security. Hornet assumes the worst: that an agent *will* be prompt-injected, and builds kernel-level walls that hold even when the LLM is fully compromised.

## Why

Every AI agent framework gives the model shell access and hopes for the best. Hornet doesn't hope — it enforces:

- **OS-level isolation** — dedicated Unix user, no sudo, can't see other processes
- **Kernel-enforced network control** — iptables per-UID egress allowlist
- **Source/runtime separation** — agent can't read or modify its own infrastructure code
- **Dual-layer command blocking** — dangerous shell patterns caught before execution at two independent layers
- **Self-healing** — permissions hardened on every boot, secrets redacted from logs automatically

Agents work on real files in real repos — no sandbox friction. They make real git branches, run real tests, and push real PRs. But they can't exfiltrate data, escalate privileges, or phone home.

## Security Stack

| Layer | What | Survives prompt injection? |
|-------|------|---------------------------|
| **Source isolation** | Source repo is admin-owned, agent has zero read access. Deploy is one-way. | ✅ Filesystem-enforced |
| **iptables egress** | Per-UID firewall chain. Allowlisted ports only, no listeners, no reverse shells. | ✅ Kernel-enforced |
| **Process isolation** | `/proc` mounted `hidepid=2`. Agent can't see other PIDs. | ✅ Kernel-enforced |
| **Shell deny list** | `hornet-safe-bash` blocks rm -rf, reverse shells, fork bombs, curl\|sh. Root-owned. | ✅ Root-owned |
| **Tool call interception** | Pi extension blocks dangerous tool calls before they hit disk or shell. | ✅ Compiled into runtime |
| **Integrity manifest** | Deploy stamps SHA256 hashes of all files. Agent can verify its own runtime hasn't been tampered with. | ✅ Admin-signed |
| **Content wrapping** | External messages wrapped with security boundaries + Unicode homoglyph sanitization. | ⚠️ LLM-dependent |
| **Injection detection** | 12 regex patterns flag suspicious content. Log-only. | ⚠️ Detection, not prevention |
| **Filesystem hardening** | 700 dirs, 600 secrets, enforced on every boot. | ✅ Boot script |
| **Log redaction** | Scrubs API keys, tokens, private keys from session logs. | ✅ Boot script |
| **Extension scanning** | Static analysis for exfiltration, obfuscation, crypto-mining patterns. | ✅ Audit-time |

## Architecture

```
admin_user (your account)
├── ~/hornet/                         ← source repo (agent CANNOT read this)
│   ├── bin/
│   │   ├── deploy.sh                     stages source → /tmp → agent runtime
│   │   ├── security-audit.sh             security posture checks
│   │   ├── setup-firewall.sh             iptables per-UID lockdown
│   │   ├── hornet-safe-bash              shell command deny list (root-owned)
│   │   ├── hornet-docker                 Docker wrapper (blocks escalation)
│   │   ├── harden-permissions.sh         filesystem hardening
│   │   ├── scan-extensions.mjs           extension static analysis
│   │   └── redact-logs.sh               secret scrubber for logs
│   ├── hooks/pre-commit              ← self-modification guardrail
│   ├── pi/
│   │   ├── extensions/                   source of truth for pi extensions
│   │   │   ├── tool-guard.ts        ← 🔒 tool call interception
│   │   │   └── ...
│   │   └── skills/                       source of truth for agent skills
│   ├── slack-bridge/
│   │   ├── bridge.mjs                    Slack ↔ agent bridge
│   │   └── security.mjs            ← 🔒 content wrapping, rate limiting, auth
│   ├── setup.sh                          system setup (run once as root)
│   └── start.sh                          agent launcher (deployed to runtime)

hornet_agent (unprivileged uid)
├── ~/runtime/
│   ├── start.sh                          deployed launcher
│   ├── bin/                              deployed utility scripts
│   └── slack-bridge/                     deployed bridge + security module
├── ~/.pi/agent/
│   ├── extensions/                       deployed pi extensions
│   ├── skills/                           agent-owned operational knowledge
│   ├── hornet-version.json               deploy version (git SHA, timestamp)
│   └── hornet-manifest.json              SHA256 hashes of all deployed files
├── ~/workspace/                          project repos + git worktrees
└── ~/.config/.env                        secrets (600 perms, not in repo)
```

### Deploy model

The admin owns the source. The agent owns the runtime. Deploy is a one-way push:

```
admin: ~/hornet/bin/deploy.sh
  → stages source to /tmp (world-readable temp dir)
  → copies to agent runtime via sudo -u hornet_agent
  → stamps hornet-version.json + hornet-manifest.json
  → cleans up staging dir
```

The agent can verify its own integrity via the manifest without needing source access.

## Quick Start

```bash
# Clone (as admin — source lives in admin's home, not agent's)
git clone <your-hornet-repo-url> ~/hornet

# Setup (creates user, firewall, permissions — run as root)
sudo bash ~/hornet/setup.sh <admin_username>

# Add secrets
sudo su - hornet_agent -c 'vim ~/.config/.env'

# Deploy source → agent runtime
~/hornet/bin/deploy.sh

# Launch
sudo -u hornet_agent ~/runtime/start.sh
```

## Configuration

Secrets and configuration live in `~hornet_agent/.config/.env` (not in repo, 600 perms).
See [CONFIGURATION.md](CONFIGURATION.md) for the full list and how to obtain each value.

## Operations

```bash
# Deploy after editing source
~/hornet/bin/deploy.sh

# Launch agent (in tmux for persistence)
tmux new-window -n hornet 'sudo -u hornet_agent ~/runtime/start.sh'

# Check security posture
~/hornet/bin/security-audit.sh
~/hornet/bin/security-audit.sh --deep   # includes extension scanner

# Monitor agent sessions
sudo -u hornet_agent tmux ls

# Kill everything
sudo -u hornet_agent pkill -u hornet_agent

# Uninstall (reverses setup.sh)
sudo ~/hornet/bin/uninstall.sh --dry-run   # preview
sudo ~/hornet/bin/uninstall.sh             # for real

# Check deployed version
sudo -u hornet_agent cat ~/.pi/agent/hornet-version.json
```

## Tests

```bash
# All 207 tests across 5 suites
bin/test.sh

# JS/TS only
bin/test.sh js

# Shell only
bin/test.sh shell

# Lint + typecheck
npm run lint && npm run typecheck
```

## How It Works

Hornet runs a **control-agent** that spawns specialized sub-agents in tmux sessions and starts a Slack bridge. Out of the box it ships with a dev-agent (coding), sentry-agent (monitoring/triage), and a control-agent (orchestration) — but you can add any agent role. Messages flow:

```
Slack → bridge (access control + content wrapping) → pi agent → tools (tool-guard + safe-bash) → workspace
```

Every layer assumes the previous one failed. The bridge wraps content and rate-limits, but tool-guard blocks dangerous commands even if wrapping is bypassed. Safe-bash blocks patterns even if tool-guard is somehow evaded. The firewall blocks exfiltration even if all software layers fail. Defense in depth, all the way down.

## Security Details

See [SECURITY.md](SECURITY.md) for the full threat model and trust boundary diagram.

## License

MIT
