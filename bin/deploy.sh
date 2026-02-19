#!/bin/bash
# Deploy extensions and bridge from baudbot source to agent runtime.
#
# Run as admin:
#   ~/baudbot/bin/deploy.sh
#   ~/baudbot/bin/deploy.sh --dry-run
#
# The source repo lives in the admin's home (agent can't read it).
# This script stages files to a temp dir, then uses sudo -u baudbot_agent
# to install them into the agent's runtime directories. It also stamps
# a version file + hash manifest so the agent can verify integrity
# without needing access to the source.
#
# Protected security files are made read-only (chmod a-w) after copy.

# Auto-detect source repo from this script's location
BAUDBOT_SRC="${BAUDBOT_SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
BAUDBOT_HOME="${BAUDBOT_HOME:-/home/baudbot_agent}"
AGENT_USER="baudbot_agent"
DRY_RUN=0

# Helper: run a command as baudbot_agent
as_agent() {
  sudo -u "$AGENT_USER" "$@"
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

log() { echo "  $1"; }

# Security-critical files — deployed read-only (chmod a-w)
PROTECTED_EXTENSIONS=(tool-guard.ts tool-guard.test.mjs)
PROTECTED_BRIDGE_FILES=(security.mjs security.test.mjs)

# ── Stage source to temp dir (readable by agent) ────────────────────────────

STAGE_DIR=$(mktemp -d /tmp/baudbot-deploy.XXXXXX)
chmod 755 "$STAGE_DIR"
trap 'rm -rf "$STAGE_DIR"' EXIT

if [ "$DRY_RUN" -eq 0 ]; then
  cp -r --no-preserve=ownership "$BAUDBOT_SRC/pi/extensions" "$STAGE_DIR/extensions"
  cp -r --no-preserve=ownership "$BAUDBOT_SRC/pi/skills" "$STAGE_DIR/skills"
  cp -r --no-preserve=ownership "$BAUDBOT_SRC/slack-bridge" "$STAGE_DIR/slack-bridge"
  cp --no-preserve=ownership "$BAUDBOT_SRC/start.sh" "$STAGE_DIR/start.sh"
  mkdir -p "$STAGE_DIR/bin"
  for script in harden-permissions.sh redact-logs.sh prune-session-logs.sh; do
    [ -f "$BAUDBOT_SRC/bin/$script" ] && cp --no-preserve=ownership "$BAUDBOT_SRC/bin/$script" "$STAGE_DIR/bin/$script"
  done
  [ -f "$BAUDBOT_SRC/pi/settings.json" ] && cp --no-preserve=ownership "$BAUDBOT_SRC/pi/settings.json" "$STAGE_DIR/settings.json"
  [ -f "$BAUDBOT_SRC/.env.schema" ] && cp --no-preserve=ownership "$BAUDBOT_SRC/.env.schema" "$STAGE_DIR/.env.schema"
  chmod -R a+rX "$STAGE_DIR"
fi

# ── Unlock all existing deployed files ────────────────────────────────────────
# Previous deploys may have left files/dirs read-only. Unlock before overwrite.
# Runs before set -e so partial failures don't abort the script.
# Uses chmod -R to handle dirs that lost execute bits.

if [ "$DRY_RUN" -eq 0 ]; then
  as_agent chmod -R u+rwX "$BAUDBOT_HOME/.pi/agent/extensions" 2>/dev/null || true
  as_agent chmod -R u+rwX "$BAUDBOT_HOME/.pi/agent/skills" 2>/dev/null || true
  as_agent chmod -R u+rwX "$BAUDBOT_HOME/runtime" 2>/dev/null || true
  as_agent chmod u+w "$BAUDBOT_HOME/.pi/agent/settings.json" 2>/dev/null || true
  as_agent chmod u+w "$BAUDBOT_HOME/.pi/agent/baudbot-version.json" 2>/dev/null || true
  as_agent chmod u+w "$BAUDBOT_HOME/.pi/agent/baudbot-manifest.json" 2>/dev/null || true
fi

set -euo pipefail

# ── Extensions ───────────────────────────────────────────────────────────────

echo "Deploying extensions..."

EXT_SRC="$STAGE_DIR/extensions"
EXT_DEST="$BAUDBOT_HOME/.pi/agent/extensions"

[ "$DRY_RUN" -eq 0 ] && as_agent mkdir -p "$EXT_DEST"

for ext in "$EXT_SRC"/*; do
  base=$(basename "$ext")
  [ "$base" = "node_modules" ] && continue

  if [ -d "$ext" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      # Make destination writable first (source files may have been a-w)
      as_agent bash -c "
        mkdir -p '$EXT_DEST/$base'
        cp -r '$ext/.' '$EXT_DEST/$base/'
      "
      log "✓ $base/"
    else
      log "would copy: $base/"
    fi
    continue
  fi

  # Check if protected
  is_protected=0
  for pf in "${PROTECTED_EXTENSIONS[@]}"; do
    [ "$base" = "$pf" ] && is_protected=1 && break
  done

  if [ "$DRY_RUN" -eq 0 ]; then
    as_agent bash -c "
      [ -f '$EXT_DEST/$base' ] && chmod u+w '$EXT_DEST/$base' 2>/dev/null || true
      cp '$ext' '$EXT_DEST/$base'
    "
    if [ "$is_protected" -eq 1 ]; then
      as_agent chmod a-w "$EXT_DEST/$base"
      log "✓ $base (read-only)"
    else
      as_agent chmod u+w "$EXT_DEST/$base"
      log "✓ $base"
    fi
  else
    if [ "$is_protected" -eq 1 ]; then
      log "would copy: $base (read-only)"
    else
      log "would copy: $base"
    fi
  fi
done

# ── Skills ───────────────────────────────────────────────────────────────────

echo "Deploying skills..."

SKILLS_SRC="$STAGE_DIR/skills"
SKILLS_DEST="$BAUDBOT_HOME/.pi/agent/skills"

if [ "$DRY_RUN" -eq 0 ]; then
  as_agent bash -c "mkdir -p '$SKILLS_DEST' && cp -r '$SKILLS_SRC/.' '$SKILLS_DEST/'"
  log "✓ skills/"
else
  log "would copy: skills/"
fi

# ── Heartbeat ────────────────────────────────────────────────────────────────

echo "Deploying heartbeat checklist..."

HEARTBEAT_SRC="$STAGE_DIR/skills/control-agent/HEARTBEAT.md"
HEARTBEAT_DEST="$BAUDBOT_HOME/.pi/agent/HEARTBEAT.md"

if [ "$DRY_RUN" -eq 0 ]; then
  # HEARTBEAT.md — always overwrite (admin-managed checklist)
  if [ -f "$HEARTBEAT_SRC" ]; then
    as_agent cp "$HEARTBEAT_SRC" "$HEARTBEAT_DEST"
    as_agent chmod 644 "$HEARTBEAT_DEST"
    log "✓ HEARTBEAT.md"
  fi
else
  log "would copy: HEARTBEAT.md"
fi

# ── Memory Seeds ─────────────────────────────────────────────────────────────

echo "Deploying memory seeds..."

MEMORY_SEED_DIR="$STAGE_DIR/skills/control-agent/memory"
MEMORY_DEST="$BAUDBOT_HOME/.pi/agent/memory"

if [ "$DRY_RUN" -eq 0 ]; then
  # Memory seeds — only copy if files don't already exist (agent-owned, don't clobber)
  as_agent mkdir -p "$MEMORY_DEST"
  if [ -d "$MEMORY_SEED_DIR" ]; then
    for seed in "$MEMORY_SEED_DIR"/*.md; do
      [ -f "$seed" ] || continue
      base=$(basename "$seed")
      as_agent bash -c "[ -f '$MEMORY_DEST/$base' ] || cp '$seed' '$MEMORY_DEST/$base'"
      log "✓ memory/$base (seed, won't overwrite)"
    done
  fi
else
  log "would seed: memory/*.md (only if missing)"
fi

# ── Slack Bridge ─────────────────────────────────────────────────────────────

echo "Deploying slack-bridge..."

BRIDGE_SRC="$STAGE_DIR/slack-bridge"
BRIDGE_DEST="$BAUDBOT_HOME/runtime/slack-bridge"

if [ "$DRY_RUN" -eq 0 ]; then
  as_agent bash -c "
    mkdir -p '$BRIDGE_DEST'
    # Unlock protected files before bulk copy
    for pf in ${PROTECTED_BRIDGE_FILES[*]}; do
      [ -f '$BRIDGE_DEST/\$pf' ] && chmod u+w '$BRIDGE_DEST/\$pf' 2>/dev/null || true
    done
    cp -r '$BRIDGE_SRC/.' '$BRIDGE_DEST/'
  "

  # Lock protected files read-only
  for pf in "${PROTECTED_BRIDGE_FILES[@]}"; do
    if as_agent test -f "$BRIDGE_DEST/$pf"; then
      as_agent chmod a-w "$BRIDGE_DEST/$pf"
      log "✓ $pf (read-only)"
    fi
  done

  # Agent-modifiable files stay writable
  if as_agent test -f "$BRIDGE_DEST/bridge.mjs"; then
    as_agent chmod u+w "$BRIDGE_DEST/bridge.mjs"
    log "✓ bridge.mjs"
  fi

  log "✓ node_modules/ + package files"
else
  log "would copy: slack-bridge/"
fi

# ── Runtime bin (utility scripts + start.sh) ─────────────────────────────────

echo "Deploying runtime scripts..."

if [ "$DRY_RUN" -eq 0 ]; then
  as_agent mkdir -p "$BAUDBOT_HOME/runtime/bin"

  for script in harden-permissions.sh redact-logs.sh prune-session-logs.sh; do
    if [ -f "$STAGE_DIR/bin/$script" ]; then
      as_agent cp "$STAGE_DIR/bin/$script" "$BAUDBOT_HOME/runtime/bin/$script"
      as_agent chmod u+x "$BAUDBOT_HOME/runtime/bin/$script"
      log "✓ bin/$script"
    fi
  done

  as_agent cp "$STAGE_DIR/start.sh" "$BAUDBOT_HOME/runtime/start.sh"
  as_agent chmod u+x "$BAUDBOT_HOME/runtime/start.sh"
  log "✓ start.sh"
else
  log "would copy: runtime scripts"
fi

# ── Settings ─────────────────────────────────────────────────────────────────

echo "Deploying settings..."

if [ -f "$STAGE_DIR/settings.json" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    as_agent bash -c "cp '$STAGE_DIR/settings.json' '$BAUDBOT_HOME/.pi/agent/settings.json' && chmod 600 '$BAUDBOT_HOME/.pi/agent/settings.json'"
    log "✓ settings.json"
  else
    log "would copy: settings.json"
  fi
fi

# ── Env schema ───────────────────────────────────────────────────────────────

echo "Deploying env schema..."

if [ -f "$STAGE_DIR/.env.schema" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    as_agent cp "$STAGE_DIR/.env.schema" "$BAUDBOT_HOME/.config/.env.schema"
    as_agent chmod 644 "$BAUDBOT_HOME/.config/.env.schema"
    log "✓ .env.schema → ~/.config/.env.schema"
  else
    log "would copy: .env.schema → ~/.config/.env.schema"
  fi
fi

# ── Admin config (secrets) ────────────────────────────────────────────────────

echo "Deploying config..."

# Determine who invoked this (the admin user)
# Priority: BAUDBOT_CONFIG_USER env > SUDO_USER > repo owner > whoami
if [ -n "${BAUDBOT_CONFIG_USER:-}" ]; then
  DEPLOY_USER="$BAUDBOT_CONFIG_USER"
elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
  DEPLOY_USER="$SUDO_USER"
else
  # Detect from repo ownership (the admin owns the source)
  DEPLOY_USER=$(stat -c '%U' "$BAUDBOT_SRC" 2>/dev/null || echo "")
  if [ -z "$DEPLOY_USER" ] || [ "$DEPLOY_USER" = "root" ]; then
    DEPLOY_USER="$(whoami)"
  fi
fi
DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6 2>/dev/null || echo "")
ADMIN_CONFIG="$DEPLOY_HOME/.baudbot/.env"

if [ -f "$ADMIN_CONFIG" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    as_agent bash -c "mkdir -p '$BAUDBOT_HOME/.config'"
    # Stream directly to agent-owned target to avoid staging secrets in /tmp.
    as_agent bash -c "cat > '$BAUDBOT_HOME/.config/.env'" < "$ADMIN_CONFIG"
    as_agent chmod 600 "$BAUDBOT_HOME/.config/.env"
    log "✓ .env → ~/.config/.env (600)"
  else
    log "would copy: $ADMIN_CONFIG → ~/.config/.env"
  fi
else
  # Fallback: check if agent already has a .env (written directly by old install.sh)
  if as_agent test -f "$BAUDBOT_HOME/.config/.env" 2>/dev/null; then
    log "- .env: using existing agent config (no ~/.baudbot/.env found)"
  else
    log "⚠ no config found — run: baudbot config"
  fi
fi

# ── Version stamp + integrity manifest ────────────────────────────────────────

echo "Stamping version..."

VERSION_DIR="$BAUDBOT_HOME/.pi/agent"
VERSION_FILE="$VERSION_DIR/baudbot-version.json"
MANIFEST_FILE="$VERSION_DIR/baudbot-manifest.json"

if [ "$DRY_RUN" -eq 0 ]; then
  # Get source metadata from git (dev checkout) or release metadata (git-free /opt release).
  RELEASE_META_FILE="$BAUDBOT_SRC/baudbot-release.json"
  GIT_SHA=""
  GIT_SHA_SHORT=""
  GIT_BRANCH=""

  if (cd "$BAUDBOT_SRC" && git rev-parse HEAD >/dev/null 2>&1); then
    GIT_SHA=$(cd "$BAUDBOT_SRC" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    GIT_SHA_SHORT=$(cd "$BAUDBOT_SRC" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_BRANCH=$(cd "$BAUDBOT_SRC" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  elif [ -f "$RELEASE_META_FILE" ]; then
    GIT_SHA=$(grep '"sha"' "$RELEASE_META_FILE" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    GIT_SHA_SHORT=$(grep '"short"' "$RELEASE_META_FILE" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    GIT_BRANCH=$(grep '"branch"' "$RELEASE_META_FILE" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
  fi

  [ -n "$GIT_SHA" ] || GIT_SHA="unknown"
  [ -n "$GIT_SHA_SHORT" ] || GIT_SHA_SHORT="unknown"
  [ -n "$GIT_BRANCH" ] || GIT_BRANCH="unknown"
  DEPLOY_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Write version file via agent
  as_agent bash -c "cat > '$VERSION_FILE'" <<VEOF
{
  "sha": "$GIT_SHA",
  "short": "$GIT_SHA_SHORT",
  "branch": "$GIT_BRANCH",
  "deployed_at": "$DEPLOY_TS",
  "deployed_by": "$(whoami)"
}
VEOF
  as_agent chmod 644 "$VERSION_FILE"
  log "✓ baudbot-version.json ($GIT_SHA_SHORT @ $GIT_BRANCH)"

  # Generate sha256 manifest of all deployed files (excluding node_modules)
  # Agent reads its own files to compute hashes
  as_agent bash -c "
    cd /tmp
    {
      echo '{'
      echo '  \"generated_at\": \"$DEPLOY_TS\",'
      echo '  \"source_sha\": \"$GIT_SHA\",'
      echo '  \"files\": {'
      first=1
      for dir in '$BAUDBOT_HOME/.pi/agent/extensions' '$BAUDBOT_HOME/.pi/agent/skills' '$BAUDBOT_HOME/runtime/slack-bridge' '$BAUDBOT_HOME/runtime/bin'; do
        if [ -d \"\$dir\" ]; then
          while IFS= read -r f; do
            hash=\$(sha256sum \"\$f\" | cut -d' ' -f1)
            rel=\"\${f#$BAUDBOT_HOME/}\"
            [ \"\$first\" -eq 1 ] && first=0 || echo ','
            printf '    \"%s\": \"%s\"' \"\$rel\" \"\$hash\"
          done < <(find \"\$dir\" -type f -not -path '*/node_modules/*' -not -name '*.log' | sort)
        fi
      done
      echo ''
      echo '  }'
      echo '}'
    } > '$MANIFEST_FILE'
    chmod 644 '$MANIFEST_FILE'
  "
  manifest_count=$(as_agent grep -c '": "' "$MANIFEST_FILE" 2>/dev/null || echo 0)
  log "✓ baudbot-manifest.json ($manifest_count files)"
else
  log "would stamp: baudbot-version.json + baudbot-manifest.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "🔍 Dry run — no changes made."
else
  echo "✅ Deployed $GIT_SHA_SHORT. Protected files are read-only."
  echo ""
  echo "If the bridge is running, restart it:"
  echo "  sudo -u baudbot_agent bash -c 'cd ~/runtime/slack-bridge && node bridge.mjs'"
fi
