{
  "id": "8bbaa7ca",
  "title": "Rename: iptables chain HORNET_OUTPUT → BAUDBOT_OUTPUT",
  "tags": [
    "rename"
  ],
  "status": "done",
  "created_at": "2026-02-17T04:32:14.022Z"
}

Rename iptables chain and log prefixes:
- `HORNET_OUTPUT` → `BAUDBOT_OUTPUT`
- `HORNET_BLOCKED` → `BAUDBOT_BLOCKED`
- `HORNET_LOCAL_BLOCKED` → `BAUDBOT_LOCAL_BLOCKED`
- `hornet-out:` → `baudbot-out:` (log prefix)
- `hornet-dns:` → `baudbot-dns:` (log prefix)

Files: `bin/setup-firewall.sh`, `bin/uninstall.sh`, `bin/security-audit.sh` + test
