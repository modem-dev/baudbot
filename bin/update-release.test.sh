#!/bin/bash
# Integration-style tests for git-free release updates.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_SCRIPT="$REPO_ROOT/bin/update-release.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-update-test-output.XXXXXX)"
  if "$@" >"$out" 2>&1; then
    echo "✓"
    PASSED=$((PASSED + 1))
  else
    echo "✗ FAILED"
    tail -40 "$out" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
  rm -f "$out"
}

make_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "baudbot-test"
  git -C "$repo" config user.email "baudbot-test@example.com"

  cat > "$repo/hello.txt" <<EOF
hello
EOF

  cat > "$repo/README.md" <<EOF
# test repo
EOF

  git -C "$repo" add hello.txt README.md
  git -C "$repo" commit -q -m "initial"
}

new_commit() {
  local repo="$1"
  local label="$2"

  printf 'hello %s %s\n' "$label" "$RANDOM" > "$repo/hello.txt"
  git -C "$repo" add hello.txt
  git -C "$repo" commit -q -m "$label"
}

run_update() {
  local repo="$1"
  local release_root="$2"
  local preflight_cmd="$3"
  local deploy_cmd="${4:-true}"

  BAUDBOT_UPDATE_ALLOW_NON_ROOT=1 \
    BAUDBOT_RELEASE_ROOT="$release_root" \
    BAUDBOT_UPDATE_REPO="$repo" \
    BAUDBOT_UPDATE_BRANCH="main" \
    BAUDBOT_UPDATE_PREFLIGHT_CMD="$preflight_cmd" \
    BAUDBOT_UPDATE_DEPLOY_CMD="$deploy_cmd" \
    BAUDBOT_UPDATE_RESTART_CMD="true" \
    BAUDBOT_UPDATE_HEALTH_CMD="true" \
    BAUDBOT_UPDATE_SKIP_VERSION_CHECK=1 \
    BAUDBOT_UPDATE_SKIP_CLI_LINK=1 \
    "$UPDATE_SCRIPT"
}

run_update_with_stale_source_paths() {
  local repo="$1"
  local release_root="$2"
  local stale_root="$3"

  BAUDBOT_UPDATE_ALLOW_NON_ROOT=1 \
    BAUDBOT_RELEASE_ROOT="$release_root" \
    BAUDBOT_SOURCE_URL_FILE="$stale_root/source.url" \
    BAUDBOT_SOURCE_BRANCH_FILE="$stale_root/source.branch" \
    BAUDBOT_UPDATE_REPO="$repo" \
    BAUDBOT_UPDATE_BRANCH="main" \
    BAUDBOT_UPDATE_PREFLIGHT_CMD="test -f hello.txt" \
    BAUDBOT_UPDATE_DEPLOY_CMD="true" \
    BAUDBOT_UPDATE_RESTART_CMD="true" \
    BAUDBOT_UPDATE_HEALTH_CMD="true" \
    BAUDBOT_UPDATE_SKIP_VERSION_CHECK=1 \
    BAUDBOT_UPDATE_SKIP_CLI_LINK=1 \
    "$UPDATE_SCRIPT"
}

assert_no_git_dirs() {
  local dir="$1"

  if find "$dir" -type d -name .git -print -quit | grep -q .; then
    return 1
  fi

  return 0
}

define_test_resolve_npm_bin() {
  resolve_npm_bin() {
    local candidate=""

    local agent_home="/home/${BAUDBOT_AGENT_USER:-baudbot_agent}"
    candidate="$(bb_resolve_runtime_node_bin_dir "$agent_home" 2>/dev/null || true)"
    if [ -n "$candidate" ] && [ -x "$candidate/npm" ]; then
      echo "$candidate/npm"
      return 0
    fi

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      local sudo_home=""
      sudo_home="$(bb_resolve_user_home "$SUDO_USER" 2>/dev/null || true)"
      if [ -n "$sudo_home" ]; then
        local dir=""
        for dir in \
          "$sudo_home/.local/share/mise/shims" \
          "$sudo_home/.nvm/versions/node"/*/bin \
          "$sudo_home/.local/bin"; do
          case "$dir" in *\**) continue ;; esac
          if [ -x "$dir/npm" ]; then
            echo "$dir/npm"
            return 0
          fi
        done
      fi
    fi

    if command -v npm >/dev/null 2>&1; then
      command -v npm
      return 0
    fi

    return 1
  }
}

test_publish_git_free_release() {
  (
    set -euo pipefail
    local tmp repo release_root sha current_target

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    run_update "$repo" "$release_root" "test -f hello.txt"

    sha="$(git -C "$repo" rev-parse HEAD)"
    current_target="$(readlink -f "$release_root/current")"

    [ "$current_target" = "$release_root/releases/$sha" ]
    [ -f "$current_target/baudbot-release.json" ]
    grep -q '"version": "0.1.0"' "$current_target/baudbot-release.json"
    grep -q '"tag": "v0.1.0"' "$current_target/baudbot-release.json"
    # Release root must be traversable so /usr/local/bin/baudbot is discoverable.
    [ "$(stat -c '%a' "$current_target")" = "755" ]
    assert_no_git_dirs "$release_root/releases"
  )
}

test_preflight_failure_keeps_current() {
  (
    set -euo pipefail
    local tmp repo release_root before after next_sha

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    run_update "$repo" "$release_root" "test -f hello.txt"

    before="$(readlink -f "$release_root/current")"
    new_commit "$repo" "second"
    next_sha="$(git -C "$repo" rev-parse HEAD)"

    if run_update "$repo" "$release_root" "false"; then
      return 1
    fi

    after="$(readlink -f "$release_root/current")"
    [ "$before" = "$after" ]
    [ ! -d "$release_root/releases/$next_sha" ]
  )
}

test_deploy_failure_keeps_current() {
  (
    set -euo pipefail
    local tmp repo release_root before after next_sha

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    run_update "$repo" "$release_root" "test -f hello.txt"

    before="$(readlink -f "$release_root/current")"
    new_commit "$repo" "third"
    next_sha="$(git -C "$repo" rev-parse HEAD)"

    if run_update "$repo" "$release_root" "test -f hello.txt" "false"; then
      return 1
    fi

    after="$(readlink -f "$release_root/current")"
    [ "$before" = "$after" ]
    [ -d "$release_root/releases/$next_sha" ]
    assert_no_git_dirs "$release_root/releases/$next_sha"
  )
}

test_release_root_overrides_stale_source_path_env() {
  (
    set -euo pipefail
    local tmp repo release_root stale_root

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"
    stale_root="$tmp/stale"

    mkdir -p "$stale_root"
    make_repo "$repo"

    run_update_with_stale_source_paths "$repo" "$release_root" "$stale_root"

    [ -f "$release_root/source.url" ]
    [ -f "$release_root/source.branch" ]
    [ ! -f "$stale_root/source.url" ]
    [ ! -f "$stale_root/source.branch" ]
  )
}

test_update_picks_up_latest_commit() {
  (
    set -euo pipefail
    local tmp repo release_root sha1 sha2 current_sha

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    sha1="$(git -C "$repo" rev-parse HEAD)"

    run_update "$repo" "$release_root" "test -f hello.txt"

    current_sha="$(readlink -f "$release_root/current")"
    [ "$current_sha" = "$release_root/releases/$sha1" ]

    # Push a new commit and update again — must land on the new SHA.
    new_commit "$repo" "latest-tip"
    sha2="$(git -C "$repo" rev-parse HEAD)"
    [ "$sha1" != "$sha2" ]

    run_update "$repo" "$release_root" "test -f hello.txt"

    current_sha="$(readlink -f "$release_root/current")"
    [ "$current_sha" = "$release_root/releases/$sha2" ]
  )
}

test_resolve_npm_from_fake_agent_home() {
  (
    set -euo pipefail
    local tmp fake_home npm_path

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    # Create a fake embedded node runtime layout.
    fake_home="$tmp/home/baudbot_agent"
    mkdir -p "$fake_home/opt/node/bin"
    printf '#!/bin/sh\necho fake-npm\n' > "$fake_home/opt/node/bin/npm"
    chmod +x "$fake_home/opt/node/bin/npm"
    # Create a matching node binary so bb_resolve_runtime_node_bin succeeds.
    printf '#!/bin/sh\ntrue\n' > "$fake_home/opt/node/bin/node"
    chmod +x "$fake_home/opt/node/bin/node"

    # Source shared helpers and define a test copy of resolve_npm_bin.
    npm_path="$(
      source "$REPO_ROOT/bin/lib/shell-common.sh"
      source "$REPO_ROOT/bin/lib/paths-common.sh"
      source "$REPO_ROOT/bin/lib/runtime-node.sh"
      source "$REPO_ROOT/bin/lib/release-common.sh"
      source "$REPO_ROOT/bin/lib/release-runtime-common.sh"
      source "$REPO_ROOT/bin/lib/json-common.sh"
      define_test_resolve_npm_bin

      BAUDBOT_AGENT_USER="baudbot_agent"
      BAUDBOT_HOME="$fake_home"
      unset SUDO_USER
      # Point the resolution at our fake tree.
      BAUDBOT_RUNTIME_NODE_BIN_DIR="$fake_home/opt/node/bin"
      resolve_npm_bin
    )"

    [ "$npm_path" = "$fake_home/opt/node/bin/npm" ]
  )
}

test_resolve_npm_from_fake_sudo_user_home() {
  (
    set -euo pipefail
    local tmp fake_sudo_home npm_path

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    fake_sudo_home="$tmp/home/baudbot_admin"
    mkdir -p "$fake_sudo_home/.local/share/mise/shims"
    printf '#!/bin/sh\necho fake-sudo-npm\n' > "$fake_sudo_home/.local/share/mise/shims/npm"
    chmod +x "$fake_sudo_home/.local/share/mise/shims/npm"

    npm_path="$(
      source "$REPO_ROOT/bin/lib/shell-common.sh"
      source "$REPO_ROOT/bin/lib/paths-common.sh"
      source "$REPO_ROOT/bin/lib/runtime-node.sh"
      source "$REPO_ROOT/bin/lib/release-common.sh"
      source "$REPO_ROOT/bin/lib/release-runtime-common.sh"
      source "$REPO_ROOT/bin/lib/json-common.sh"
      define_test_resolve_npm_bin

      bb_resolve_user_home() {
        [ "$1" = "baudbot_admin" ] || return 1
        echo "$fake_sudo_home"
      }

      BAUDBOT_AGENT_USER="missing-agent"
      BAUDBOT_HOME="$tmp/home/missing-agent"
      unset BAUDBOT_RUNTIME_NODE_BIN BAUDBOT_RUNTIME_NODE_DIR BAUDBOT_RUNTIME_NODE_BIN_DIR
      SUDO_USER="baudbot_admin"
      resolve_npm_bin
    )"

    [ "$npm_path" = "$fake_sudo_home/.local/share/mise/shims/npm" ]
  )
}

test_resolve_npm_fails_when_missing() {
  (
    set -euo pipefail
    local tmp

    tmp="$(mktemp -d /tmp/baudbot-update-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    # Empty fake home — no node installed anywhere.
    local result=0
    (
      source "$REPO_ROOT/bin/lib/shell-common.sh"
      source "$REPO_ROOT/bin/lib/paths-common.sh"
      source "$REPO_ROOT/bin/lib/runtime-node.sh"
      define_test_resolve_npm_bin

      BAUDBOT_AGENT_USER="nobody"
      BAUDBOT_HOME="$tmp/home/nobody"
      unset BAUDBOT_RUNTIME_NODE_BIN BAUDBOT_RUNTIME_NODE_DIR BAUDBOT_RUNTIME_NODE_BIN_DIR
      unset SUDO_USER
      mkdir -p "$tmp/empty-path"
      PATH="$tmp/empty-path" resolve_npm_bin
    ) && result=1

    [ "$result" -eq 0 ]
  )
}

echo "=== update-release tests ==="
echo ""

run_test "publishes git-free release snapshot" test_publish_git_free_release
run_test "preflight failure keeps current release" test_preflight_failure_keeps_current
run_test "deploy failure keeps current release" test_deploy_failure_keeps_current
run_test "release root overrides stale source env" test_release_root_overrides_stale_source_path_env
run_test "update picks up latest commit" test_update_picks_up_latest_commit
run_test "resolves npm from agent embedded runtime" test_resolve_npm_from_fake_agent_home
run_test "resolves npm from sudo user home" test_resolve_npm_from_fake_sudo_user_home
run_test "resolve_npm_bin fails when npm missing" test_resolve_npm_fails_when_missing

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
