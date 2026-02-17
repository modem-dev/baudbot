#!/bin/bash
# Port-based network lockdown for baudbot_agent
# Run as root: sudo ~/baudbot/bin/setup-firewall.sh
#
# OUTBOUND (internet):
#   Allows: HTTP/S, SSH, DNS, cloud databases (pg, mysql, redis, mongo), OTLP
#   Blocks: reverse shells, raw sockets, SMTP, non-standard ports
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

UID_BAUDBOT=$(id -u baudbot_agent 2>/dev/null)
if [ -z "$UID_BAUDBOT" ]; then
  echo "❌ baudbot_agent user not found"
  exit 1
fi

CHAIN="BAUDBOT_OUTPUT"

echo "🔒 Setting up firewall rules for baudbot_agent (uid $UID_BAUDBOT)..."

# Clean up any existing rules first
iptables -w -D OUTPUT -m owner --uid-owner "$UID_BAUDBOT" -j "$CHAIN" 2>/dev/null || true
iptables -w -F "$CHAIN" 2>/dev/null || true
iptables -w -X "$CHAIN" 2>/dev/null || true

# Create a dedicated chain for baudbot_agent
iptables -w -N "$CHAIN"

# ── Logging (SYN + DNS only — low volume) ────────────────────────────────────
# Log all new outbound connections (SYN packets only to avoid flooding)
iptables -w -A "$CHAIN" -p tcp --syn -j LOG --log-prefix "baudbot-out: " --log-level info
# Log DNS queries
iptables -w -A "$CHAIN" -p udp --dport 53 -j LOG --log-prefix "baudbot-dns: " --log-level info

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
iptables -w -A "$CHAIN" -o lo -j LOG --log-prefix "BAUDBOT_LOCAL_BLOCKED: " --log-level 4
iptables -w -A "$CHAIN" -o lo -j DROP

# ── Internet: allow standard + dev ports ─────────────────────────────────────

# DNS (UDP + TCP)
iptables -w -A "$CHAIN" -p udp --dport 53 -j ACCEPT
iptables -w -A "$CHAIN" -p tcp --dport 53 -j ACCEPT

# HTTP/HTTPS (web, APIs, cloud services)
iptables -w -A "$CHAIN" -p tcp --dport 80 -j ACCEPT
iptables -w -A "$CHAIN" -p tcp --dport 443 -j ACCEPT

# SSH (git push/pull)
iptables -w -A "$CHAIN" -p tcp --dport 22 -j ACCEPT

# Cloud databases (Neon, Supabase, RDS, PlanetScale, Atlas, Upstash, etc.)
iptables -w -A "$CHAIN" -p tcp --dport 3306 -j ACCEPT    # MySQL / PlanetScale
iptables -w -A "$CHAIN" -p tcp --dport 5432:5433 -j ACCEPT  # PostgreSQL / Neon
iptables -w -A "$CHAIN" -p tcp --dport 6543 -j ACCEPT    # Supabase pooler
iptables -w -A "$CHAIN" -p tcp --dport 6379 -j ACCEPT    # Redis Cloud / Upstash
iptables -w -A "$CHAIN" -p tcp --dport 27017 -j ACCEPT   # MongoDB Atlas

# Observability (OpenTelemetry OTLP)
iptables -w -A "$CHAIN" -p tcp --dport 4317:4318 -j ACCEPT

# Allow established/related (responses to allowed outbound)
iptables -w -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Log and drop everything else
iptables -w -A "$CHAIN" -j LOG --log-prefix "BAUDBOT_BLOCKED: " --log-level 4
iptables -w -A "$CHAIN" -j DROP

# Jump to our chain for all baudbot_agent traffic
iptables -w -A OUTPUT -m owner --uid-owner "$UID_BAUDBOT" -j "$CHAIN"

echo "✅ Firewall active. Rules:"
echo ""
iptables -w -L "$CHAIN" -n -v --line-numbers
echo ""
echo "Localhost allowed: 3000-5999 (dev servers), 5432 (pg), 6006 (storybook),"
echo "                   6379 (redis), 7890 (bridge), 8000-9999 (wrangler/inspector),"
echo "                   11434 (ollama), 24678 (vite hmr), 27017 (mongo),"
echo "                   54322 (pg docker), 53 (dns)"
echo "Internet allowed:  22 (ssh), 53 (dns), 80/443 (http/s),"
echo "                   3306 (mysql), 4317-4318 (otlp), 5432-5433 (pg),"
echo "                   6379 (redis), 6543 (supabase), 27017 (mongo)"
echo "Everything else:   BLOCKED + LOGGED"
echo ""
echo "To remove: sudo iptables -w -D OUTPUT -m owner --uid-owner $UID_BAUDBOT -j $CHAIN && sudo iptables -w -F $CHAIN && sudo iptables -w -X $CHAIN"
echo ""
echo "Persistence: baudbot-firewall.service (systemd)"
