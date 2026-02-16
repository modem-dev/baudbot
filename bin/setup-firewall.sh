#!/bin/bash
# Port-based network lockdown for hornet_agent
# Run as root: sudo ~/hornet/bin/setup-firewall.sh
#
# OUTBOUND (internet):
#   Allows: HTTP (80), HTTPS (443), SSH (22), DNS (53)
#   Blocks: everything else (reverse shells, raw sockets, non-standard ports)
#
# LOCALHOST:
#   Allows: Dev servers & databases on common ports (see rules below)
#   Blocks: system services (CUPS, X11, D-Bus, Tailscale admin, etc.)
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

# ── Dev servers & frameworks ──────────────────────────────────────────────
# 3000-3999: Next.js, Express, Remix, generic web servers
# 4000-4999: Astro (4321), Remix (4200), Nuxt, etc.
# 5000-5999: Vite (5173), Flask, generic dev servers
# 6000-6099: Storybook (6006), Expo (6100 range is X11 — skip 6063+)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 3000:5999 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 6006 -j ACCEPT

# ── Databases ────────────────────────────────────────────────────────────
# 5432: PostgreSQL (native)
# 6379: Redis
# 27017: MongoDB
# 54322: PostgreSQL (Docker-mapped)
iptables -w -A "$CHAIN" -o lo -p tcp --dport 5432 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 6379 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 27017 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 54322 -j ACCEPT

# ── Infrastructure ───────────────────────────────────────────────────────
# 7890: Slack bridge
# 8000-9999: Wrangler (8787), Django/FastAPI (8000), inspector (9229+), MinIO (9000)
# 11434: Ollama
# 24678: Vite HMR websocket
iptables -w -A "$CHAIN" -o lo -p tcp --dport 7890 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 8000:9999 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 11434 -j ACCEPT
iptables -w -A "$CHAIN" -o lo -p tcp --dport 24678 -j ACCEPT

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
echo "Localhost allowed: 3000-5999 (dev servers), 5432 (pg), 6006 (storybook),"
echo "                   6379 (redis), 7890 (bridge), 8000-9999 (wrangler/inspector),"
echo "                   11434 (ollama), 24678 (vite hmr), 27017 (mongo),"
echo "                   54322 (pg docker), 53 (dns)"
echo "Internet allowed:  80, 443, 22, 53"
echo "Everything else:   BLOCKED + LOGGED"
echo ""
echo "To remove: sudo iptables -w -D OUTPUT -m owner --uid-owner $UID_HORNET -j $CHAIN && sudo iptables -w -F $CHAIN && sudo iptables -w -X $CHAIN"
echo ""
echo "Persistence: hornet-firewall.service (systemd)"
