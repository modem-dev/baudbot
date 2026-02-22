#!/bin/bash
# Roll back the active /opt/baudbot release snapshot.
#
# Usage:
#   rollback-release.sh previous
#   rollback-release.sh <sha>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
bb_enable_strict_mode

bb_init_paths

BAUDBOT_ROLLBACK_DEPLOY_CMD="${BAUDBOT_ROLLBACK_DEPLOY_CMD:-}"
BAUDBOT_ROLLBACK_RESTART_CMD="${BAUDBOT_ROLLBACK_RESTART_CMD:-}"
BAUDBOT_ROLLBACK_HEALTH_CMD="${BAUDBOT_ROLLBACK_HEALTH_CMD:-}"

BAUDBOT_ROLLBACK_SKIP_RESTART="${BAUDBOT_ROLLBACK_SKIP_RESTART:-0}"
BAUDBOT_ROLLBACK_SKIP_VERSION_CHECK="${BAUDBOT_ROLLBACK_SKIP_VERSION_CHECK:-0}"
BAUDBOT_ROLLBACK_SKIP_CLI_LINK="${BAUDBOT_ROLLBACK_SKIP_CLI_LINK:-0}"
BAUDBOT_ROLLBACK_ALLOW_NON_ROOT="${BAUDBOT_ROLLBACK_ALLOW_NON_ROOT:-0}"

log() { bb_log "$1"; }
die() { bb_die "$1"; }

usage() {
  cat <<EOF
Usage: $0 [previous|<sha>] [--release-root <path>] [--skip-restart]
EOF
}

# shellcheck source=bin/lib/release-common.sh
source "$SCRIPT_DIR/lib/release-common.sh"
# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/lib/json-common.sh"

TARGET_SPEC="${1:-previous}"
if [ "$#" -gt 0 ]; then
  shift
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-root)
      [ "$#" -ge 2 ] || die "--release-root requires a value"
      BAUDBOT_RELEASE_ROOT="$2"
      shift 2
      ;;
    --skip-restart)
      BAUDBOT_ROLLBACK_SKIP_RESTART=1
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
# wins over any inherited BAUDBOT_CURRENT/PREVIOUS/RELEASES path variables.
bb_refresh_release_paths "${BAUDBOT_RELEASE_ROOT:-/opt/baudbot}" 1

bb_require_root "rollback (or BAUDBOT_ROLLBACK_ALLOW_NON_ROOT=1 for tests)" "$BAUDBOT_ROLLBACK_ALLOW_NON_ROOT"

[ -d "$BAUDBOT_RELEASES_DIR" ] || die "release directory missing: $BAUDBOT_RELEASES_DIR"

CURRENT_TARGET=""
if [ -L "$BAUDBOT_CURRENT_LINK" ] || [ -e "$BAUDBOT_CURRENT_LINK" ]; then
  CURRENT_TARGET="$(readlink -f "$BAUDBOT_CURRENT_LINK" 2>/dev/null || true)"
fi

[ -n "$CURRENT_TARGET" ] || die "current release link is missing: $BAUDBOT_CURRENT_LINK"

TARGET_RELEASE=""
if [ "$TARGET_SPEC" = "previous" ]; then
  [ -L "$BAUDBOT_PREVIOUS_LINK" ] || die "no previous release pointer at $BAUDBOT_PREVIOUS_LINK"
  TARGET_RELEASE="$(readlink -f "$BAUDBOT_PREVIOUS_LINK" 2>/dev/null || true)"
  [ -n "$TARGET_RELEASE" ] || die "failed to resolve previous release"
else
  if [ -d "$BAUDBOT_RELEASES_DIR/$TARGET_SPEC" ]; then
    TARGET_RELEASE="$BAUDBOT_RELEASES_DIR/$TARGET_SPEC"
  else
    matches=$(find "$BAUDBOT_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -name "$TARGET_SPEC*" -printf '%f\n' | sort)
    count=$(echo "$matches" | grep -c . || true)
    if [ "$count" -eq 1 ]; then
      TARGET_RELEASE="$BAUDBOT_RELEASES_DIR/$(echo "$matches" | head -1)"
    elif [ "$count" -gt 1 ]; then
      die "ambiguous release prefix '$TARGET_SPEC'"
    else
      die "release not found: $TARGET_SPEC"
    fi
  fi
fi

verify_git_free_release "$TARGET_RELEASE" || die "target release is invalid or contains .git: $TARGET_RELEASE"

if [ "$TARGET_RELEASE" = "$CURRENT_TARGET" ]; then
  echo "✅ Already on requested release"
  exit 0
fi

run_deploy() {
  if [ -n "$BAUDBOT_ROLLBACK_DEPLOY_CMD" ]; then
    log "running deploy override"
    BAUDBOT_ROLLBACK_TARGET_RELEASE="$TARGET_RELEASE" bash -lc "$BAUDBOT_ROLLBACK_DEPLOY_CMD"
    return 0
  fi

  [ -x "$TARGET_RELEASE/bin/deploy.sh" ] || die "missing deploy script in release: $TARGET_RELEASE/bin/deploy.sh"

  log "deploying rollback release"
  DEPLOY_CONFIG_USER="${BAUDBOT_CONFIG_USER:-${SUDO_USER:-}}"
  BAUDBOT_SRC="$TARGET_RELEASE" BAUDBOT_CONFIG_USER="$DEPLOY_CONFIG_USER" bash "$TARGET_RELEASE/bin/deploy.sh"
}

run_restart_and_health() {
  if [ -n "$BAUDBOT_ROLLBACK_RESTART_CMD" ]; then
    log "running restart override"
    BAUDBOT_ROLLBACK_TARGET_RELEASE="$TARGET_RELEASE" bash -lc "$BAUDBOT_ROLLBACK_RESTART_CMD"
  elif [ "$BAUDBOT_ROLLBACK_SKIP_RESTART" = "1" ]; then
    log "skipping restart"
  else
    restart_baudbot_service_if_active
  fi

  if [ -n "$BAUDBOT_ROLLBACK_HEALTH_CMD" ]; then
    log "running health override"
    BAUDBOT_ROLLBACK_TARGET_RELEASE="$TARGET_RELEASE" bash -lc "$BAUDBOT_ROLLBACK_HEALTH_CMD"
  fi

  if [ "$BAUDBOT_ROLLBACK_SKIP_VERSION_CHECK" = "1" ]; then
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
  local expected_sha
  local deployed_sha

  expected_sha="$(json_get_string_or_empty "$TARGET_RELEASE/baudbot-release.json" "sha")"
  [ -n "$expected_sha" ] || expected_sha="$(basename "$TARGET_RELEASE")"

  deployed_sha="$(sudo -u "$BAUDBOT_AGENT_USER" sh -c "cat '$version_file' 2>/dev/null" | json_get_string_stdin "sha" 2>/dev/null || true)"

  if [ -z "$deployed_sha" ]; then
    die "deployed version file missing or unreadable: $version_file"
  fi

  if [ "$deployed_sha" != "$expected_sha" ]; then
    die "deployed sha mismatch (expected $expected_sha, got $deployed_sha)"
  fi
}

install_cli_link() {
  if [ "$BAUDBOT_ROLLBACK_SKIP_CLI_LINK" = "1" ]; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi

  atomic_symlink_swap "$BAUDBOT_CURRENT_LINK/bin/baudbot" /usr/local/bin/baudbot
}

echo "=== Baudbot rollback ==="
log "target: $TARGET_RELEASE"
log "current: $CURRENT_TARGET"

run_deploy
run_restart_and_health

atomic_symlink_swap "$CURRENT_TARGET" "$BAUDBOT_PREVIOUS_LINK"
atomic_symlink_swap "$TARGET_RELEASE" "$BAUDBOT_CURRENT_LINK"
install_cli_link

log "rollback complete"
log "current -> $(readlink -f "$BAUDBOT_CURRENT_LINK")"

echo "✅ Rollback complete"
