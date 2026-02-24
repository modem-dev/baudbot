#!/bin/bash
# Deploy extensions/skills/runtime scripts from baudbot source to agent runtime.
#
# Run as admin:
#   ~/baudbot/bin/deploy.sh
#   ~/baudbot/bin/deploy.sh --dry-run
#
# In default hardened installs, source lives in admin-owned paths not readable by the agent.
# This script stages files to a temp dir, then uses sudo -u baudbot_agent
# to install them into the agent's runtime directories. It also stamps
# a version file + hash manifest so the agent can verify integrity
# without needing access to the source.
#
# Protected security files are made read-only (chmod a-w) after copy.

# Auto-detect source repo from this script's location
BAUDBOT_SRC="${BAUDBOT_SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/lib/json-common.sh"
# shellcheck source=bin/lib/deploy-common.sh
source "$SCRIPT_DIR/lib/deploy-common.sh"
bb_enable_strict_mode
bb_init_paths

AGENT_USER="${AGENT_USER:-$BAUDBOT_AGENT_USER}"

# Helper: run a command as baudbot_agent
as_agent() {
  bb_as_user "$AGENT_USER" "$@"
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

command -v sudo >/dev/null 2>&1 || bb_die "deploy requires sudo in PATH"
[ -d "$BAUDBOT_SRC" ] || bb_die "source repo not found: $BAUDBOT_SRC"

# Determine admin config location (used for secret deploy + feature flags)
DEPLOY_USER="$(bb_resolve_deploy_user "$BAUDBOT_SRC")"
DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6 2>/dev/null || echo "")
ADMIN_CONFIG="$DEPLOY_HOME/.baudbot/.env"
RENDER_ENV_SCRIPT="$BAUDBOT_SRC/bin/render-env.sh"

source_env_value() {
  local key="$1"
  bb_source_env_value "$RENDER_ENV_SCRIPT" "$DEPLOY_HOME" "$DEPLOY_USER" "$ADMIN_CONFIG" "$key"
}

EXPERIMENTAL_MODE="${BAUDBOT_EXPERIMENTAL:-}"
if [ -z "$EXPERIMENTAL_MODE" ]; then
  EXPERIMENTAL_MODE="$(source_env_value BAUDBOT_EXPERIMENTAL)"
fi
case "$EXPERIMENTAL_MODE" in
  1|true|TRUE|yes|YES|on|ON) EXPERIMENTAL_MODE=1 ;;
  *) EXPERIMENTAL_MODE=0 ;;
esac

log() { bb_log "$1"; }

# Security-critical files — deployed read-only (chmod a-w)
PROTECTED_EXTENSIONS=(tool-guard.ts tool-guard.test.mjs)
EXPERIMENTAL_EXTENSIONS=(agentmail email-monitor)

# ── Stage source to temp dir (readable by agent) ────────────────────────────

STAGE_DIR=$(mktemp -d /tmp/baudbot-deploy.XXXXXX)
chmod 755 "$STAGE_DIR"
trap 'rm -rf "$STAGE_DIR"' EXIT

# shellcheck disable=SC2034  # consumed via nameref in bb_manifest_for_each
STAGE_MANIFEST=(
  "dir|pi/extensions|extensions|required|always"
  "dir|pi/skills|skills|required|always"
  "file|start.sh|start.sh|required|always"
  "file|bin/harden-permissions.sh|bin/harden-permissions.sh|optional|always"
  "file|bin/redact-logs.sh|bin/redact-logs.sh|optional|always"
  "file|bin/prune-session-logs.sh|bin/prune-session-logs.sh|optional|always"
  "file|bin/verify-manifest.sh|bin/verify-manifest.sh|optional|always"
  "file|bin/lib/runtime-node.sh|bin/lib/runtime-node.sh|optional|always"
  "file|bin/lib/bridge-restart-policy.sh|bin/lib/bridge-restart-policy.sh|optional|always"
  "file|pi/settings.json|settings.json|optional|always"
  "file|.env.schema|.env.schema|optional|always"
)

stage_manifest_entry() {
  local entry="$1"
  local item_type src_rel stage_rel required gate
  IFS='|' read -r item_type src_rel stage_rel required gate <<<"$entry"

  bb_feature_gate_enabled "$gate" "$EXPERIMENTAL_MODE" || return 0

  local src_path="$BAUDBOT_SRC/$src_rel"
  local stage_path="$STAGE_DIR/$stage_rel"

  if [ ! -e "$src_path" ]; then
    [ "$required" = "required" ] && bb_die "missing required deploy source: $src_rel"
    return 0
  fi

  mkdir -p "$(dirname "$stage_path")"

  if [ "$item_type" = "dir" ]; then
    cp -r --no-preserve=ownership "$src_path" "$stage_path"
  else
    cp --no-preserve=ownership "$src_path" "$stage_path"
  fi
}

if [ "$DRY_RUN" -eq 0 ]; then
  bb_manifest_for_each STAGE_MANIFEST stage_manifest_entry
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

# ── Extensions ───────────────────────────────────────────────────────────────

echo "Deploying extensions..."
log "experimental mode: $EXPERIMENTAL_MODE"

EXT_SRC="$STAGE_DIR/extensions"
EXT_DEST="$BAUDBOT_HOME/.pi/agent/extensions"

[ "$DRY_RUN" -eq 0 ] && as_agent mkdir -p "$EXT_DEST"

if [ "$EXPERIMENTAL_MODE" -ne 1 ]; then
  for disabled in "${EXPERIMENTAL_EXTENSIONS[@]}"; do
    if [ "$DRY_RUN" -eq 0 ]; then
      as_agent rm -rf "$EXT_DEST/$disabled" 2>/dev/null || true
      log "✓ removed $disabled/ (experimental-only)"
    else
      log "would remove: $disabled/ (experimental-only)"
    fi
  done
fi

for ext in "$EXT_SRC"/*; do
  base=$(basename "$ext")
  [ "$base" = "node_modules" ] && continue

  skip_ext=0
  if [ "$EXPERIMENTAL_MODE" -ne 1 ]; then
    for experimental in "${EXPERIMENTAL_EXTENSIONS[@]}"; do
      if [ "$base" = "$experimental" ]; then
        skip_ext=1
        break
      fi
    done
  fi

  if [ "$skip_ext" -eq 1 ]; then
    log "- skipped $base/ (experimental-only)"
    continue
  fi

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

# ── Runtime assets (manifest-driven) ────────────────────────────────────────

echo "Deploying heartbeat checklist..."
echo "Deploying memory seeds..."
echo "Deploying runtime scripts..."
echo "Deploying settings..."
echo "Deploying env schema..."

# shellcheck disable=SC2034  # consumed via nameref in bb_manifest_for_each
RUNTIME_ASSET_MANIFEST=(
  "file|skills/control-agent/HEARTBEAT.md|.pi/agent/HEARTBEAT.md|644|agent|0|always|optional|HEARTBEAT.md"
  "file|bin/harden-permissions.sh|runtime/bin/harden-permissions.sh|u+x|agent|0|always|optional|bin/harden-permissions.sh"
  "file|bin/redact-logs.sh|runtime/bin/redact-logs.sh|u+x|agent|0|always|optional|bin/redact-logs.sh"
  "file|bin/prune-session-logs.sh|runtime/bin/prune-session-logs.sh|u+x|agent|0|always|optional|bin/prune-session-logs.sh"
  "file|bin/verify-manifest.sh|runtime/bin/verify-manifest.sh|u+x|agent|0|always|optional|bin/verify-manifest.sh"
  "file|bin/lib/runtime-node.sh|runtime/bin/lib/runtime-node.sh|u+r|agent|0|always|optional|bin/lib/runtime-node.sh"
  "file|bin/lib/bridge-restart-policy.sh|runtime/bin/lib/bridge-restart-policy.sh|u+r|agent|0|always|optional|bin/lib/bridge-restart-policy.sh"
  "file|start.sh|runtime/start.sh|u+x|agent|0|always|required|start.sh"
  "file|settings.json|.pi/agent/settings.json|600|agent|0|always|optional|settings.json"
  "file|.env.schema|.config/.env.schema|644|agent|0|always|optional|.env.schema → ~/.config/.env.schema"
)

deploy_runtime_asset_entry() {
  local entry="$1"
  local src_rel dest_rel mode owner read_only gate required log_label
  IFS='|' read -r _ src_rel dest_rel mode owner read_only gate required log_label <<<"$entry"

  bb_feature_gate_enabled "$gate" "$EXPERIMENTAL_MODE" || return 0

  local src_path="$STAGE_DIR/$src_rel"
  local dest_path="$BAUDBOT_HOME/$dest_rel"

  if [ ! -e "$src_path" ]; then
    [ "$required" = "required" ] && bb_die "missing required staged file: $src_rel"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$read_only" = "1" ]; then
      log "would copy: $log_label (read-only)"
    else
      log "would copy: $log_label"
    fi
    return 0
  fi

  if [ "$owner" = "agent" ]; then
    as_agent mkdir -p "$(dirname "$dest_path")"
    as_agent cp "$src_path" "$dest_path"
    as_agent chmod "$mode" "$dest_path"
    if [ "$read_only" = "1" ]; then
      as_agent chmod a-w "$dest_path"
      log "✓ $log_label (read-only)"
    else
      log "✓ $log_label"
    fi
  else
    bb_die "unsupported deploy owner: $owner"
  fi
}

bb_manifest_for_each RUNTIME_ASSET_MANIFEST deploy_runtime_asset_entry

# ── Memory Seeds ─────────────────────────────────────────────────────────────

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

# ── Admin config (secrets) ────────────────────────────────────────────────────

echo "Deploying config..."

# Uses admin env source resolved near script start.

if [ -x "$RENDER_ENV_SCRIPT" ] && BAUDBOT_ADMIN_HOME="$DEPLOY_HOME" BAUDBOT_CONFIG_USER="$DEPLOY_USER" "$RENDER_ENV_SCRIPT" --check >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 0 ]; then
    as_agent bash -c "mkdir -p '$BAUDBOT_HOME/.config'"
    # Stream rendered config directly to agent-owned target to avoid staging secrets in /tmp.
    BAUDBOT_ADMIN_HOME="$DEPLOY_HOME" BAUDBOT_CONFIG_USER="$DEPLOY_USER" "$RENDER_ENV_SCRIPT" | as_agent bash -c "cat > '$BAUDBOT_HOME/.config/.env'"
    as_agent chmod 600 "$BAUDBOT_HOME/.config/.env"
    log "✓ env source → ~/.config/.env (600)"
  else
    log "would render env source → ~/.config/.env"
  fi
elif [ -f "$ADMIN_CONFIG" ]; then
  # Backward-compatible fallback for older checkouts without render-env.sh.
  if [ "$DRY_RUN" -eq 0 ]; then
    as_agent bash -c "mkdir -p '$BAUDBOT_HOME/.config'"
    as_agent bash -c "cat > '$BAUDBOT_HOME/.config/.env'" < "$ADMIN_CONFIG"
    as_agent chmod 600 "$BAUDBOT_HOME/.config/.env"
    log "✓ .env → ~/.config/.env (600)"
  else
    log "would copy: $ADMIN_CONFIG → ~/.config/.env"
  fi
else
  # Fallback: check if agent already has a .env (written directly by old install.sh)
  if as_agent test -f "$BAUDBOT_HOME/.config/.env" 2>/dev/null; then
    log "- .env: using existing agent config (no env source found)"
  else
    log "⚠ no config source found — run: baudbot config or configure 'baudbot env backend'"
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
    GIT_SHA="$(json_get_string_or_empty "$RELEASE_META_FILE" "sha")"
    GIT_SHA_SHORT="$(json_get_string_or_empty "$RELEASE_META_FILE" "short")"
    GIT_BRANCH="$(json_get_string_or_empty "$RELEASE_META_FILE" "branch")"
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
      for dir in '$BAUDBOT_HOME/.pi/agent/extensions' '$BAUDBOT_HOME/.pi/agent/skills' '/opt/baudbot/current/slack-bridge' '$BAUDBOT_HOME/runtime/bin'; do
        if [ -d \"\$dir\" ]; then
          while IFS= read -r f; do
            hash=\$(sha256sum \"\$f\" | cut -d' ' -f1)
            if [[ \"\$f\" == "$BAUDBOT_HOME/"* ]]; then
              rel=\"\${f#$BAUDBOT_HOME/}\"
            elif [[ \"\$f\" == \"/opt/baudbot/current/\"* ]]; then
              rel=\"release/\${f#/opt/baudbot/current/}\"
            else
              rel=\"\$f\"
            fi
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
  echo "Restart runtime services to load changes (recommended):"
  echo "  sudo baudbot restart"
fi
