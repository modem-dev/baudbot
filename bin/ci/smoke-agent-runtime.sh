#!/usr/bin/env bash
# Runtime smoke-test for baudbot agent lifecycle in CI droplets.
#
# Verifies that:
#  - baudbot starts successfully
#  - control-agent session socket is created and reachable
#  - session-control RPC responds successfully
#  - bridge supervisor status artifact exists (if bridge was started by start.sh)
#  - process remains healthy for a short stabilization window
#  - baudbot stops cleanly

set -Eeuo pipefail

readonly AGENT_USER="baudbot_agent"
readonly AGENT_HOME="/home/${AGENT_USER}"
readonly CONTROL_DIR="${AGENT_HOME}/.pi/session-control"
readonly CONTROL_ALIAS="${CONTROL_DIR}/control-agent.alias"
readonly BRIDGE_STATUS_FILE="${AGENT_HOME}/.pi/agent/slack-bridge-supervisor.json"
readonly START_TIMEOUT_SECONDS=60
readonly STABILIZE_SECONDS=20

started=0

log() {
  printf '[runtime-smoke] %s\n' "$*"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    log "missing required command: ${cmd}"
    exit 2
  }
}

cleanup() {
  local exit_code=$?
  if [[ $started -eq 1 ]]; then
    log "cleanup: attempting to stop baudbot"
    sudo baudbot stop >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

wait_for_control_socket() {
  local deadline=$((SECONDS + START_TIMEOUT_SECONDS))
  local target=""

  while (( SECONDS < deadline )); do
    if [[ -L "$CONTROL_ALIAS" ]]; then
      target="$(readlink -- "$CONTROL_ALIAS" 2>/dev/null || true)"
      if [[ -n "$target" ]]; then
        if [[ "$target" != /* ]]; then
          target="${CONTROL_DIR}/${target}"
        fi
        if [[ -S "$target" ]]; then
          printf '%s\n' "$target"
          return 0
        fi
      fi
    fi
    sleep 1
  done

  return 1
}

probe_rpc_get_message() {
  local socket_path="$1"
  local attempts=8
  local delay_seconds=1

  for ((i = 1; i <= attempts; i++)); do
    if sudo -u "$AGENT_USER" python3 - "$socket_path" <<'PY'
import json
import socket
import sys

sock_path = sys.argv[1]
request = {"type": "get_message", "id": "ci-runtime-smoke"}

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    client.settimeout(4)
    client.connect(sock_path)
    client.sendall((json.dumps(request) + "\n").encode("utf-8"))

    buf = b""
    while b"\n" not in buf:
        chunk = client.recv(4096)
        if not chunk:
            break
        buf += chunk

    if not buf:
        print("empty rpc response", file=sys.stderr)
        sys.exit(1)

    line = buf.split(b"\n", 1)[0].decode("utf-8", errors="replace")
    response = json.loads(line)
    if not response.get("success", False):
        print(f"rpc reported failure: {response}", file=sys.stderr)
        sys.exit(1)

    print("rpc-ok")
finally:
    client.close()
PY
    then
      return 0
    fi

    log "rpc probe attempt ${i}/${attempts} failed; retrying in ${delay_seconds}s"
    sleep "$delay_seconds"
  done

  return 1
}

main() {
  require_cmd sudo
  require_cmd baudbot
  require_cmd python3

  log "starting baudbot"
  sudo baudbot start
  started=1

  log "waiting for control-agent socket"
  local socket_path=""
  if ! socket_path="$(wait_for_control_socket)"; then
    log "control-agent socket did not become ready within ${START_TIMEOUT_SECONDS}s"
    sudo baudbot status || true
    exit 1
  fi
  log "control socket ready: ${socket_path}"

  log "probing session-control RPC"
  probe_rpc_get_message "$socket_path"

  # Bridge is now started by startup-pi.sh (inside the agent), not by
  # start.sh. In CI the agent doesn't run long enough for startup-pi.sh
  # to execute, so the status file may not exist. Log but don't fail.
  log "checking bridge supervisor status file"
  if [[ -f "$BRIDGE_STATUS_FILE" ]]; then
    log "bridge supervisor status file exists"
  else
    log "bridge supervisor status file not found (expected — bridge starts inside agent)"
  fi

  log "stabilization window (${STABILIZE_SECONDS}s)"
  sleep "$STABILIZE_SECONDS"

  log "verifying runtime health via baudbot status"
  sudo baudbot status >/dev/null

  log "stopping baudbot"
  sudo baudbot stop
  started=0

  log "runtime smoke passed"
}

main "$@"
