#!/bin/bash
# Focused tests for bin/baudbot CLI dispatcher behavior.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO_ROOT/bin/baudbot"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-cli-test-output.XXXXXX)"
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

test_version_uses_package_json() {
  (
    set -euo pipefail
    local tmp out
    tmp="$(mktemp -d /tmp/baudbot-cli-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin"
    printf '{"version":"9.9.9"}\n' > "$tmp/package.json"

    out="$(BAUDBOT_ROOT="$tmp" bash "$CLI" version)"
    printf '%s\n' "$out" | grep -q '^baudbot 9\.9\.9'
  )
}

test_status_dispatches_via_runtime_module() {
  (
    set -euo pipefail
    local tmp out
    tmp="$(mktemp -d /tmp/baudbot-cli-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin/lib"
    printf '{"version":"1.2.3"}\n' > "$tmp/package.json"
    cat > "$tmp/bin/lib/baudbot-runtime.sh" <<'EOF'
#!/bin/bash
cmd_status() { echo "status-dispatch-ok"; }
cmd_logs() { echo "logs-dispatch-ok"; }
cmd_sessions() { echo "sessions-dispatch-ok"; }
cmd_attach() { echo "attach-dispatch-ok"; }
has_systemd() { return 1; }
EOF

    out="$(BAUDBOT_ROOT="$tmp" bash "$CLI" status)"
    [ "$out" = "status-dispatch-ok" ]
  )
}

test_attach_requires_root() {
  (
    set -euo pipefail
    local tmp fakebin out
    tmp="$(mktemp -d /tmp/baudbot-cli-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/fakebin"
    fakebin="$tmp/fakebin"
    cat > "$fakebin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
  echo 1000
elif [ "${1:-}" = "-un" ]; then
  echo tester
else
  /usr/bin/id "$@"
fi
EOF
    chmod +x "$fakebin/id"

    if PATH="$fakebin:$PATH" BAUDBOT_ROOT="$REPO_ROOT" bash "$CLI" attach >/tmp/baudbot-attach.out 2>&1; then
      return 1
    fi

    out="$(cat /tmp/baudbot-attach.out)"
    rm -f /tmp/baudbot-attach.out
    printf '%s\n' "$out" | grep -q "requires root"
  )
}

test_broker_register_requires_root() {
  (
    set -euo pipefail
    local tmp fakebin out
    tmp="$(mktemp -d /tmp/baudbot-cli-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/fakebin"
    fakebin="$tmp/fakebin"
    cat > "$fakebin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
  echo 1000
elif [ "${1:-}" = "-un" ]; then
  echo tester
else
  /usr/bin/id "$@"
fi
EOF
    chmod +x "$fakebin/id"

    if PATH="$fakebin:$PATH" BAUDBOT_ROOT="$REPO_ROOT" bash "$CLI" broker register >/tmp/baudbot-broker.out 2>&1; then
      return 1
    fi

    out="$(cat /tmp/baudbot-broker.out)"
    rm -f /tmp/baudbot-broker.out
    printf '%s\n' "$out" | grep -q "requires root"
  )
}

echo "=== baudbot cli tests ==="
echo ""

run_test "version reads package.json" test_version_uses_package_json
run_test "status dispatches via runtime module" test_status_dispatches_via_runtime_module
run_test "attach requires root" test_attach_requires_root
run_test "broker register requires root" test_broker_register_requires_root

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
