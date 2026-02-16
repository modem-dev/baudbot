#!/bin/bash
# Port-based network lockdown for hornet_agent
# Run as root: sudo ~/hornet/bin/setup-firewall.sh
#
# OUTBOUND (internet):
#   Allows: HTTP (80), HTTPS (443), SSH (22), DNS (53)
#   Blocks: everything else (reverse shells, raw sockets, non-standard ports)
#
# LOCALHOST:
#   Allows: Dev servers (3000-3999, 5173, 6006, 8787-8800, 9229-9260),
#           Slack bridge (7890), Ollama (11434), PostgreSQL (54322), DNS (53)
#   Blocks: everything else (Steam, CUPS, Tailscale admin, unknown services)
#
# The agent cannot:
# - Open reverse shells on non-standard ports
# - Talk to localhost services it doesn't need (Steam, CUPS, Tailscale UI)
# - Bind to ports (no inbound listeners/backdoors)
# - Do DNS tunneling over non-53 UDP

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Must run as root (sudo $0)"
  exit 1
fi

UID_HORNET=$(id -u hornet_agent 2>/dev/null)
if [ -z "$UID_HORNET" ]; then
  echo "❌ hornet_agent user not found"
  exit 1
fi

CHAIN="HORNET_OUTPUT"

echo "🔒 Setting up firewall rules for hornet_agent (uid $UID_HORNET)..."

# Clean up any existing rules first
iptables -w -D OUTPUT -m owner --uid-owner "$UID_HORNET" -j "$CHAIN" 2>/dev/null || true
iptables -w -F "$CHAIN" 2>/dev/null || true
iptables -w -X "$CHAIN" 2>/dev/null || true

# Create a dedicated chain for hornet_agent
iptables -w -N "$CHAIN"

# ── Localhost: allow only specific services ──────────────────────────────────

# ── Infrastructure ────────────────────────────────────────────────────────
# Slack bridge (outbound API)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 7890 -j ACCEPT
# Ollama (local LLM inference)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 11434 -j ACCEPT
# PostgreSQL in Docker (modem app)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 54322 -j ACCEPT

# ── Dev servers (for running/testing modem app locally) ──────────────────
# Next.js (dashboard, website)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 3000:3999 -j ACCEPT
# Vite
iptables -w -A "$CHAIN" -o lo -p tcp --dport 5173 -j ACCEPT
# Storybook
iptables -w -A "$CHAIN" -o lo -p tcp --dport 6006 -j ACCEPT
# Wrangler dev servers (Cloudflare Workers)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 8787:8800 -j ACCEPT
# Node/Wrangler inspector (debugging)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 9229:9260 -j ACCEPT

# Allow DNS on localhost
iptables -w -A "$CHAIN" -o lo -p udp --dport 53 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 53 -j ACCEPT

# Allow localhost responses (established connections back to us)
iptables -w -A "$CHAIN" -o lo -m state --state ESTABLISHED,RELATED -j ACCEPT

# Block everything else on localhost
iptables -w -A "$CHAIN" -o lo -j LOG --log-prefix "HORNET_LOCAL_BLOCKED: " --log-level 4
iptables -w -A "$CHAIN" -o lo -j DROP

# ── Internet: allow only standard ports ──────────────────────────────────────

# Allow DNS (UDP + TCP)
iptables -w -A "$CHAIN" -p udp --dport 53 -j ACCEPT
iptables -w -A "$CHAIN" -p tcp --dport 53 -j ACCEPT

# Allow HTTP/HTTPS (web browsing, all APIs)
iptables -w -A "$CHAIN" -p tcp --dport 80 -j ACCEPT
iptables -w -A "$CHAIN" -p tcp --dport 443 -j ACCEPT

# Allow SSH (git push/pull)
iptables -w -A "$CHAIN" -p tcp --dport 22 -j ACCEPT

# Allow established/related (responses to allowed outbound)
iptables -w -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Log and drop everything else
iptables -w -A "$CHAIN" -j LOG --log-prefix "HORNET_BLOCKED: " --log-level 4
iptables -w -A "$CHAIN" -j DROP

# Jump to our chain for all hornet_agent traffic
iptables -w -A OUTPUT -m owner --uid-owner "$UID_HORNET" -j "$CHAIN"

echo "✅ Firewall active. Rules:"
echo ""
iptables -w -L "$CHAIN" -n -v --line-numbers
echo ""
echo "Localhost allowed: 3000-3999 (next), 5173 (vite), 6006 (storybook),"
echo "                   7890 (bridge), 8787-8800 (wrangler), 9229-9260 (inspector),"
echo "                   11434 (ollama), 54322 (postgres), 53 (dns)"
echo "Internet allowed:  80, 443, 22, 53"
echo "Everything else:   BLOCKED + LOGGED"
echo ""
echo "To remove: sudo iptables -w -D OUTPUT -m owner --uid-owner $UID_HORNET -j $CHAIN && sudo iptables -w -F $CHAIN && sudo iptables -w -X $CHAIN"
echo ""
echo "Persistence: hornet-firewall.service (systemd)"
