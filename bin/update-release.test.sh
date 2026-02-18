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

assert_no_git_dirs() {
  local dir="$1"

  if find "$dir" -type d -name .git -print -quit | grep -q .; then
    return 1
  fi

  return 0
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

echo "=== update-release tests ==="
echo ""

run_test "publishes git-free release snapshot" test_publish_git_free_release
run_test "preflight failure keeps current release" test_preflight_failure_keeps_current
run_test "deploy failure keeps current release" test_deploy_failure_keeps_current

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
