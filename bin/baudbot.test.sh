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

test_restart_restarts_systemd_and_kills_bridge_tmux() {
  (
    set -euo pipefail
    local tmp fakebin log_file
    tmp="$(mktemp -d /tmp/baudbot-cli-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/fakebin" "$tmp/bin/lib"
    fakebin="$tmp/fakebin"
    log_file="$tmp/calls.log"

    printf '{"version":"1.2.3"}\n' > "$tmp/package.json"
    cat > "$tmp/bin/lib/baudbot-runtime.sh" <<'EOF'
#!/bin/bash
has_systemd() { return 0; }
cmd_status() { :; }
cmd_logs() { :; }
cmd_sessions() { :; }
cmd_attach() { :; }
EOF

    cat > "$fakebin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
  echo 0
else
  /usr/bin/id "$@"
fi
EOF

    cat > "$fakebin/sudo" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
  user="$2"
  shift 2
fi
echo "sudo $*" >> "${BAUDBOT_TEST_LOG}"
exec "$@"
EOF

    cat > "$fakebin/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "${BAUDBOT_TEST_LOG}"
exit 0
EOF

    cat > "$fakebin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "${BAUDBOT_TEST_LOG}"
exit 0
EOF

    chmod +x "$fakebin/id" "$fakebin/sudo" "$fakebin/tmux" "$fakebin/systemctl"

    PATH="$fakebin:$PATH" BAUDBOT_TEST_LOG="$log_file" BAUDBOT_ROOT="$tmp" bash "$CLI" restart

    grep -q '^tmux kill-session -t slack-bridge$' "$log_file"
    grep -q '^systemctl restart baudbot$' "$log_file"
  )
}

test_remote_dispatches_to_remote_script() {
  (
    set -euo pipefail
    local tmp out
    tmp="$(mktemp -d /tmp/baudbot-cli-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin/lib"
    printf '{"version":"1.2.3"}\n' > "$tmp/package.json"
    cat > "$tmp/bin/lib/baudbot-runtime.sh" <<'EOF'
#!/bin/bash
cmd_status() { :; }
cmd_logs() { :; }
cmd_sessions() { :; }
cmd_attach() { :; }
has_systemd() { return 0; }
EOF

    cat > "$tmp/bin/remote.sh" <<'EOF'
#!/bin/bash
echo "remote-dispatch-ok:$*"
EOF
    chmod +x "$tmp/bin/remote.sh"

    out="$(BAUDBOT_ROOT="$tmp" bash "$CLI" remote list)"
    [ "$out" = "remote-dispatch-ok:list" ]
  )
}

echo "=== baudbot cli tests ==="
echo ""

run_test "version reads package.json" test_version_uses_package_json
run_test "status dispatches via runtime module" test_status_dispatches_via_runtime_module
run_test "attach requires root" test_attach_requires_root
run_test "broker register requires root" test_broker_register_requires_root
run_test "restart kills bridge tmux then restarts systemd" test_restart_restarts_systemd_and_kills_bridge_tmux
run_test "remote command dispatches to remote.sh" test_remote_dispatches_to_remote_script

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
