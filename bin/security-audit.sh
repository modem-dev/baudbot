#!/bin/bash
# Security audit for Hornet agent infrastructure
# Run as hornet_agent or admin user to check security posture
#
# Usage: ~/hornet/bin/security-audit.sh [--deep]
#        sudo -u hornet_agent ~/hornet/bin/security-audit.sh --deep
#
# --deep: Run the Node.js extension scanner for cross-pattern analysis

set -euo pipefail

HORNET_HOME="${HORNET_HOME:-/home/hornet_agent}"
DEEP=0
for arg in "$@"; do
  if [ "$arg" = "--deep" ]; then
    DEEP=1
  fi
done

# Counters
critical=0
warn=0
info=0
pass=0

finding() {
  local severity="$1"
  local title="$2"
  local detail="${3:-}"

  case "$severity" in
    CRITICAL) echo "  ❌ CRITICAL: $title"; critical=$((critical + 1)) ;;
    WARN)     echo "  ⚠️  WARN:     $title"; warn=$((warn + 1)) ;;
    INFO)     echo "  ℹ️  INFO:     $title"; info=$((info + 1)) ;;
  esac
  [ -n "$detail" ] && echo "              $detail"
}

ok() {
  echo "  ✅ PASS:     $1"
  pass=$((pass + 1))
}

echo ""
echo "🔒 Hornet Security Audit"
echo "========================"
echo ""

# ── Docker group ─────────────────────────────────────────────────────────────

echo "Docker Access"
if id hornet_agent 2>/dev/null | grep -q '(docker)'; then
  finding "CRITICAL" "hornet_agent is in docker group" \
    "Can bypass hornet-docker wrapper via /usr/bin/docker directly"
else
  ok "hornet_agent not in docker group"
fi

if [ -f /usr/local/bin/hornet-docker ]; then
  ok "Docker wrapper installed at /usr/local/bin/hornet-docker"
else
  finding "WARN" "Docker wrapper not found" \
    "Expected /usr/local/bin/hornet-docker"
fi
echo ""

# ── Filesystem permissions ───────────────────────────────────────────────────

echo "Filesystem Permissions"

check_perms() {
  local path="$1"
  local expected="$2"
  local desc="$3"
  if [ ! -e "$path" ]; then
    return
  fi
  actual=$(stat -c '%a' "$path" 2>/dev/null || echo "???")
  if [ "$actual" = "$expected" ]; then
    ok "$desc ($actual)"
  else
    local sev="WARN"
    # Group/world readable secrets or state = critical
    if [ "$expected" = "600" ] || [ "$expected" = "700" ]; then
      # Check if actually group/world readable
      if [ $((0$actual & 044)) -ne 0 ]; then
        sev="CRITICAL"
      fi
    fi
    finding "$sev" "$desc is $actual (expected $expected)" "$path"
  fi
}

check_perms "$HORNET_HOME/.config/.env" "600" "Secrets file"
check_perms "$HORNET_HOME/.ssh" "700" "SSH directory"
check_perms "$HORNET_HOME/.pi" "700" "Pi state directory"
check_perms "$HORNET_HOME/.pi/agent" "700" "Pi agent directory"
check_perms "$HORNET_HOME/.pi/session-control" "700" "Pi session-control directory"
check_perms "$HORNET_HOME/.pi/agent/settings.json" "600" "Pi settings"

# Check session logs
if [ -d "$HORNET_HOME/.pi/agent/sessions" ]; then
  leaky_logs=$(find "$HORNET_HOME/.pi/agent/sessions" -name '*.jsonl' -perm /044 2>/dev/null | wc -l)
  if [ "$leaky_logs" -gt 0 ]; then
    finding "WARN" "$leaky_logs session log(s) are group/world-readable" \
      "Run: ~/hornet/bin/harden-permissions.sh"
  else
    ok "Session logs are owner-only"
  fi
fi

# Check control sockets
if [ -d "$HORNET_HOME/.pi/session-control" ]; then
  leaky_socks=$(find "$HORNET_HOME/.pi/session-control" -name '*.sock' -perm /044 2>/dev/null | wc -l)
  if [ "$leaky_socks" -gt 0 ]; then
    finding "WARN" "$leaky_socks control socket(s) are group/world-accessible" \
      "Other users could send commands to running agent sessions"
  else
    ok "Control sockets are owner-only"
  fi
fi
echo ""

# ── Secrets in readable files ────────────────────────────────────────────────

echo "Secret Exposure"
# Check for secrets in group-readable files (skip .env which should be 600)
secret_patterns='(sk-[a-zA-Z0-9]{20,}|xoxb-|xapp-|ghp_[a-zA-Z0-9]{36}|AKIA[A-Z0-9]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)'
leaked_files=$(find "$HORNET_HOME" -maxdepth 3 \
  -not -path '*/.ssh/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/.config/.env' \
  -not -path '*/security-audit.sh' \
  -not -path '*/.env.schema' \
  -not -name '*.md' \
  -not -name 'bridge.mjs' \
  -not -name 'security.mjs' \
  -not -name 'redact-logs.sh' \
  -not -name 'scan-extensions.mjs' \
  -not -name 'setup.sh' \
  -type f -perm /044 \
  -exec grep -l -E "$secret_patterns" {} \; 2>/dev/null | head -5 || true)

if [ -n "$leaked_files" ]; then
  finding "CRITICAL" "Possible secrets in group/world-readable files:" ""
  echo "$leaked_files" | while read -r f; do echo "              $f"; done
else
  ok "No secrets found in readable files"
fi

# Check git config for tokens
if [ -f "$HORNET_HOME/.gitconfig" ]; then
  if grep -qiE '(token|password|secret)' "$HORNET_HOME/.gitconfig" 2>/dev/null; then
    finding "WARN" "Possible credentials in .gitconfig" "$HORNET_HOME/.gitconfig"
  else
    ok "No credentials in .gitconfig"
  fi
fi

# Check for stale .env copies outside .config
stale_envs=$(find "$HORNET_HOME" -maxdepth 3 \
  -name '.env' -not -path '*/.config/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  2>/dev/null | head -5 || true)
if [ -n "$stale_envs" ]; then
  finding "WARN" "Found .env file(s) outside ~/.config:" ""
  echo "$stale_envs" | while read -r f; do echo "              $f"; done
else
  ok "No stale .env copies found"
fi

# Check git history for committed secrets
if [ -d "$HORNET_HOME/hornet/.git" ]; then
  git_secrets=$(cd "$HORNET_HOME/hornet" && git log --all -p --diff-filter=A 2>/dev/null \
    | grep -cE '(sk-[a-zA-Z0-9]{20,}|xoxb-[0-9]|xapp-[0-9]|ghp_[a-zA-Z0-9]{36}|AKIA[A-Z0-9]{16})' 2>/dev/null || true)
  git_secrets="${git_secrets:-0}"
  if [ "$git_secrets" -gt 0 ]; then
    finding "CRITICAL" "$git_secrets potential secret(s) found in git history" \
      "Run: git log --all -p | grep -nE 'sk-|xoxb-|xapp-|ghp_|AKIA'"
  else
    ok "No secrets detected in git history"
  fi
fi

# Check .gitignore excludes .env
if [ -f "$HORNET_HOME/hornet/.gitignore" ]; then
  if grep -q '\.env' "$HORNET_HOME/hornet/.gitignore" 2>/dev/null; then
    ok ".gitignore excludes .env files"
  else
    finding "WARN" ".gitignore does not exclude .env files" \
      "Add '*.env' or '.env' to $HORNET_HOME/hornet/.gitignore"
  fi
elif [ -d "$HORNET_HOME/hornet/.git" ]; then
  finding "WARN" "No .gitignore found in repo" \
    "Create $HORNET_HOME/hornet/.gitignore with at minimum: .env"
fi

# Scan session logs for accidentally logged secrets
if [ -d "$HORNET_HOME/.pi/agent/sessions" ]; then
  log_secrets=$(find "$HORNET_HOME/.pi/agent/sessions" -name '*.jsonl' \
    -exec grep -lE '(sk-[a-zA-Z0-9]{20,}|xoxb-[0-9]{10,}|xapp-[0-9]{10,})' {} \; 2>/dev/null | wc -l || true)
  log_secrets="${log_secrets:-0}"
  if [ "$log_secrets" -gt 0 ]; then
    finding "CRITICAL" "$log_secrets session log(s) contain possible API keys/tokens" \
      "Review and redact: find ~/.pi/agent/sessions -name '*.jsonl' -exec grep -l 'sk-\|xoxb-\|xapp-' {} +"
  else
    ok "No secrets detected in session logs"
  fi
fi
echo ""

# ── Process Isolation ─────────────────────────────────────────────────────────

echo "Process Isolation"
proc_mount=$(grep '^proc /proc' /proc/mounts 2>/dev/null || true)
if echo "$proc_mount" | grep -q 'hidepid=2'; then
  ok "/proc mounted with hidepid=2 (hornet_agent can only see own processes)"
else
  finding "WARN" "/proc not mounted with hidepid=2" \
    "hornet_agent can see all system processes — run setup.sh or: sudo mount -o remount,hidepid=2,gid=<procview_gid> /proc"
fi
echo ""

# ── Network ──────────────────────────────────────────────────────────────────

echo "Network"

# Check if bridge is bound to localhost only
bridge_bind=$(ss -tlnp 2>/dev/null | grep ':7890' | awk '{print $4}' | head -1)
if [ -n "$bridge_bind" ]; then
  if echo "$bridge_bind" | grep -q '127.0.0.1'; then
    ok "Slack bridge bound to 127.0.0.1:7890"
  else
    finding "CRITICAL" "Slack bridge bound to $bridge_bind (not localhost!)" \
      "Should bind to 127.0.0.1 only"
  fi
else
  finding "INFO" "Slack bridge not running" ""
fi

# Check firewall rules
if command -v iptables &>/dev/null; then
  if iptables -L HORNET_OUTPUT -n 2>/dev/null | grep -q 'DROP'; then
    ok "Firewall rules active (HORNET_OUTPUT chain)"

    # Check localhost isolation (blanket -o lo ACCEPT = bad)
    if iptables -L HORNET_OUTPUT -n 2>/dev/null | grep -qE 'ACCEPT.*lo\s+0\.0\.0\.0/0\s+0\.0\.0\.0/0\s*$'; then
      finding "WARN" "Firewall allows ALL localhost traffic" \
        "Agent can reach every local service (Steam, CUPS, Tailscale, etc.). Update setup-firewall.sh"
    else
      ok "Localhost traffic restricted to specific ports"
    fi
  else
    finding "WARN" "No firewall rules for hornet_agent" \
      "Run: sudo ~/hornet/bin/setup-firewall.sh"
  fi
fi

# Check for firewall persistence
if [ -f /etc/systemd/system/hornet-firewall.service ]; then
  ok "Firewall persistence configured (systemd)"
elif [ -f /etc/iptables/rules.v4 ] && grep -q 'HORNET_OUTPUT' /etc/iptables/rules.v4 2>/dev/null; then
  ok "Firewall persistence configured (iptables-save)"
else
  finding "WARN" "Firewall rules are NOT persistent across reboots" \
    "Install: sudo cp ~/hornet/bin/hornet-firewall.service /etc/systemd/system/ && sudo systemctl enable hornet-firewall"
fi
echo ""

# ── Services ─────────────────────────────────────────────────────────────────

echo "Services"
if ss -tlnp 2>/dev/null | grep -q ':11434'; then
  bind_addr=$(ss -tlnp 2>/dev/null | grep ':11434' | awk '{print $4}' | head -1)
  if echo "$bind_addr" | grep -qE '(0\.0\.0\.0|\*|::)'; then
    finding "INFO" "Ollama listening on $bind_addr (all interfaces)" \
      "Consider binding to 127.0.0.1 if not needed externally"
  else
    ok "Ollama bound to $bind_addr"
  fi
fi
echo ""

# ── Tool Safety ──────────────────────────────────────────────────────────────

echo "Tool Safety"

# Check bash wrapper
if [ -f /usr/local/bin/hornet-safe-bash ]; then
  if [ ! -w /usr/local/bin/hornet-safe-bash ]; then
    ok "Safe bash wrapper installed (not agent-writable)"
  else
    finding "WARN" "hornet-safe-bash is writable by current user" \
      "Should be root-owned: sudo chown root:root /usr/local/bin/hornet-safe-bash"
  fi
else
  finding "INFO" "Safe bash wrapper not installed" \
    "Optional defense-in-depth: install /usr/local/bin/hornet-safe-bash"
fi
echo ""

# ── Extension / Skill Vetting ────────────────────────────────────────────────

echo "Extension & Skill Safety"

# Check pi extensions for suspicious patterns
suspicious_extension_patterns='(eval\s*\(|new\s+Function\s*\(|child_process|execSync|execFile|spawn\s*\(|writeFileSync.*\/etc|writeFileSync.*\/home\/(?!hornet_agent))'
ext_dirs=(
  "$HORNET_HOME/.pi/agent/extensions"
  "$HORNET_HOME/hornet/pi/extensions"
)
ext_findings=0
for ext_dir in "${ext_dirs[@]}"; do
  if [ -d "$ext_dir" ]; then
    while IFS= read -r ext_file; do
      if grep -qP "$suspicious_extension_patterns" "$ext_file" 2>/dev/null; then
        finding "WARN" "Suspicious pattern in extension: $(basename "$ext_file")" "$ext_file"
        ext_findings=$((ext_findings + 1))
      fi
    done < <(find "$ext_dir" -not -path '*/node_modules/*' -type f \( -name '*.ts' -o -name '*.js' -o -name '*.mjs' \) 2>/dev/null)
  fi
done
if [ "$ext_findings" -eq 0 ]; then
  ok "No suspicious patterns in extensions"
fi

# Check skills for dangerous tool instructions
skill_dirs=(
  "$HORNET_HOME/.pi/agent/skills"
  "$HORNET_HOME/hornet/pi/skills"
)
skill_findings=0
for skill_dir in "${skill_dirs[@]}"; do
  if [ -d "$skill_dir" ]; then
    while IFS= read -r skill_file; do
      # Check for skills that might instruct the agent to do dangerous things
      if grep -qiP '(ignore\s+(previous|all)\s+instructions|override\s+safety|disable\s+security)' "$skill_file" 2>/dev/null; then
        finding "CRITICAL" "Skill attempts to override safety: $(basename "$(dirname "$skill_file")")" "$skill_file"
        skill_findings=$((skill_findings + 1))
      fi
    done < <(find "$skill_dir" -type f -name '*.md' 2>/dev/null)
  fi
done
if [ "$skill_findings" -eq 0 ]; then
  ok "No safety-override patterns in skills"
fi

# Check for unexpected node_modules in extension dirs
for ext_dir in "${ext_dirs[@]}"; do
  if [ -d "$ext_dir" ]; then
    unexpected_modules=$(find "$ext_dir" -name 'node_modules' -type d 2>/dev/null | wc -l)
    if [ "$unexpected_modules" -gt 0 ]; then
      finding "WARN" "$unexpected_modules unexpected node_modules in extensions" \
        "Extensions should be self-contained — review dependencies"
    fi
  fi
done

# Deep scan: cross-pattern analysis via Node scanner
if [ "$DEEP" -eq 1 ]; then
  NODE_BIN="$HORNET_HOME/opt/node-v22.14.0-linux-x64/bin/node"
  SCANNER="$HORNET_HOME/hornet/bin/scan-extensions.mjs"
  if [ -x "$NODE_BIN" ] && [ -f "$SCANNER" ]; then
    echo ""
    echo "Deep Extension Scan (cross-pattern analysis)"
    deep_output=$("$NODE_BIN" "$SCANNER" \
      "$HORNET_HOME/hornet/pi/extensions" \
      "$HORNET_HOME/hornet/pi/skills" 2>&1 || true)
    deep_critical=$(echo "$deep_output" | grep -c '❌ CRITICAL' || true)
    deep_warn=$(echo "$deep_output" | grep -c '⚠️' || true)
    if [ "$deep_critical" -gt 0 ]; then
      finding "WARN" "$deep_critical cross-pattern critical finding(s) in deep scan" \
        "Run: node ~/hornet/bin/scan-extensions.mjs for details"
    elif [ "$deep_warn" -gt 0 ]; then
      finding "INFO" "$deep_warn cross-pattern warning(s) in deep scan" \
        "Run: node ~/hornet/bin/scan-extensions.mjs for details"
    else
      ok "Deep extension scan clean"
    fi
  else
    finding "INFO" "Deep scanner not available (Node or scanner not found)" ""
  fi
fi

# Check that bridge security.mjs exists and is tested
if [ -f "$HORNET_HOME/hornet/slack-bridge/security.mjs" ]; then
  ok "Bridge security module exists"
  if [ -f "$HORNET_HOME/hornet/slack-bridge/security.test.mjs" ]; then
    ok "Bridge security tests exist"
  else
    finding "WARN" "No tests for bridge security module" \
      "Add security.test.mjs"
  fi
else
  finding "WARN" "Bridge security module not found" \
    "Expected $HORNET_HOME/hornet/slack-bridge/security.mjs"
fi
echo ""

# ── Bridge Config ────────────────────────────────────────────────────────────

echo "Bridge Configuration"

# Check SLACK_ALLOWED_USERS is set (without reading the actual value)
if [ -f "$HORNET_HOME/.config/.env" ]; then
  if grep -q '^SLACK_ALLOWED_USERS=' "$HORNET_HOME/.config/.env" 2>/dev/null; then
    allowed_count=$(grep '^SLACK_ALLOWED_USERS=' "$HORNET_HOME/.config/.env" 2>/dev/null | cut -d= -f2 | tr ',' '\n' | grep -c . || echo 0)
    if [ "$allowed_count" -gt 0 ]; then
      ok "SLACK_ALLOWED_USERS configured ($allowed_count user(s))"
    else
      finding "CRITICAL" "SLACK_ALLOWED_USERS is empty" \
        "Bridge will refuse to start — add at least one user ID"
    fi
  else
    finding "CRITICAL" "SLACK_ALLOWED_USERS not set in .env" \
      "Bridge will refuse to start — add SLACK_ALLOWED_USERS=U..."
  fi
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

echo "Summary"
echo "───────"
echo "  ✅ Pass:     $pass"
echo "  ❌ Critical: $critical"
echo "  ⚠️  Warn:     $warn"
echo "  ℹ️  Info:     $info"
echo ""

if [ "$critical" -gt 0 ]; then
  echo "🚨 $critical critical finding(s) — fix immediately!"
  exit 2
elif [ "$warn" -gt 0 ]; then
  echo "⚠️  $warn warning(s) — review recommended."
  exit 1
else
  echo "✅ All checks passed."
  exit 0
fi
