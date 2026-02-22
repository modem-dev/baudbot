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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
bb_enable_strict_mode

BAUDBOT_ROOT="${BAUDBOT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
bb_init_paths

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

CHECKOUT_DIR=""
STAGING_DIR=""
TARGET_SHA=""
TARGET_BRANCH=""
TARGET_SHORT=""
RELEASE_DIR=""

log() { bb_log "$1"; }
die() { bb_die "$1"; }

# shellcheck source=bin/lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"
# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/lib/json-common.sh"

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

# Normalize release paths after env + CLI parsing so BAUDBOT_RELEASE_ROOT always
# wins over any inherited BAUDBOT_SOURCE_* path variables.
bb_refresh_release_paths "${BAUDBOT_RELEASE_ROOT:-/opt/baudbot}" 1

bb_require_root "update (or BAUDBOT_UPDATE_ALLOW_NON_ROOT=1 for tests)" "$BAUDBOT_UPDATE_ALLOW_NON_ROOT"

resolve_repo_url() {
  if [ -n "$BAUDBOT_UPDATE_REPO" ]; then
    echo "$BAUDBOT_UPDATE_REPO"
    return 0
  fi

  if [ -f "$BAUDBOT_SOURCE_URL_FILE" ]; then
    head -n 1 "$BAUDBOT_SOURCE_URL_FILE"
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

  if [ -f "$BAUDBOT_SOURCE_BRANCH_FILE" ]; then
    head -n 1 "$BAUDBOT_SOURCE_BRANCH_FILE"
    return 0
  fi

  if [ -d "$BAUDBOT_ROOT/.git" ]; then
    git -C "$BAUDBOT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null && return 0
  fi

  echo "main"
}

save_source_metadata() {
  local repo_url="$1"
  local branch="$2"

  mkdir -p "$BAUDBOT_RELEASE_ROOT"
  printf '%s\n' "$repo_url" > "$BAUDBOT_SOURCE_URL_FILE"
  printf '%s\n' "$branch" > "$BAUDBOT_SOURCE_BRANCH_FILE"
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
    # Ensure the top-level release directory is traversable by non-root users
    # so /usr/local/bin/baudbot remains discoverable on PATH.
    chmod a+rx "$RELEASE_DIR" 2>/dev/null || true
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

  # Ensure release root is traversable by non-root users so the global
  # /usr/local/bin/baudbot symlink can be resolved from PATH.
  chmod a+rx "$STAGING_DIR"

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
  if [ -n "$BAUDBOT_UPDATE_RESTART_CMD" ]; then
    log "running restart override"
    BAUDBOT_UPDATE_RELEASE_DIR="$RELEASE_DIR" BAUDBOT_UPDATE_CHECKOUT_DIR="$CHECKOUT_DIR" bash -lc "$BAUDBOT_UPDATE_RESTART_CMD"
  elif [ "$BAUDBOT_UPDATE_SKIP_RESTART" = "1" ]; then
    log "skipping restart"
  else
    restart_baudbot_service_if_active
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

  deployed_sha="$(sudo -u "$BAUDBOT_AGENT_USER" sh -c "cat '$version_file' 2>/dev/null" | json_get_string_stdin "sha" 2>/dev/null || true)"

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

bb_require_non_empty "repo URL" "$REPO_URL"
bb_require_non_empty "branch" "$BRANCH"

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
