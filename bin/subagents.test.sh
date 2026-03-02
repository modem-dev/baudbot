#!/bin/bash
# Tests for bin/subagents.sh lifecycle commands.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/subagents.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-subagents-test-output.XXXXXX)"
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

setup_fixture() {
  local tmp="$1"

  local agent_home="$tmp/agent-home"
  local fakebin="$tmp/fakebin"
  local subagent_dir="$agent_home/.pi/agent/subagents/sentry-agent"
  local control_dir="$agent_home/.pi/session-control"

  mkdir -p "$subagent_dir" "$control_dir" "$agent_home/.config" "$fakebin"

  cat > "$subagent_dir/subagent.json" <<'JSON'
{
  "id": "sentry-agent",
  "name": "Sentry Agent",
  "description": "Incident triage agent",
  "session_name": "sentry-agent",
  "cwd": "~",
  "skill_path": "SKILL.md",
  "model_profile": "cheap_tier",
  "ready_alias": "sentry-agent",
  "ready_timeout_sec": 2,
  "installed_by_default": true,
  "enabled_by_default": true,
  "autostart": false
}
JSON

  printf '# test skill\n' > "$subagent_dir/SKILL.md"
  printf 'OPENAI_API_KEY=test-key\n' > "$agent_home/.config/.env"

  cat > "$fakebin/id" <<'EOF_ID'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
  echo "${BAUDBOT_TEST_ID_U:-0}"
  exit 0
fi
if [ "${1:-}" = "-un" ]; then
  echo "${BAUDBOT_TEST_ID_UN:-tester}"
  exit 0
fi
exec /usr/bin/id "$@"
EOF_ID

  cat > "$fakebin/sudo" <<'EOF_SUDO'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-u" ]; then
  shift 2
fi
exec "$@"
EOF_SUDO

  cat > "$fakebin/tmux" <<'EOF_TMUX'
#!/bin/bash
set -euo pipefail
STATE_FILE="${BAUDBOT_TEST_TMUX_FILE:?missing BAUDBOT_TEST_TMUX_FILE}"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

extract_flag_value() {
  local flag="$1"
  shift
  local args=("$@")
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "$flag" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
      echo "${args[$((i + 1))]}"
      return 0
    fi
  done
  return 1
}

cmd="${1:-}"
shift || true

case "$cmd" in
  has-session)
    session="$(extract_flag_value "-t" "$@" || true)"
    if [ -n "$session" ] && grep -Fxq "$session" "$STATE_FILE"; then
      exit 0
    fi
    exit 1
    ;;
  new-session)
    session="$(extract_flag_value "-s" "$@" || true)"
    [ -n "$session" ] || exit 1
    if ! grep -Fxq "$session" "$STATE_FILE"; then
      echo "$session" >> "$STATE_FILE"
    fi
    exit 0
    ;;
  kill-session)
    session="$(extract_flag_value "-t" "$@" || true)"
    [ -n "$session" ] || exit 1
    if ! grep -Fxq "$session" "$STATE_FILE"; then
      exit 1
    fi
    grep -Fxv "$session" "$STATE_FILE" > "$STATE_FILE.tmp" || true
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF_TMUX

  chmod +x "$fakebin/id" "$fakebin/sudo" "$fakebin/tmux"

  echo "$agent_home"
}

start_unix_socket() {
  local socket_path="$1"
  python3 - "$socket_path" <<'PY' &
import os
import socket
import sys
import time

sock_path = sys.argv[1]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)

end = time.time() + 10
while time.time() < end:
    server.settimeout(1)
    try:
        client, _ = server.accept()
        client.close()
    except Exception:
        pass

server.close()
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
PY
  echo $!
}

test_requires_root() {
  (
    set -euo pipefail
    local tmp agent_home fakebin real_user
    tmp="$(mktemp -d /tmp/baudbot-subagents-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    agent_home="$(setup_fixture "$tmp")"
    fakebin="$tmp/fakebin"
    real_user="$(/usr/bin/id -un)"

    export PATH="$fakebin:$PATH"
    export BAUDBOT_TEST_ID_U="1000"
    export BAUDBOT_AGENT_USER="$real_user"
    export BAUDBOT_AGENT_HOME="$agent_home"
    export BAUDBOT_TEST_TMUX_FILE="$tmp/tmux-sessions"

    if bash "$SCRIPT" list >/tmp/baudbot-subagents-root.out 2>&1; then
      rm -f /tmp/baudbot-subagents-root.out
      return 1
    fi

    grep -q "requires root" /tmp/baudbot-subagents-root.out
    rm -f /tmp/baudbot-subagents-root.out
  )
}

test_list_and_state_toggles() {
  (
    set -euo pipefail
    local tmp agent_home fakebin real_user
    tmp="$(mktemp -d /tmp/baudbot-subagents-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    agent_home="$(setup_fixture "$tmp")"
    fakebin="$tmp/fakebin"
    real_user="$(/usr/bin/id -un)"

    export PATH="$fakebin:$PATH"
    export BAUDBOT_TEST_ID_U="0"
    export BAUDBOT_AGENT_USER="$real_user"
    export BAUDBOT_AGENT_HOME="$agent_home"
    export BAUDBOT_TEST_TMUX_FILE="$tmp/tmux-sessions"

    local list_out
    list_out="$(bash "$SCRIPT" list)"
    echo "$list_out" | grep -q "sentry-agent"

    bash "$SCRIPT" install sentry-agent >/dev/null
    bash "$SCRIPT" enable sentry-agent >/dev/null
    bash "$SCRIPT" autostart-on sentry-agent >/dev/null

    jq -e '.agents["sentry-agent"].installed == true' "$agent_home/.pi/agent/subagents-state.json" >/dev/null
    jq -e '.agents["sentry-agent"].enabled == true' "$agent_home/.pi/agent/subagents-state.json" >/dev/null
    jq -e '.agents["sentry-agent"].autostart == true' "$agent_home/.pi/agent/subagents-state.json" >/dev/null

    bash "$SCRIPT" autostart-off sentry-agent >/dev/null
    jq -e '.agents["sentry-agent"].autostart == false' "$agent_home/.pi/agent/subagents-state.json" >/dev/null
  )
}

test_reconcile_status_stop() {
  (
    set -euo pipefail
    local tmp agent_home fakebin control_dir socket_path alias_path sock_pid real_user
    tmp="$(mktemp -d /tmp/baudbot-subagents-test.XXXXXX)"
    trap 'kill "$sock_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

    agent_home="$(setup_fixture "$tmp")"
    fakebin="$tmp/fakebin"
    real_user="$(/usr/bin/id -un)"
    control_dir="$agent_home/.pi/session-control"
    socket_path="$control_dir/sentry-agent.sock"
    alias_path="$control_dir/sentry-agent.alias"

    export PATH="$fakebin:$PATH"
    export BAUDBOT_TEST_ID_U="0"
    export BAUDBOT_AGENT_USER="$real_user"
    export BAUDBOT_AGENT_HOME="$agent_home"
    export BAUDBOT_TEST_TMUX_FILE="$tmp/tmux-sessions"

    sock_pid="$(start_unix_socket "$socket_path")"
    for _i in $(seq 1 20); do
      [ -S "$socket_path" ] && break
      sleep 0.1
    done
    ln -sf "$(basename "$socket_path")" "$alias_path"

    bash "$SCRIPT" autostart-on sentry-agent >/dev/null

    local reconcile_out
    reconcile_out="$(bash "$SCRIPT" reconcile)"
    echo "$reconcile_out" | grep -q "started sentry-agent"

    local status_out
    status_out="$(bash "$SCRIPT" status sentry-agent)"
    echo "$status_out" | grep -q "running"
    echo "$status_out" | grep -q "sentry-agent.alias"

    bash "$SCRIPT" stop sentry-agent >/dev/null

    if grep -Fxq "sentry-agent" "$tmp/tmux-sessions"; then
      return 1
    fi
  )
}

test_start_rejects_injected_cwd() {
  (
    set -euo pipefail
    local tmp agent_home fakebin real_user marker manifest output_file
    tmp="$(mktemp -d /tmp/baudbot-subagents-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    agent_home="$(setup_fixture "$tmp")"
    fakebin="$tmp/fakebin"
    real_user="$(/usr/bin/id -un)"
    marker="$tmp/injected-marker"
    manifest="$agent_home/.pi/agent/subagents/sentry-agent/subagent.json"
    output_file="$tmp/start.out"

    jq --arg cwd "~'; touch $marker; echo '" '.cwd = $cwd' "$manifest" > "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"

    export PATH="$fakebin:$PATH"
    export BAUDBOT_TEST_ID_U="0"
    export BAUDBOT_AGENT_USER="$real_user"
    export BAUDBOT_AGENT_HOME="$agent_home"
    export BAUDBOT_TEST_TMUX_FILE="$tmp/tmux-sessions"

    if bash "$SCRIPT" start sentry-agent >"$output_file" 2>&1; then
      return 1
    fi

    grep -q "cwd does not exist" "$output_file"
    [ ! -f "$marker" ]
  )
}

test_start_handles_single_quote_path() {
  (
    set -euo pipefail
    local tmp agent_home fakebin control_dir socket_path alias_path sock_pid real_user manifest quoted_cwd output_file
    tmp="$(mktemp -d /tmp/baudbot-subagents-test.XXXXXX)"
    trap 'kill "$sock_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

    agent_home="$(setup_fixture "$tmp")"
    fakebin="$tmp/fakebin"
    real_user="$(/usr/bin/id -un)"
    control_dir="$agent_home/.pi/session-control"
    socket_path="$control_dir/sentry-agent.sock"
    alias_path="$control_dir/sentry-agent.alias"
    manifest="$agent_home/.pi/agent/subagents/sentry-agent/subagent.json"
    quoted_cwd="$tmp/cwd-with-quote's"
    output_file="$tmp/start.out"

    mkdir -p "$quoted_cwd"
    jq --arg cwd "$quoted_cwd" '.cwd = $cwd' "$manifest" > "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"

    sock_pid="$(start_unix_socket "$socket_path")"
    for _i in $(seq 1 20); do
      [ -S "$socket_path" ] && break
      sleep 0.1
    done
    ln -sf "$(basename "$socket_path")" "$alias_path"

    export PATH="$fakebin:$PATH"
    export BAUDBOT_TEST_ID_U="0"
    export BAUDBOT_AGENT_USER="$real_user"
    export BAUDBOT_AGENT_HOME="$agent_home"
    export BAUDBOT_TEST_TMUX_FILE="$tmp/tmux-sessions"

    bash "$SCRIPT" start sentry-agent >"$output_file" 2>&1
    grep -q "started sentry-agent" "$output_file"
  )
}

echo "=== subagents cli tests ==="
echo ""

run_test "requires root guard" test_requires_root
run_test "list/install/enable/autostart state" test_list_and_state_toggles
run_test "reconcile/status/stop lifecycle" test_reconcile_status_stop
run_test "start rejects injected cwd payload" test_start_rejects_injected_cwd
run_test "start handles single-quote cwd path" test_start_handles_single_quote_path

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
