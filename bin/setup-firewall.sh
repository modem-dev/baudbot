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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
bb_enable_strict_mode
bb_init_paths

bb_require_root "setup-firewall"

UID_BAUDBOT=$(id -u "$BAUDBOT_AGENT_USER" 2>/dev/null)
if [ -z "$UID_BAUDBOT" ]; then
  echo "❌ $BAUDBOT_AGENT_USER user not found"
  exit 1
fi

CHAIN="BAUDBOT_OUTPUT"
IPTABLES_BIN="iptables"
if command -v iptables-nft >/dev/null 2>&1 && iptables-nft -w -L OUTPUT -n >/dev/null 2>&1; then
  IPTABLES_BIN="iptables-nft"
fi

fw() {
  "$IPTABLES_BIN" -w "$@"
}

add_optional_rule() {
  if ! fw "$@"; then
    echo "⚠️  Optional firewall rule unsupported by kernel, skipping: $IPTABLES_BIN -w $*" >&2
  fi
}

echo "🔒 Setting up firewall rules for $BAUDBOT_AGENT_USER (uid $UID_BAUDBOT)..."
echo "   backend: $IPTABLES_BIN"

# Clean up any existing rules first
fw -D OUTPUT -m owner --uid-owner "$UID_BAUDBOT" -j "$CHAIN" 2>/dev/null || true
fw -F "$CHAIN" 2>/dev/null || true
fw -X "$CHAIN" 2>/dev/null || true

# Create a dedicated chain for baudbot_agent
fw -N "$CHAIN"

# ── Logging (SYN + DNS only — low volume) ────────────────────────────────────
# Some kernels (notably certain cloud Arch images) lack optional LOG/tcp xtables
# modules. Treat logging rules as best-effort; the allow/drop policy is mandatory.
add_optional_rule -A "$CHAIN" -p tcp --syn -j LOG --log-prefix "baudbot-out: " --log-level info
add_optional_rule -A "$CHAIN" -p udp --dport 53 -j LOG --log-prefix "baudbot-dns: " --log-level info

# ── Localhost: allow only specific services ──────────────────────────────────

# ── Dev servers & frameworks ──────────────────────────────────────────────
# 3000-3999: Next.js, Express, Remix, generic web servers
# 4000-4999: Astro (4321), Remix (4200), Nuxt, etc.
# 5000-5999: Vite (5173), Flask, generic dev servers
# 6000-6099: Storybook (6006), Expo (6100 range is X11 — skip 6063+)
fw -A "$CHAIN" -o lo -p tcp --dport 3000:5999 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 6006 -j ACCEPT

# ── Databases ────────────────────────────────────────────────────────────
# 5432: PostgreSQL (native)
# 6379: Redis
# 27017: MongoDB
# 54322: PostgreSQL (Docker-mapped)
fw -A "$CHAIN" -o lo -p tcp --dport 5432 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 6379 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 27017 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 54322 -j ACCEPT

# ── Infrastructure ───────────────────────────────────────────────────────
# 7890: Gateway bridge
# 8000-9999: Wrangler (8787), Django/FastAPI (8000), inspector (9229+), MinIO (9000)
# 11434: Ollama
# 24678: Vite HMR websocket
fw -A "$CHAIN" -o lo -p tcp --dport 7890 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 8000:9999 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 11434 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 24678 -j ACCEPT

# Allow DNS on localhost
fw -A "$CHAIN" -o lo -p udp --dport 53 -j ACCEPT
fw -A "$CHAIN" -o lo -p tcp --dport 53 -j ACCEPT

# Allow localhost responses (established connections back to us)
fw -A "$CHAIN" -o lo -m state --state ESTABLISHED,RELATED -j ACCEPT

# Block everything else on localhost
add_optional_rule -A "$CHAIN" -o lo -j LOG --log-prefix "BAUDBOT_LOCAL_BLOCKED: " --log-level 4
fw -A "$CHAIN" -o lo -j DROP

# ── Internet: allow standard + dev ports ─────────────────────────────────────

# DNS (UDP + TCP)
fw -A "$CHAIN" -p udp --dport 53 -j ACCEPT
fw -A "$CHAIN" -p tcp --dport 53 -j ACCEPT

# HTTP/HTTPS (web, APIs, cloud services)
fw -A "$CHAIN" -p tcp --dport 80 -j ACCEPT
fw -A "$CHAIN" -p tcp --dport 443 -j ACCEPT

# SSH (git push/pull)
fw -A "$CHAIN" -p tcp --dport 22 -j ACCEPT

# Cloud databases (Neon, Supabase, RDS, PlanetScale, Atlas, Upstash, etc.)
fw -A "$CHAIN" -p tcp --dport 3306 -j ACCEPT      # MySQL / PlanetScale
fw -A "$CHAIN" -p tcp --dport 5432:5433 -j ACCEPT # PostgreSQL / Neon
fw -A "$CHAIN" -p tcp --dport 6543 -j ACCEPT      # Supabase pooler
fw -A "$CHAIN" -p tcp --dport 6379 -j ACCEPT      # Redis Cloud / Upstash
fw -A "$CHAIN" -p tcp --dport 27017 -j ACCEPT     # MongoDB Atlas

# Observability (OpenTelemetry OTLP)
fw -A "$CHAIN" -p tcp --dport 4317:4318 -j ACCEPT

# Allow established/related (responses to allowed outbound)
fw -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Log and drop everything else
add_optional_rule -A "$CHAIN" -j LOG --log-prefix "BAUDBOT_BLOCKED: " --log-level 4
fw -A "$CHAIN" -j DROP

# Jump to our chain for all baudbot_agent traffic
fw -A OUTPUT -m owner --uid-owner "$UID_BAUDBOT" -j "$CHAIN"

echo "✅ Firewall active. Rules:"
echo ""
fw -L "$CHAIN" -n -v --line-numbers
echo ""
echo "Localhost allowed: 3000-5999 (dev servers), 5432 (pg), 6006 (storybook),"
echo "                   6379 (redis), 7890 (gateway bridge), 8000-9999 (wrangler/inspector),"
echo "                   11434 (ollama), 24678 (vite hmr), 27017 (mongo),"
echo "                   54322 (pg docker), 53 (dns)"
echo "Internet allowed:  22 (ssh), 53 (dns), 80/443 (http/s),"
echo "                   3306 (mysql), 4317-4318 (otlp), 5432-5433 (pg),"
echo "                   6379 (redis), 6543 (supabase), 27017 (mongo)"
echo "Everything else:   BLOCKED + LOGGED"
echo ""
echo "To remove: sudo $IPTABLES_BIN -w -D OUTPUT -m owner --uid-owner $UID_BAUDBOT -j $CHAIN && sudo $IPTABLES_BIN -w -F $CHAIN && sudo $IPTABLES_BIN -w -X $CHAIN"
echo ""
echo "Persistence: baudbot-firewall.service (systemd)"
