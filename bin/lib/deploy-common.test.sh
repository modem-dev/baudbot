#!/bin/bash
# Tests for bin/lib/deploy-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-deploy-common-test-output.XXXXXX)"
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

test_resolve_prefers_config_user() {
  (
    set -euo pipefail
    local tmp resolved
    tmp="$(mktemp -d /tmp/baudbot-deploy-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    export BAUDBOT_CONFIG_USER="config-user"
    export SUDO_USER="sudo-user"
    resolved="$(bb_resolve_deploy_user "$tmp")"

    [ "$resolved" = "config-user" ]
  )
}

test_resolve_prefers_sudo_user_when_non_root() {
  (
    set -euo pipefail
    local tmp resolved
    tmp="$(mktemp -d /tmp/baudbot-deploy-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    unset BAUDBOT_CONFIG_USER
    export SUDO_USER="ci-admin"
    resolved="$(bb_resolve_deploy_user "$tmp")"

    [ "$resolved" = "ci-admin" ]
  )
}

test_resolve_falls_back_to_owner_or_whoami() {
  (
    set -euo pipefail
    local tmp resolved expected
    tmp="$(mktemp -d /tmp/baudbot-deploy-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    unset BAUDBOT_CONFIG_USER
    unset SUDO_USER

    expected="$(whoami)"
    resolved="$(bb_resolve_deploy_user "$tmp")"
    [ "$resolved" = "$expected" ]

    # unreadable path fallback also returns whoami
    resolved="$(bb_resolve_deploy_user "$tmp/missing")"
    [ "$resolved" = "$expected" ]
  )
}

test_source_env_uses_render_script_when_present() {
  (
    set -euo pipefail
    local tmp render value
    tmp="$(mktemp -d /tmp/baudbot-deploy-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    render="$tmp/render-env.sh"
    cat > "$render" <<'EOF'
#!/bin/bash
if [ "$1" = "--get" ] && [ "$2" = "BAUDBOT_EXPERIMENTAL" ]; then
  echo "1"
else
  echo ""
fi
EOF
    chmod +x "$render"

    value="$(bb_source_env_value "$render" "/home/admin" "admin" "$tmp/.env" "BAUDBOT_EXPERIMENTAL")"
    [ "$value" = "1" ]
  )
}

test_source_env_falls_back_to_admin_config() {
  (
    set -euo pipefail
    local tmp admin_config value
    tmp="$(mktemp -d /tmp/baudbot-deploy-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    admin_config="$tmp/.env"
    cat > "$admin_config" <<'EOF'
FOO=one
BAUDBOT_EXPERIMENTAL=0
BAUDBOT_EXPERIMENTAL=1
EOF

    value="$(bb_source_env_value "$tmp/missing-render" "/home/admin" "admin" "$admin_config" "BAUDBOT_EXPERIMENTAL")"
    [ "$value" = "1" ]
  )
}

test_source_env_returns_empty_when_missing() {
  (
    set -euo pipefail
    local tmp value
    tmp="$(mktemp -d /tmp/baudbot-deploy-common-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    value="$(bb_source_env_value "$tmp/missing-render" "/home/admin" "admin" "$tmp/missing-env" "MISSING")"
    [ -z "$value" ]
  )
}

echo "=== deploy-common tests ==="
echo ""

run_test "resolve: BAUDBOT_CONFIG_USER wins" test_resolve_prefers_config_user
run_test "resolve: SUDO_USER wins when non-root" test_resolve_prefers_sudo_user_when_non_root
run_test "resolve: fallback to owner/whoami" test_resolve_falls_back_to_owner_or_whoami
run_test "source_env: render script preferred" test_source_env_uses_render_script_when_present
run_test "source_env: fallback to admin config" test_source_env_falls_back_to_admin_config
run_test "source_env: missing returns empty" test_source_env_returns_empty_when_missing

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
