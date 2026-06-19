#!/bin/bash
# Baudbot Agent Launcher
# Run as: sudo -u baudbot_agent ~/runtime/start.sh
#
# The agent runs entirely from deployed copies — no source repo access needed:
#   ~/.pi/agent/extensions/          ← pi extensions
#   ~/.pi/agent/skills/              ← operational skills
#   /opt/baudbot/current/gateway-bridge/ ← bridge process (legacy shim: /opt/baudbot/current/slack-bridge/)
#   ~/runtime/bin/                   ← utility scripts
#
# To update, admin edits source and runs deploy.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/runtime-node.sh
source "$SCRIPT_DIR/bin/lib/runtime-node.sh"
cd ~

NODE_BIN_DIR="$(bb_resolve_runtime_node_bin_dir "$HOME")"

# Set PATH (varlock may be installed in ~/.varlock/bin or ~/.config/varlock/bin)
export PATH="$HOME/.varlock/bin:$HOME/.config/varlock/bin:$NODE_BIN_DIR:$PATH"

# Opt out of varlock telemetry at runtime (belt-and-suspenders: setup also
# persists this via `varlock telemetry disable`). Inherited by child processes.
export VARLOCK_TELEMETRY_DISABLED=1

# Validate secrets via varlock (fail fast before hardening/cleanup).
#
# We intentionally do NOT `source ~/.config/.env` into this shell. The launch
# chain is rooted at `varlock run` (see the exec at the end of this script):
# varlock 1.7.x injects a resolution marker (__VARLOCK_RUN / __VARLOCK_ENV) into
# pi and every descendant `varlock run` (gateway bridge, dev/sentry subagents).
# With the marker present, descendants re-resolve config from ~/.config/.env on
# each restart instead of honoring stale values inherited from the long-lived
# control-agent process. Sourcing .env into this shell would re-introduce
# exactly those stale overrides, so this shell stays secret-free and varlock run
# owns resolution end-to-end.
varlock load --path ~/.config/ >/dev/null || {
  echo "❌ Environment validation failed — check ~/.config/.env against .env.schema"
  exit 1
}

# Harden file permissions (pi defaults are too permissive)
umask 077
~/runtime/bin/harden-permissions.sh

# Prune old session logs to limit transcript retention window
~/runtime/bin/prune-session-logs.sh --days 14 2>/dev/null || true

# Redact any secrets that leaked into retained session logs
~/runtime/bin/redact-logs.sh 2>/dev/null || true

# Verify deployed runtime integrity against deploy manifest.
# Resolve the integrity mode through varlock since we no longer source .env into
# this shell (the value may be configured in ~/.config/.env). Falls back to the
# schema default of "warn" if varlock can't resolve it.
INTEGRITY_MODE="$(varlock run --path ~/.config/ -- sh -c 'printf "%s" "${BAUDBOT_STARTUP_INTEGRITY_MODE:-warn}"' 2>/dev/null || true)"
INTEGRITY_MODE="${INTEGRITY_MODE:-warn}"
if [ -x "$HOME/runtime/bin/verify-manifest.sh" ]; then
  if ! BAUDBOT_STARTUP_INTEGRITY_MODE="$INTEGRITY_MODE" "$HOME/runtime/bin/verify-manifest.sh"; then
    echo "❌ Startup integrity verification failed (mode: $INTEGRITY_MODE). Refusing to start."
    exit 1
  fi
else
  echo "⚠️  Startup integrity verifier missing at ~/runtime/bin/verify-manifest.sh"
fi

# Clean stale session sockets from previous runs
SOCKET_DIR="$HOME/.pi/session-control"
if [ -d "$SOCKET_DIR" ]; then
  echo "Cleaning stale session sockets..."
  if command -v fuser &>/dev/null; then
    for sock in "$SOCKET_DIR"/*.sock; do
      [ -e "$sock" ] || continue
      if ! fuser "$sock" &>/dev/null 2>&1; then
        rm -f "$sock"
      fi
    done
  else
    echo "  fuser not found, skipping socket cleanup (install psmisc)"
  fi
  for alias in "$SOCKET_DIR"/*.alias; do
    [ -L "$alias" ] || continue
    target=$(readlink "$alias")
    if [ ! -e "$SOCKET_DIR/$target" ] && [ ! -e "$target" ]; then
      rm -f "$alias"
    fi
  done
fi

# ── Process Group Management ──
# Kill old control-agent process group to ensure clean slate.
# This automatically terminates all spawned services (bridge, workers, etc.)
# without needing to track individual PIDs or process names.
CONTROL_PGID_FILE="$HOME/.pi/agent/control-agent.pgid"

if [ -f "$CONTROL_PGID_FILE" ]; then
  OLD_PGID=$(cat "$CONTROL_PGID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PGID" ] && kill -0 -"$OLD_PGID" 2>/dev/null; then
    echo "Terminating old control-agent process group (PGID $OLD_PGID)..."
    kill -TERM -"$OLD_PGID" 2>/dev/null || true
    # Wait up to 5s for graceful shutdown
    for _i in 1 2 3 4 5; do
      if ! kill -0 -"$OLD_PGID" 2>/dev/null; then
        echo "  Process group terminated cleanly"
        break
      fi
      sleep 1
    done
    # Force-kill any survivors
    if kill -0 -"$OLD_PGID" 2>/dev/null; then
      echo "  Force-killing stubborn processes in group $OLD_PGID..."
      kill -KILL -"$OLD_PGID" 2>/dev/null || true
      sleep 1
    fi
  fi
  rm -f "$CONTROL_PGID_FILE"
fi

# Set session name (read by auto-name.ts extension)
export PI_SESSION_NAME="control-agent"

# Start control-agent under `varlock run` so pi and its entire subtree inherit
# varlock-resolved config plus the resolution marker (see the note near the top
# of this script). Model auto-detection reads API keys / auth.json, which only
# exist inside the varlock context now that we no longer source .env — so the
# detection runs in the same `bash -c` that ultimately exec's pi.
#
# Process-group semantics are preserved: when systemd launches start.sh
# (Type=simple) our PID ($$) is the process-group leader. `exec varlock run`
# replaces start.sh in place (same PID, same PGID); varlock runs the inner bash
# in that same group, and `exec pi` replaces the inner bash. So pi and every
# child (bridge, workers) stay in PGID $$, and on the next restart killing
# -$PGID terminates the entire tree automatically. We record $$ before exec'ing.
#
# Inside the bash -c body (single-quoted so the inner shell expands the
# varlock-provided secrets), jq filters use double quotes to avoid nested
# single-quote escaping.
#
# --session-control: enables inter-session communication (handled by control.ts extension)
echo "Starting control-agent..."
echo $$ > "$CONTROL_PGID_FILE"
exec varlock run --path ~/.config/ -- bash -c '
  set -euo pipefail

  # Pick model: explicit override or auto-detect from API keys (first match wins)
  if [ -n "${BAUDBOT_MODEL:-}" ]; then
    MODEL="$BAUDBOT_MODEL"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    MODEL="anthropic/claude-opus-4-6"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    MODEL="openai/gpt-5.2-codex"
  elif [ -n "${GEMINI_API_KEY:-}" ]; then
    MODEL="google/gemini-3-pro-preview"
  elif [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
    MODEL="opencode-zen/claude-opus-4-6"
  elif [ -f "$HOME/.pi/agent/auth.json" ] && command -v jq >/dev/null 2>&1; then
    # OAuth subscription fallback: check auth.json for credentials saved via
    # `baudbot login` or `pi /login`
    if jq -e ".\"openai-codex\"" "$HOME/.pi/agent/auth.json" >/dev/null 2>&1; then
      MODEL="openai-codex/gpt-5.2-codex"
    elif jq -e ".anthropic" "$HOME/.pi/agent/auth.json" >/dev/null 2>&1; then
      MODEL="anthropic/claude-opus-4-6"
    elif jq -e ".google" "$HOME/.pi/agent/auth.json" >/dev/null 2>&1; then
      MODEL="google/gemini-3-pro-preview"
    elif jq -e ".\"github-copilot\"" "$HOME/.pi/agent/auth.json" >/dev/null 2>&1; then
      MODEL="github-copilot/claude-sonnet-4"
    else
      echo "❌ No LLM credentials found in env vars or auth.json"
      exit 1
    fi
  else
    echo "❌ No LLM API key found — set ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, or OPENCODE_ZEN_API_KEY"
    echo "   Or use subscription login: sudo baudbot login"
    exit 1
  fi

  exec pi --session-control --model "$MODEL" --skill "$HOME/.pi/agent/skills/control-agent" "/skill:control-agent"
'
