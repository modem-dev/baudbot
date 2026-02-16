#!/bin/bash
# Port-based network lockdown for hornet_agent
# Run as root: sudo ~/hornet/bin/setup-firewall.sh
#
# OUTBOUND (internet):
#   Allows: HTTP (80), HTTPS (443), SSH (22), DNS (53)
#   Blocks: everything else (reverse shells, raw sockets, non-standard ports)
#
# LOCALHOST:
#   Allows: Slack bridge (7890), Ollama (11434), DNS (53)
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
iptables -D OUTPUT -m owner --uid-owner "$UID_HORNET" -j "$CHAIN" 2>/dev/null || true
iptables -F "$CHAIN" 2>/dev/null || true
iptables -X "$CHAIN" 2>/dev/null || true

# Create a dedicated chain for hornet_agent
iptables -N "$CHAIN"

# ── Localhost: allow only specific services ──────────────────────────────────

# Allow Slack bridge (outbound API)
iptables -A "$CHAIN" -o lo -p tcp --dport 7890 -j ACCEPT

# Allow Ollama (local LLM inference)
iptables -A "$CHAIN" -o lo -p tcp --dport 11434 -j ACCEPT

# Allow DNS on localhost
iptables -A "$CHAIN" -o lo -p udp --dport 53 -j ACCEPT
iptables -A "$CHAIN" -o lo -p tcp --dport 53 -j ACCEPT

# Allow localhost responses (established connections back to us)
iptables -A "$CHAIN" -o lo -m state --state ESTABLISHED,RELATED -j ACCEPT

# Block everything else on localhost
iptables -A "$CHAIN" -o lo -j LOG --log-prefix "HORNET_LOCAL_BLOCKED: " --log-level 4
iptables -A "$CHAIN" -o lo -j DROP

# ── Internet: allow only standard ports ──────────────────────────────────────

# Allow DNS (UDP + TCP)
iptables -A "$CHAIN" -p udp --dport 53 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 53 -j ACCEPT

# Allow HTTP/HTTPS (web browsing, all APIs)
iptables -A "$CHAIN" -p tcp --dport 80 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 443 -j ACCEPT

# Allow SSH (git push/pull)
iptables -A "$CHAIN" -p tcp --dport 22 -j ACCEPT

# Allow established/related (responses to allowed outbound)
iptables -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Log and drop everything else
iptables -A "$CHAIN" -j LOG --log-prefix "HORNET_BLOCKED: " --log-level 4
iptables -A "$CHAIN" -j DROP

# Jump to our chain for all hornet_agent traffic
iptables -A OUTPUT -m owner --uid-owner "$UID_HORNET" -j "$CHAIN"

echo "✅ Firewall active. Rules:"
echo ""
iptables -L "$CHAIN" -n -v --line-numbers
echo ""
echo "Localhost allowed: 7890 (bridge), 11434 (ollama), 53 (dns)"
echo "Internet allowed:  80, 443, 22, 53"
echo "Everything else:   BLOCKED + LOGGED"
echo ""
echo "To remove: sudo iptables -D OUTPUT -m owner --uid-owner $UID_HORNET -j $CHAIN && sudo iptables -F $CHAIN && sudo iptables -X $CHAIN"
echo ""
echo "⚠️  These rules are NOT persistent across reboots."
echo "   To persist, add to a systemd unit or use iptables-save/iptables-restore."
