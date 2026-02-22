#!/bin/bash
# Security audit for Baudbot agent infrastructure
# Run as baudbot_agent or admin user to check security posture
#
# Usage: ~/baudbot/bin/security-audit.sh [--deep] [--fix]
#        sudo -u baudbot_agent ~/baudbot/bin/security-audit.sh --deep
#        sudo -u baudbot_agent ~/baudbot/bin/security-audit.sh --fix
#
# --deep: Run the Node.js extension scanner for cross-pattern analysis
# --fix:  Auto-remediate findings where possible

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
bb_enable_strict_mode
bb_init_paths

# Source repo — auto-detect from this script's location, or use env override
BAUDBOT_SRC="${BAUDBOT_SRC:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/lib/json-common.sh"

DEEP=0
FIX=0
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --fix)  FIX=1 ;;
  esac
done

# Counters
critical=0
warn=0
info=0
pass=0
fixed=0
skipped=0
fix_errors=0

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

# fix_action: attempt a remediation and report result
# Usage: fix_action "description" command [args...]
fix_action() {
  local desc="$1"
  shift
  if [ "$FIX" -ne 1 ]; then
    return 1  # signal: not fixed (caller should emit finding)
  fi
  if "$@" 2>/dev/null; then
    echo "  🔧 FIXED:    $desc"
    fixed=$((fixed + 1))
    return 0
  else
    echo "  ❌ FIX-ERR:  $desc (command failed)"
    fix_errors=$((fix_errors + 1))
    return 1
  fi
}

# fix_skip: report that fix was skipped (needs root, manual intervention, etc.)
fix_skip() {
  local desc="$1"
  local reason="$2"
  if [ "$FIX" -eq 1 ]; then
    echo "  ⏭️  SKIPPED:  $desc — $reason"
    skipped=$((skipped + 1))
  fi
}

echo ""
echo "🔒 Baudbot Security Audit"
echo "========================"
if [ "$FIX" -eq 1 ]; then
  echo "   Mode: auto-fix enabled"
fi
echo ""

# ── Docker group ─────────────────────────────────────────────────────────────

echo "Docker Access"
if id "$BAUDBOT_AGENT_USER" 2>/dev/null | grep -q '(docker)'; then
  finding "CRITICAL" "$BAUDBOT_AGENT_USER is in docker group" \
    "Can bypass baudbot-docker wrapper via /usr/bin/docker directly"
  fix_skip "Remove from docker group" "Requires root: sudo gpasswd -d $BAUDBOT_AGENT_USER docker"
else
  ok "$BAUDBOT_AGENT_USER not in docker group"
fi

if [ -f /usr/local/bin/baudbot-docker ]; then
  ok "Docker wrapper installed at /usr/local/bin/baudbot-docker"
else
  finding "WARN" "Docker wrapper not found" \
    "Expected /usr/local/bin/baudbot-docker"
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
    if fix_action "chmod $expected $path" chmod "$expected" "$path"; then
      ok "$desc ($expected) [fixed]"
    else
      finding "$sev" "$desc is $actual (expected $expected)" "$path"
    fi
  fi
}

check_perms "$BAUDBOT_HOME/.config/.env" "600" "Secrets file"
check_perms "$BAUDBOT_HOME/.ssh" "700" "SSH directory"
check_perms "$BAUDBOT_HOME/.pi" "700" "Pi state directory"
check_perms "$BAUDBOT_HOME/.pi/agent" "700" "Pi agent directory"
check_perms "$BAUDBOT_HOME/.pi/session-control" "700" "Pi session-control directory"
check_perms "$BAUDBOT_HOME/.pi/agent/settings.json" "600" "Pi settings"

# Check session logs
if [ -d "$BAUDBOT_HOME/.pi/agent/sessions" ]; then
  leaky_logs=$(find "$BAUDBOT_HOME/.pi/agent/sessions" -name '*.jsonl' -perm /044 2>/dev/null | wc -l)
  if [ "$leaky_logs" -gt 0 ]; then
    if fix_action "Fix $leaky_logs session log permissions" \
      find "$BAUDBOT_HOME/.pi/agent/sessions" -name '*.jsonl' -perm /044 -exec chmod 600 {} +; then
      ok "Session logs fixed to owner-only"
    else
      finding "WARN" "$leaky_logs session log(s) are group/world-readable" \
        "Run: ~/baudbot/bin/harden-permissions.sh"
    fi
  else
    ok "Session logs are owner-only"
  fi
fi

# Check control sockets
if [ -d "$BAUDBOT_HOME/.pi/session-control" ]; then
  leaky_socks=$(find "$BAUDBOT_HOME/.pi/session-control" -name '*.sock' -perm /044 2>/dev/null | wc -l)
  if [ "$leaky_socks" -gt 0 ]; then
    if fix_action "Fix $leaky_socks control socket permissions" \
      find "$BAUDBOT_HOME/.pi/session-control" -name '*.sock' -perm /044 -exec chmod 600 {} +; then
      ok "Control sockets fixed to owner-only"
    else
      finding "WARN" "$leaky_socks control socket(s) are group/world-accessible" \
        "Other users could send commands to running agent sessions"
    fi
  else
    ok "Control sockets are owner-only"
  fi
fi
echo ""

# ── Source Isolation & Integrity ──────────────────────────────────────────────

echo "Source Isolation & Integrity"

# Source repo lives outside agent's home — agent should not be able to read it
if [ -r "$BAUDBOT_SRC/setup.sh" ] 2>/dev/null; then
  # If we're running as admin, this is expected — check agent can't
  agent_can_read=$(sudo -u "$BAUDBOT_AGENT_USER" test -r "$BAUDBOT_SRC/setup.sh" 2>/dev/null && echo "yes" || echo "no")
  if [ "$agent_can_read" = "yes" ]; then
    finding "WARN" "Agent can read source repo at $BAUDBOT_SRC" \
      "Ensure admin home is 700: chmod 700 $(dirname "$BAUDBOT_SRC")"
  else
    ok "Source repo not readable by agent"
  fi
fi

# Check extensions/skills are real dirs, not symlinks into source
# shellcheck disable=SC2088  # tildes in log messages are intentional
if [ -L "$BAUDBOT_HOME/.pi/agent/extensions" ]; then
  finding "CRITICAL" "~/.pi/agent/extensions is a symlink (should be a real dir)" \
    "Run: rm ~/.pi/agent/extensions && mkdir ~/.pi/agent/extensions && deploy.sh"
else
  ok "~/.pi/agent/extensions/ is a real directory"
fi

# shellcheck disable=SC2088
if [ -L "$BAUDBOT_HOME/.pi/agent/skills" ]; then
  finding "CRITICAL" "~/.pi/agent/skills is a symlink (should be a real dir)" \
    "Run: rm ~/.pi/agent/skills && mkdir ~/.pi/agent/skills && deploy.sh"
else
  ok "~/.pi/agent/skills/ is a real directory"
fi

BRIDGE_DIR="$BAUDBOT_CURRENT_LINK/slack-bridge"
# shellcheck disable=SC2088
if [ -d "$BRIDGE_DIR" ]; then
  ok "Release bridge directory exists ($BRIDGE_DIR)"
else
  finding "WARN" "release bridge directory not found" \
    "Expected: $BRIDGE_DIR (run: sudo baudbot update)"
fi

# Check version stamp exists
VERSION_FILE="$BAUDBOT_HOME/.pi/agent/baudbot-version.json"
MANIFEST_FILE="$BAUDBOT_HOME/.pi/agent/baudbot-manifest.json"

if [ -f "$VERSION_FILE" ]; then
  deploy_sha="$(json_get_string_or_empty "$VERSION_FILE" "short")"
  deploy_ts="$(json_get_string_or_empty "$VERSION_FILE" "deployed_at")"
  [ -n "$deploy_sha" ] || deploy_sha="?"
  [ -n "$deploy_ts" ] || deploy_ts="?"
  ok "Deployed version: $deploy_sha ($deploy_ts)"
else
  finding "WARN" "No version stamp found — run deploy.sh" ""
fi

# Check runtime integrity via manifest (no source access needed)
if [ -f "$MANIFEST_FILE" ]; then
  tampered=0
  missing=0

  # Check security-critical files against manifest
  for critical_file in \
    ".pi/agent/extensions/tool-guard.ts" \
    ".pi/agent/extensions/tool-guard.test.mjs" \
    "release/slack-bridge/security.mjs" \
    "release/slack-bridge/security.test.mjs"; do

    if [[ "$critical_file" == release/* ]]; then
      full_path="$BAUDBOT_CURRENT_LINK/${critical_file#release/}"
    else
      full_path="$BAUDBOT_HOME/$critical_file"
    fi
    if [ ! -f "$full_path" ]; then
      finding "WARN" "Missing critical file: $critical_file" "Run deploy.sh"
      missing=$((missing + 1))
      continue
    fi

    expected_hash=$(grep "\"$critical_file\"" "$MANIFEST_FILE" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' || echo "")
    if [ -z "$expected_hash" ]; then
      finding "WARN" "$critical_file not in manifest" "Run deploy.sh to regenerate"
      continue
    fi

    actual_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1)
    if [ "$actual_hash" = "$expected_hash" ]; then
      ok "$critical_file: integrity OK"
    else
      finding "CRITICAL" "$critical_file: HASH MISMATCH (possibly tampered)" \
        "Re-deploy: ~/baudbot/bin/deploy.sh"
      tampered=$((tampered + 1))
    fi
  done

  [ "$tampered" -eq 0 ] && [ "$missing" -eq 0 ] && \
    ok "All critical runtime files match deploy manifest"
else
  finding "WARN" "No deploy manifest found — cannot verify integrity" \
    "Run deploy.sh to generate"
fi
echo ""

# ── Secrets in readable files ────────────────────────────────────────────────

echo "Secret Exposure"
# Check for secrets in group-readable files (skip .env which should be 600)
secret_patterns='(sk-[a-zA-Z0-9]{20,}|xoxb-|xapp-|ghp_[a-zA-Z0-9]{36}|AKIA[A-Z0-9]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)'
leaked_files=$(find "$BAUDBOT_HOME" -maxdepth 3 \
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
  -not -name '*.test.sh' \
  -not -name '*.test.mjs' \
  -type f -perm /044 \
  -exec grep -l -E "$secret_patterns" {} \; 2>/dev/null | head -5 || true)

if [ -n "$leaked_files" ]; then
  finding "CRITICAL" "Possible secrets in group/world-readable files:" ""
  echo "$leaked_files" | while read -r f; do echo "              $f"; done
else
  ok "No secrets found in readable files"
fi

# Check git config for tokens
if [ -f "$BAUDBOT_HOME/.gitconfig" ]; then
  if grep -qiE '(token|password|secret)' "$BAUDBOT_HOME/.gitconfig" 2>/dev/null; then
    finding "WARN" "Possible credentials in .gitconfig" "$BAUDBOT_HOME/.gitconfig"
  else
    ok "No credentials in .gitconfig"
  fi
fi

# Check for stale .env copies outside .config
stale_envs=$(find "$BAUDBOT_HOME" -maxdepth 3 \
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

# Check git history for committed secrets (admin-only — needs source access)
if [ -d "$BAUDBOT_SRC/.git" ] && [ -r "$BAUDBOT_SRC/.git/HEAD" ]; then
  git_secrets=$(cd "$BAUDBOT_SRC" && git log --all -p --diff-filter=A 2>/dev/null \
    | grep -cE '(sk-[a-zA-Z0-9]{20,}|xoxb-[0-9]|xapp-[0-9]|ghp_[a-zA-Z0-9]{36}|AKIA[A-Z0-9]{16})' 2>/dev/null || true)
  git_secrets="${git_secrets:-0}"
  if [ "$git_secrets" -gt 0 ]; then
    finding "CRITICAL" "$git_secrets potential secret(s) found in git history" \
      "Run: git log --all -p | grep -nE 'sk-|xoxb-|xapp-|ghp_|AKIA'"
  else
    ok "No secrets detected in git history"
  fi
else
  finding "INFO" "Source repo not accessible — skipping git history scan (admin-only check)" ""
fi

# Check .gitignore excludes .env (admin-only — needs source access)
if [ -f "$BAUDBOT_SRC/.gitignore" ] && [ -r "$BAUDBOT_SRC/.gitignore" ]; then
  if grep -q '\.env' "$BAUDBOT_SRC/.gitignore" 2>/dev/null; then
    ok ".gitignore excludes .env files"
  else
    finding "WARN" ".gitignore does not exclude .env files" \
      "Add '*.env' or '.env' to $BAUDBOT_SRC/.gitignore"
  fi
fi

# Scan session logs for accidentally logged secrets
if [ -d "$BAUDBOT_HOME/.pi/agent/sessions" ]; then
  log_secrets=$(find "$BAUDBOT_HOME/.pi/agent/sessions" -name '*.jsonl' \
    -exec grep -lE '(sk-[a-zA-Z0-9]{20,}|xoxb-[0-9]{10,}|xapp-[0-9]{10,})' {} \; 2>/dev/null | wc -l || true)
  log_secrets="${log_secrets:-0}"
  if [ "$log_secrets" -gt 0 ]; then
    REDACT_SCRIPT="${BAUDBOT_SRC}/bin/redact-logs.sh"
    if [ "$FIX" -eq 1 ] && [ -x "$REDACT_SCRIPT" ]; then
      echo "  🔧 Running log redaction..."
      "$REDACT_SCRIPT" 2>/dev/null && {
        echo "  🔧 FIXED:    Redacted secrets from session logs"
        fixed=$((fixed + 1))
      } || {
        echo "  ❌ FIX-ERR:  Log redaction failed"
        fix_errors=$((fix_errors + 1))
      }
    else
      finding "CRITICAL" "$log_secrets session log(s) contain possible API keys/tokens" \
        "Review and redact: find ~/.pi/agent/sessions -name '*.jsonl' -exec grep -l 'sk-\|xoxb-\|xapp-' {} +"
    fi
  else
    ok "No secrets detected in session logs"
  fi
fi
echo ""

# ── Process Isolation ─────────────────────────────────────────────────────────

echo "Process Isolation"
proc_mount=$(grep '^proc /proc' /proc/mounts 2>/dev/null || true)
if echo "$proc_mount" | grep -q 'hidepid=2'; then
  ok "/proc mounted with hidepid=2 (baudbot_agent can only see own processes)"
else
  finding "WARN" "/proc not mounted with hidepid=2" \
    "baudbot_agent can see all system processes — run setup.sh or: sudo mount -o remount,hidepid=2,gid=<procview_gid> /proc"
  fix_skip "Remount /proc with hidepid=2" "Requires root"
fi
echo ""

# ── Network ──────────────────────────────────────────────────────────────────

echo "Network"

# Check if bridge is bound to localhost only
bridge_bind=$(ss -tlnp 2>/dev/null | grep ':7890' | awk '{print $4}' | head -1 || true)
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
  if iptables -L BAUDBOT_OUTPUT -n 2>/dev/null | grep -q 'DROP'; then
    ok "Firewall rules active (BAUDBOT_OUTPUT chain)"

    # Check localhost isolation (blanket -o lo ACCEPT = bad)
    if iptables -L BAUDBOT_OUTPUT -n 2>/dev/null | grep -qE 'ACCEPT.*lo\s+0\.0\.0\.0/0\s+0\.0\.0\.0/0\s*$'; then
      finding "WARN" "Firewall allows ALL localhost traffic" \
        "Agent can reach every local service (Steam, CUPS, Tailscale, etc.). Update setup-firewall.sh"
    else
      ok "Localhost traffic restricted to specific ports"
    fi
  else
    finding "WARN" "No firewall rules for baudbot_agent" \
      "Run: sudo ~/baudbot/bin/setup-firewall.sh"
    fix_skip "Install firewall rules" "Requires root: sudo ~/baudbot/bin/setup-firewall.sh"
  fi
fi

# Check for firewall persistence
if [ -f /etc/systemd/system/baudbot-firewall.service ]; then
  ok "Firewall persistence configured (systemd)"
elif [ -f /etc/iptables/rules.v4 ] && grep -q 'BAUDBOT_OUTPUT' /etc/iptables/rules.v4 2>/dev/null; then
  ok "Firewall persistence configured (iptables-save)"
else
  finding "WARN" "Firewall rules are NOT persistent across reboots" \
    "Install: sudo cp ~/baudbot/bin/baudbot-firewall.service /etc/systemd/system/ && sudo systemctl enable baudbot-firewall"
fi
echo ""

# Check for network logging rules
if command -v iptables &>/dev/null; then
  if iptables -L BAUDBOT_OUTPUT -n 2>/dev/null | grep -qE "LOG.*baudbot-(out|dns):"; then
    ok "Network logging active (SYN + DNS)"
  else
    finding "WARN" "No network logging in firewall rules" \
      "Run: sudo ~/baudbot/bin/setup-firewall.sh to add LOG rules"
  fi
fi
echo ""

# ── Audit Log ────────────────────────────────────────────────────────────────

echo "Audit Log"

AUDIT_LOG_PRIMARY="/var/log/baudbot/commands.log"
AUDIT_LOG_FALLBACK="$BAUDBOT_HOME/logs/commands.log"

if [ -f "$AUDIT_LOG_PRIMARY" ]; then
  ok "Audit log exists ($AUDIT_LOG_PRIMARY)"
  # Check append-only attribute
  if command -v lsattr &>/dev/null; then
    log_attrs=$(lsattr "$AUDIT_LOG_PRIMARY" 2>/dev/null | awk '{print $1}' || true)
    if echo "$log_attrs" | grep -q 'a'; then
      ok "Audit log has append-only attribute (tamper-proof)"
    else
      finding "WARN" "Audit log missing append-only attribute" \
        "Run: sudo chattr +a $AUDIT_LOG_PRIMARY"
      fix_skip "Set append-only attribute" "Requires root: sudo chattr +a $AUDIT_LOG_PRIMARY"
    fi
  fi
  # Check permissions
  log_perms=$(stat -c '%a' "$AUDIT_LOG_PRIMARY" 2>/dev/null || echo "???")
  if [ $((0$log_perms & 004)) -eq 0 ]; then
    ok "Audit log is not world-readable ($log_perms)"
  else
    finding "WARN" "Audit log is world-readable ($log_perms)" \
      "Run: sudo chmod 660 $AUDIT_LOG_PRIMARY"
  fi
elif [ -f "$AUDIT_LOG_FALLBACK" ]; then
  finding "WARN" "Audit log using fallback location ($AUDIT_LOG_FALLBACK)" \
    "For tamper-proof logging, set up /var/log/baudbot/ as root with chattr +a"
else
  finding "WARN" "No audit log file found" \
    "Create: mkdir -p $BAUDBOT_HOME/logs && touch $BAUDBOT_HOME/logs/commands.log"
  if [ "$FIX" -eq 1 ]; then
    if mkdir -p "$BAUDBOT_HOME/logs" && touch "$BAUDBOT_HOME/logs/commands.log" && chmod 600 "$BAUDBOT_HOME/logs/commands.log" 2>/dev/null; then
      echo "  🔧 FIXED:    Created fallback audit log at $AUDIT_LOG_FALLBACK"
      fixed=$((fixed + 1))
    else
      echo "  ❌ FIX-ERR:  Could not create audit log"
      fix_errors=$((fix_errors + 1))
    fi
  fi
fi
echo ""

# ── Pre-commit hook ──────────────────────────────────────────────────────────

echo "Pre-commit Hook"

if [ -d "$BAUDBOT_SRC/.git" ] && [ -r "$BAUDBOT_SRC/.git/hooks" ]; then
  hook_path="$BAUDBOT_SRC/.git/hooks/pre-commit"
  if [ -f "$hook_path" ]; then
    ok "Pre-commit hook installed"
    hook_owner=$(stat -c '%U' "$hook_path" 2>/dev/null || echo "unknown")
    if [ "$hook_owner" = "root" ]; then
      ok "Pre-commit hook is root-owned (tamper-proof)"
    else
      finding "WARN" "Pre-commit hook owned by $hook_owner (should be root)" \
        "Run: sudo chown root:root $hook_path"
      fix_skip "Fix hook ownership" "Requires root: sudo chown root:root $hook_path"
    fi
  else
    finding "WARN" "Pre-commit hook not installed" \
      "Run: sudo cp ~/baudbot/hooks/pre-commit $hook_path && sudo chown root:root $hook_path"
    fix_skip "Install pre-commit hook" "Requires root"
  fi
else
  finding "INFO" "Source repo not accessible — skipping pre-commit hook check (admin-only)" ""
fi
echo ""

# ── Services ─────────────────────────────────────────────────────────────────

echo "Services"
if ss -tlnp 2>/dev/null | grep -q ':11434'; then
  bind_addr=$(ss -tlnp 2>/dev/null | grep ':11434' | awk '{print $4}' | head -1 || true)
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
if [ -f /usr/local/bin/baudbot-safe-bash ]; then
  if [ ! -w /usr/local/bin/baudbot-safe-bash ]; then
    ok "Safe bash wrapper installed (not agent-writable)"
  else
    finding "WARN" "baudbot-safe-bash is writable by current user" \
      "Should be root-owned: sudo chown root:root /usr/local/bin/baudbot-safe-bash"
  fi
else
  finding "INFO" "Safe bash wrapper not installed" \
    "Optional defense-in-depth: install /usr/local/bin/baudbot-safe-bash"
fi
echo ""

# ── Extension / Skill Vetting ────────────────────────────────────────────────

echo "Extension & Skill Safety"

# Check pi extensions for suspicious patterns (deployed copies only)
AGENT_USER="$BAUDBOT_AGENT_USER"
suspicious_extension_patterns="(eval\s*\(|new\s+Function\s*\(|child_process|execSync|execFile|spawn\s*\(|writeFileSync.*\/etc|writeFileSync.*\/home\/(?!${AGENT_USER}))"
ext_dirs=(
  "$BAUDBOT_AGENT_EXT_DIR"
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

# Check skills for dangerous tool instructions (deployed copies only)
skill_dirs=(
  "$BAUDBOT_AGENT_SKILLS_DIR"
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

# Deep scan: cross-pattern analysis via Node scanner (deployed copies)
if [ "$DEEP" -eq 1 ]; then
  NODE_BIN="$BAUDBOT_HOME/opt/node-v22.14.0-linux-x64/bin/node"
  # Try source scanner first, fall back to deployed copy
  SCANNER=""
  [ -f "$BAUDBOT_SRC/bin/scan-extensions.mjs" ] && [ -r "$BAUDBOT_SRC/bin/scan-extensions.mjs" ] && SCANNER="$BAUDBOT_SRC/bin/scan-extensions.mjs"
  [ -z "$SCANNER" ] && [ -f "$BAUDBOT_HOME/.pi/agent/extensions/scan-extensions.mjs" ] && SCANNER="$BAUDBOT_HOME/.pi/agent/extensions/scan-extensions.mjs"
  if [ -x "$NODE_BIN" ] && [ -n "$SCANNER" ]; then
    echo ""
    echo "Deep Extension Scan (cross-pattern analysis)"
    deep_output=$("$NODE_BIN" "$SCANNER" \
      "$BAUDBOT_HOME/.pi/agent/extensions" \
      "$BAUDBOT_HOME/.pi/agent/skills" 2>&1 || true)
    deep_critical=$(echo "$deep_output" | grep -c '❌ CRITICAL' || true)
    deep_warn=$(echo "$deep_output" | grep -c '⚠️' || true)
    if [ "$deep_critical" -gt 0 ]; then
      finding "WARN" "$deep_critical cross-pattern critical finding(s) in deep scan" \
        "Run: node ~/baudbot/bin/scan-extensions.mjs for details"
    elif [ "$deep_warn" -gt 0 ]; then
      finding "INFO" "$deep_warn cross-pattern warning(s) in deep scan" \
        "Run: node ~/baudbot/bin/scan-extensions.mjs for details"
    else
      ok "Deep extension scan clean"
    fi
  else
    finding "INFO" "Deep scanner not available (Node or scanner not found)" ""
  fi
fi

# Check that bridge security.mjs exists and is tested
if [ -f "$BRIDGE_DIR/security.mjs" ]; then
  ok "Bridge security module exists (release)"
  if [ -f "$BRIDGE_DIR/security.test.mjs" ]; then
    ok "Bridge security tests exist (release)"
  else
    finding "WARN" "No tests for bridge security module in release" \
      "Run: sudo baudbot update"
  fi
else
  finding "WARN" "Bridge security module not found" \
    "Expected in $BRIDGE_DIR/security.mjs — run: sudo baudbot update"
fi
echo ""

# ── Bridge Config ────────────────────────────────────────────────────────────

echo "Bridge Configuration"

# Check SLACK_ALLOWED_USERS mode (without reading the actual value)
if [ -f "$BAUDBOT_HOME/.config/.env" ]; then
  if grep -q '^SLACK_ALLOWED_USERS=' "$BAUDBOT_HOME/.config/.env" 2>/dev/null; then
    allowed_count=$(grep '^SLACK_ALLOWED_USERS=' "$BAUDBOT_HOME/.config/.env" 2>/dev/null | cut -d= -f2 | tr ',' '\n' | grep -c . || echo 0)
    if [ "$allowed_count" -gt 0 ]; then
      ok "SLACK_ALLOWED_USERS configured ($allowed_count user(s))"
    else
      finding "WARN" "SLACK_ALLOWED_USERS is empty" \
        "Bridge will allow all workspace members"
    fi
  else
    finding "WARN" "SLACK_ALLOWED_USERS not set in .env" \
      "Bridge will allow all workspace members"
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

if [ "$FIX" -eq 1 ]; then
  echo ""
  echo "  🔧 Fixed:    $fixed"
  echo "  ⏭️  Skipped:  $skipped"
  echo "  ❌ Errors:   $fix_errors"
fi
echo ""

if [ "$FIX" -eq 1 ] && [ "$fixed" -gt 0 ]; then
  echo "🔧 $fixed fix(es) applied."
  [ "$skipped" -gt 0 ] && echo "⏭️  $skipped fix(es) skipped (require root or manual intervention)."
  [ "$fix_errors" -gt 0 ] && echo "❌ $fix_errors fix(es) failed."
  echo ""
fi

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
