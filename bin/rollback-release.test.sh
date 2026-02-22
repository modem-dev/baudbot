#!/bin/bash
# Integration-style tests for rollback-release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_SCRIPT="$REPO_ROOT/bin/update-release.sh"
ROLLBACK_SCRIPT="$REPO_ROOT/bin/rollback-release.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-rollback-test-output.XXXXXX)"
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

  echo "hello" > "$repo/hello.txt"
  git -C "$repo" add hello.txt
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

  BAUDBOT_UPDATE_ALLOW_NON_ROOT=1 \
    BAUDBOT_RELEASE_ROOT="$release_root" \
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

run_rollback() {
  local release_root="$1"
  local target="${2:-previous}"
  local deploy_cmd="${3:-true}"

  BAUDBOT_ROLLBACK_ALLOW_NON_ROOT=1 \
    BAUDBOT_RELEASE_ROOT="$release_root" \
    BAUDBOT_ROLLBACK_DEPLOY_CMD="$deploy_cmd" \
    BAUDBOT_ROLLBACK_RESTART_CMD="true" \
    BAUDBOT_ROLLBACK_HEALTH_CMD="true" \
    BAUDBOT_ROLLBACK_SKIP_VERSION_CHECK=1 \
    BAUDBOT_ROLLBACK_SKIP_CLI_LINK=1 \
    "$ROLLBACK_SCRIPT" "$target"
}

run_rollback_with_stale_release_paths() {
  local release_root="$1"
  local stale_root="$2"

  BAUDBOT_ROLLBACK_ALLOW_NON_ROOT=1 \
    BAUDBOT_RELEASE_ROOT="$release_root" \
    BAUDBOT_RELEASES_DIR="$stale_root/releases" \
    BAUDBOT_CURRENT_LINK="$stale_root/current" \
    BAUDBOT_PREVIOUS_LINK="$stale_root/previous" \
    BAUDBOT_ROLLBACK_DEPLOY_CMD="true" \
    BAUDBOT_ROLLBACK_RESTART_CMD="true" \
    BAUDBOT_ROLLBACK_HEALTH_CMD="true" \
    BAUDBOT_ROLLBACK_SKIP_VERSION_CHECK=1 \
    BAUDBOT_ROLLBACK_SKIP_CLI_LINK=1 \
    "$ROLLBACK_SCRIPT" previous
}

test_rollback_previous_switches_current() {
  (
    set -euo pipefail
    local tmp repo release_root sha1 sha2 current previous

    tmp="$(mktemp -d /tmp/baudbot-rollback-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    run_update "$repo" "$release_root"
    sha1="$(git -C "$repo" rev-parse HEAD)"

    new_commit "$repo" "second"
    run_update "$repo" "$release_root"
    sha2="$(git -C "$repo" rev-parse HEAD)"

    run_rollback "$release_root" previous

    current="$(readlink -f "$release_root/current")"
    previous="$(readlink -f "$release_root/previous")"

    [ "$current" = "$release_root/releases/$sha1" ]
    [ "$previous" = "$release_root/releases/$sha2" ]
  )
}

test_rollback_missing_release_fails_without_mutation() {
  (
    set -euo pipefail
    local tmp repo release_root before

    tmp="$(mktemp -d /tmp/baudbot-rollback-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    run_update "$repo" "$release_root"
    before="$(readlink -f "$release_root/current")"

    if run_rollback "$release_root" does-not-exist; then
      return 1
    fi

    [ "$(readlink -f "$release_root/current")" = "$before" ]
  )
}

test_rollback_deploy_failure_keeps_current() {
  (
    set -euo pipefail
    local tmp repo release_root before

    tmp="$(mktemp -d /tmp/baudbot-rollback-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"

    make_repo "$repo"
    run_update "$repo" "$release_root"

    new_commit "$repo" "third"
    run_update "$repo" "$release_root"

    before="$(readlink -f "$release_root/current")"

    if run_rollback "$release_root" previous false; then
      return 1
    fi

    [ "$(readlink -f "$release_root/current")" = "$before" ]
  )
}

test_rollback_release_root_overrides_stale_release_path_env() {
  (
    set -euo pipefail
    local tmp repo release_root stale_root sha1 sha2 current previous

    tmp="$(mktemp -d /tmp/baudbot-rollback-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    repo="$tmp/repo"
    release_root="$tmp/opt/baudbot"
    stale_root="$tmp/stale"

    mkdir -p "$stale_root/releases/fake-current" "$stale_root/releases/fake-previous"
    ln -s "$stale_root/releases/fake-current" "$stale_root/current"
    ln -s "$stale_root/releases/fake-previous" "$stale_root/previous"

    make_repo "$repo"
    run_update "$repo" "$release_root"
    sha1="$(git -C "$repo" rev-parse HEAD)"

    new_commit "$repo" "second"
    run_update "$repo" "$release_root"
    sha2="$(git -C "$repo" rev-parse HEAD)"

    run_rollback_with_stale_release_paths "$release_root" "$stale_root"

    current="$(readlink -f "$release_root/current")"
    previous="$(readlink -f "$release_root/previous")"

    [ "$current" = "$release_root/releases/$sha1" ]
    [ "$previous" = "$release_root/releases/$sha2" ]
  )
}

echo "=== rollback-release tests ==="
echo ""

run_test "rollback previous switches current" test_rollback_previous_switches_current
run_test "rollback missing release keeps current" test_rollback_missing_release_fails_without_mutation
run_test "rollback deploy failure keeps current" test_rollback_deploy_failure_keeps_current
run_test "rollback release-root overrides stale env" test_rollback_release_root_overrides_stale_release_path_env

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
