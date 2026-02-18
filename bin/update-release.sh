#!/bin/bash
# Publish a git-free release snapshot under /opt/baudbot and deploy it.
#
# Default flow:
#   1) Clone target ref into /tmp/baudbot-update.*
#   2) Run preflight checks in temp checkout
#   3) Create immutable git-free release at /opt/baudbot/releases/<sha>
#   4) Deploy from release dir, restart + verify
#   5) Atomically switch /opt/baudbot/current on success
#
# This script keeps the currently active release untouched on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAUDBOT_ROOT="${BAUDBOT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

BAUDBOT_RELEASE_ROOT="${BAUDBOT_RELEASE_ROOT:-/opt/baudbot}"
BAUDBOT_RELEASES_DIR="${BAUDBOT_RELEASES_DIR:-$BAUDBOT_RELEASE_ROOT/releases}"
BAUDBOT_CURRENT_LINK="${BAUDBOT_CURRENT_LINK:-$BAUDBOT_RELEASE_ROOT/current}"
BAUDBOT_PREVIOUS_LINK="${BAUDBOT_PREVIOUS_LINK:-$BAUDBOT_RELEASE_ROOT/previous}"

SOURCE_URL_FILE="$BAUDBOT_RELEASE_ROOT/source.url"
SOURCE_BRANCH_FILE="$BAUDBOT_RELEASE_ROOT/source.branch"

BAUDBOT_UPDATE_TMP_PARENT="${BAUDBOT_UPDATE_TMP_PARENT:-/tmp}"
BAUDBOT_UPDATE_REPO="${BAUDBOT_UPDATE_REPO:-}"
BAUDBOT_UPDATE_BRANCH="${BAUDBOT_UPDATE_BRANCH:-}"
BAUDBOT_UPDATE_REF="${BAUDBOT_UPDATE_REF:-}"

BAUDBOT_UPDATE_PREFLIGHT_CMD="${BAUDBOT_UPDATE_PREFLIGHT_CMD:-bin/test.sh shell}"
BAUDBOT_UPDATE_DEPLOY_CMD="${BAUDBOT_UPDATE_DEPLOY_CMD:-}"
BAUDBOT_UPDATE_RESTART_CMD="${BAUDBOT_UPDATE_RESTART_CMD:-}"
BAUDBOT_UPDATE_HEALTH_CMD="${BAUDBOT_UPDATE_HEALTH_CMD:-}"

BAUDBOT_UPDATE_SKIP_PREFLIGHT="${BAUDBOT_UPDATE_SKIP_PREFLIGHT:-0}"
BAUDBOT_UPDATE_SKIP_RESTART="${BAUDBOT_UPDATE_SKIP_RESTART:-0}"
BAUDBOT_UPDATE_SKIP_VERSION_CHECK="${BAUDBOT_UPDATE_SKIP_VERSION_CHECK:-0}"
BAUDBOT_UPDATE_SKIP_CLI_LINK="${BAUDBOT_UPDATE_SKIP_CLI_LINK:-0}"
BAUDBOT_UPDATE_ALLOW_NON_ROOT="${BAUDBOT_UPDATE_ALLOW_NON_ROOT:-0}"

BAUDBOT_AGENT_USER="${BAUDBOT_AGENT_USER:-baudbot_agent}"
BAUDBOT_AGENT_HOME="${BAUDBOT_AGENT_HOME:-/home/baudbot_agent}"

CHECKOUT_DIR=""
STAGING_DIR=""
TARGET_SHA=""
TARGET_BRANCH=""
TARGET_SHORT=""
RELEASE_DIR=""

log() { echo "  $1"; }

die() {
  echo "❌ $1" >&2
  exit 1
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

cleanup() {
  if [ -n "$CHECKOUT_DIR" ] && [ -d "$CHECKOUT_DIR" ]; then
    rm -rf "$CHECKOUT_DIR"
  fi
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo <url>           Override source repo URL/path
  --branch <name>        Branch to update from (default: remembered or main)
  --ref <git-ref>        Specific ref/SHA/tag to update to
  --release-root <path>  Override release root (default: /opt/baudbot)
  --skip-preflight       Skip preflight checks
  --skip-restart         Skip restart check
  -h, --help             Show help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires a value"
      BAUDBOT_UPDATE_REPO="$2"
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || die "--branch requires a value"
      BAUDBOT_UPDATE_BRANCH="$2"
      shift 2
      ;;
    --ref)
      [ "$#" -ge 2 ] || die "--ref requires a value"
      BAUDBOT_UPDATE_REF="$2"
      shift 2
      ;;
    --release-root)
      [ "$#" -ge 2 ] || die "--release-root requires a value"
      BAUDBOT_RELEASE_ROOT="$2"
      BAUDBOT_RELEASES_DIR="$BAUDBOT_RELEASE_ROOT/releases"
      BAUDBOT_CURRENT_LINK="$BAUDBOT_RELEASE_ROOT/current"
      BAUDBOT_PREVIOUS_LINK="$BAUDBOT_RELEASE_ROOT/previous"
      SOURCE_URL_FILE="$BAUDBOT_RELEASE_ROOT/source.url"
      SOURCE_BRANCH_FILE="$BAUDBOT_RELEASE_ROOT/source.branch"
      shift 2
      ;;
    --skip-preflight)
      BAUDBOT_UPDATE_SKIP_PREFLIGHT=1
      shift
      ;;
    --skip-restart)
      BAUDBOT_UPDATE_SKIP_RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ] && [ "$BAUDBOT_UPDATE_ALLOW_NON_ROOT" != "1" ]; then
  die "update requires root (or BAUDBOT_UPDATE_ALLOW_NON_ROOT=1 for tests)"
fi

resolve_repo_url() {
  if [ -n "$BAUDBOT_UPDATE_REPO" ]; then
    echo "$BAUDBOT_UPDATE_REPO"
    return 0
  fi

  if [ -f "$SOURCE_URL_FILE" ]; then
    head -n 1 "$SOURCE_URL_FILE"
    return 0
  fi

  if [ -d "$BAUDBOT_ROOT/.git" ]; then
    git -C "$BAUDBOT_ROOT" remote get-url origin 2>/dev/null && return 0
  fi

  return 1
}

resolve_branch() {
  if [ -n "$BAUDBOT_UPDATE_BRANCH" ]; then
    echo "$BAUDBOT_UPDATE_BRANCH"
    return 0
  fi

  if [ -f "$SOURCE_BRANCH_FILE" ]; then
    head -n 1 "$SOURCE_BRANCH_FILE"
    return 0
  fi

  if [ -d "$BAUDBOT_ROOT/.git" ]; then
    git -C "$BAUDBOT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null && return 0
  fi

  echo "main"
}

verify_git_free_release() {
  local dir="$1"

  if [ -d "$dir/.git" ]; then
    return 1
  fi

  if find "$dir" -type d -name .git -print -quit | grep -q .; then
    return 1
  fi

  return 0
}

atomic_symlink_swap() {
  local target="$1"
  local link_path="$2"
  local parent
  local tmp_link

  parent="$(dirname "$link_path")"
  mkdir -p "$parent"

  tmp_link="$parent/.tmp.$(basename "$link_path").$$"
  ln -s "$target" "$tmp_link"
  mv -Tf "$tmp_link" "$link_path"
}

save_source_metadata() {
  local repo_url="$1"
  local branch="$2"

  mkdir -p "$BAUDBOT_RELEASE_ROOT"
  printf '%s\n' "$repo_url" > "$SOURCE_URL_FILE"
  printf '%s\n' "$branch" > "$SOURCE_BRANCH_FILE"
}

run_preflight() {
  local checkout="$1"

  if [ "$BAUDBOT_UPDATE_SKIP_PREFLIGHT" = "1" ]; then
    log "skipping preflight checks"
    return 0
  fi

  log "running preflight: $BAUDBOT_UPDATE_PREFLIGHT_CMD"
  (
    cd "$checkout"
    bash -lc "$BAUDBOT_UPDATE_PREFLIGHT_CMD"
  )
}

write_release_metadata() {
  local release_dir="$1"
  local repo_url="$2"
  local branch="$3"
  local deployed_by
  local built_at

  deployed_by="${SUDO_USER:-$(whoami)}"
  built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  cat > "$release_dir/baudbot-release.json" <<EOF
{
  "sha": "$TARGET_SHA",
  "short": "$TARGET_SHORT",
  "branch": "$branch",
  "source_repo": "$repo_url",
  "built_at": "$built_at",
  "built_by": "$deployed_by"
}
EOF
  chmod 644 "$release_dir/baudbot-release.json"
}

publish_release() {
  local checkout="$1"
  local repo_url="$2"
  local branch="$3"

  mkdir -p "$BAUDBOT_RELEASES_DIR"
  RELEASE_DIR="$BAUDBOT_RELEASES_DIR/$TARGET_SHA"

  if [ -d "$RELEASE_DIR" ]; then
    log "release already exists: $RELEASE_DIR"
    verify_git_free_release "$RELEASE_DIR" || die "existing release contains .git: $RELEASE_DIR"
    return 0
  fi

  STAGING_DIR="$(mktemp -d "$BAUDBOT_RELEASES_DIR/.staging.$TARGET_SHORT.XXXXXX")"
  log "publishing release: $RELEASE_DIR"

  (
    cd "$checkout"
    tar --exclude='.git' -cf - .
  ) | (
    cd "$STAGING_DIR"
    tar -xf -
  )

  verify_git_free_release "$STAGING_DIR" || die "staged release contains .git"
  write_release_metadata "$STAGING_DIR" "$repo_url" "$branch"

  # Release snapshots are immutable artifacts (files read-only).
  # Keep directories writable for release pruning/cleanup workflows.
  find "$STAGING_DIR" -type f -exec chmod a-w {} +

  mv "$STAGING_DIR" "$RELEASE_DIR"
  STAGING_DIR=""
}

run_deploy() {
  if [ -n "$BAUDBOT_UPDATE_DEPLOY_CMD" ]; then
    log "running deploy override"
    BAUDBOT_UPDATE_RELEASE_DIR="$RELEASE_DIR" BAUDBOT_UPDATE_CHECKOUT_DIR="$CHECKOUT_DIR" bash -lc "$BAUDBOT_UPDATE_DEPLOY_CMD"
    return 0
  fi

  [ -x "$RELEASE_DIR/bin/deploy.sh" ] || die "missing deploy script in release: $RELEASE_DIR/bin/deploy.sh"

  log "deploying release to runtime"
  DEPLOY_CONFIG_USER="${BAUDBOT_CONFIG_USER:-${SUDO_USER:-}}"
  BAUDBOT_SRC="$RELEASE_DIR" BAUDBOT_CONFIG_USER="$DEPLOY_CONFIG_USER" bash "$RELEASE_DIR/bin/deploy.sh"
}

run_restart_and_health() {
  local was_active=0

  if [ -n "$BAUDBOT_UPDATE_RESTART_CMD" ]; then
    log "running restart override"
    BAUDBOT_UPDATE_RELEASE_DIR="$RELEASE_DIR" BAUDBOT_UPDATE_CHECKOUT_DIR="$CHECKOUT_DIR" bash -lc "$BAUDBOT_UPDATE_RESTART_CMD"
  elif [ "$BAUDBOT_UPDATE_SKIP_RESTART" = "1" ]; then
    log "skipping restart"
  else
    if has_systemd && systemctl is-enabled baudbot >/dev/null 2>&1; then
      if systemctl is-active baudbot >/dev/null 2>&1; then
        was_active=1
      fi

      if [ "$was_active" -eq 1 ]; then
        log "restarting baudbot service"
        systemctl restart baudbot
        sleep 3
        systemctl is-active baudbot >/dev/null 2>&1 || die "service failed to restart"
      else
        log "service installed but not active; skipping restart"
      fi
    else
      log "systemd unavailable; skipping restart"
    fi
  fi

  if [ -n "$BAUDBOT_UPDATE_HEALTH_CMD" ]; then
    log "running health override"
    BAUDBOT_UPDATE_RELEASE_DIR="$RELEASE_DIR" BAUDBOT_UPDATE_CHECKOUT_DIR="$CHECKOUT_DIR" bash -lc "$BAUDBOT_UPDATE_HEALTH_CMD"
  fi

  if [ "$BAUDBOT_UPDATE_SKIP_VERSION_CHECK" = "1" ]; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    log "non-root run: skipping deployed version verification"
    return 0
  fi

  if ! id "$BAUDBOT_AGENT_USER" >/dev/null 2>&1; then
    log "agent user '$BAUDBOT_AGENT_USER' missing; skipping deployed version verification"
    return 0
  fi

  local version_file="$BAUDBOT_AGENT_HOME/.pi/agent/baudbot-version.json"
  local deployed_sha

  deployed_sha="$(sudo -u "$BAUDBOT_AGENT_USER" sh -c "grep '\"sha\"' '$version_file' 2>/dev/null | head -1 | sed 's/.*\"sha\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/'")"

  if [ -z "$deployed_sha" ]; then
    die "deployed version file missing or unreadable: $version_file"
  fi

  if [ "$deployed_sha" != "$TARGET_SHA" ]; then
    die "deployed sha mismatch (expected $TARGET_SHA, got $deployed_sha)"
  fi

  log "deployed version verified: $TARGET_SHORT"
}

install_cli_link() {
  if [ "$BAUDBOT_UPDATE_SKIP_CLI_LINK" = "1" ]; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi

  atomic_symlink_swap "$BAUDBOT_CURRENT_LINK/bin/baudbot" /usr/local/bin/baudbot
}

echo "=== Baudbot update ==="

REPO_URL="$(resolve_repo_url)" || die "cannot resolve update repo URL; pass --repo or set BAUDBOT_UPDATE_REPO"
BRANCH="$(resolve_branch)"

if [ -z "$REPO_URL" ]; then
  die "empty repo URL"
fi
if [ -z "$BRANCH" ]; then
  die "empty branch"
fi

save_source_metadata "$REPO_URL" "$BRANCH"

CHECKOUT_DIR="$(mktemp -d "$BAUDBOT_UPDATE_TMP_PARENT/baudbot-update.XXXXXX")"

log "repo: $REPO_URL"
log "branch: $BRANCH"

# Local path repositories need explicit trust when root clones from an
# admin-owned checkout (safe.directory protection).
if [ "$(id -u)" -eq 0 ] && [ -d "$REPO_URL/.git" ]; then
  LOCAL_REPO_REAL="$(cd "$REPO_URL" && pwd)"
  git config --global --add safe.directory "$LOCAL_REPO_REAL" >/dev/null 2>&1 || true
  git config --global --add safe.directory "$LOCAL_REPO_REAL/.git" >/dev/null 2>&1 || true
fi

log "cloning update source"
git clone --quiet --single-branch --branch "$BRANCH" "$REPO_URL" "$CHECKOUT_DIR"

if [ -n "$BAUDBOT_UPDATE_REF" ]; then
  log "checking out ref: $BAUDBOT_UPDATE_REF"
  git -C "$CHECKOUT_DIR" fetch --quiet origin "$BAUDBOT_UPDATE_REF"
  git -C "$CHECKOUT_DIR" checkout --quiet --detach FETCH_HEAD
fi

TARGET_SHA="$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
TARGET_SHORT="$(git -C "$CHECKOUT_DIR" rev-parse --short HEAD)"
TARGET_BRANCH="$(git -C "$CHECKOUT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$BRANCH")"

log "target: $TARGET_SHORT"

run_preflight "$CHECKOUT_DIR"
publish_release "$CHECKOUT_DIR" "$REPO_URL" "$TARGET_BRANCH"
run_deploy
run_restart_and_health

CURRENT_TARGET=""
if [ -L "$BAUDBOT_CURRENT_LINK" ] || [ -e "$BAUDBOT_CURRENT_LINK" ]; then
  CURRENT_TARGET="$(readlink -f "$BAUDBOT_CURRENT_LINK" 2>/dev/null || true)"
fi

if [ -n "$CURRENT_TARGET" ] && [ "$CURRENT_TARGET" != "$RELEASE_DIR" ]; then
  atomic_symlink_swap "$CURRENT_TARGET" "$BAUDBOT_PREVIOUS_LINK"
fi

atomic_symlink_swap "$RELEASE_DIR" "$BAUDBOT_CURRENT_LINK"
install_cli_link

verify_git_free_release "$RELEASE_DIR" || die "release contains .git after publish"

log "active release: $RELEASE_DIR"
log "current -> $(readlink -f "$BAUDBOT_CURRENT_LINK")"

echo "✅ Update complete ($TARGET_SHORT)"
