#!/usr/bin/env bash
# Gated inference smoke-test for baudbot.
#
# Verifies that the control-agent can complete at least one real LLM turn
# end-to-end via session-control RPC. Default OFF for PR CI; enabled by
# setting BAUDBOT_CI_INFERENCE_SMOKE=1.
#
# Optional fail-open mode: BAUDBOT_CI_INFERENCE_SMOKE_OPTIONAL=1 logs failure
# as a warning instead of failing the build (useful for non-nightly runs where
# flaky provider errors shouldn't block merges).
#
# Expects baudbot to be already installed and stoppable via `sudo baudbot`.

set -Eeuo pipefail

readonly AGENT_USER="baudbot_agent"
readonly AGENT_HOME="/home/${AGENT_USER}"
readonly AGENT_ENV="${AGENT_HOME}/.config/.env"
readonly CONTROL_DIR="${AGENT_HOME}/.pi/session-control"
readonly CONTROL_ALIAS="${CONTROL_DIR}/control-agent.alias"
readonly START_TIMEOUT_SECONDS=60
readonly INFERENCE_TIMEOUT_SECONDS=120
readonly EXPECTED_TOKEN="CI_INFERENCE_OK"

started=0

log() {
  printf '[inference-smoke] %s\n' "$*"
}

cleanup() {
  local exit_code=$?
  if [[ $started -eq 1 ]]; then
    log "cleanup: stopping baudbot"
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

dump_diagnostics() {
  log "--- diagnostics ---"
  sudo baudbot status 2>&1 || true
  log "--- end diagnostics ---"
}

# Send a message via session-control RPC and wait for turn_end.
# Prints the assistant response content on success, exits non-zero on failure.
rpc_send_wait_turn_end() {
  local socket_path="$1"
  local message="$2"
  local timeout_seconds="$3"

  sudo -u "$AGENT_USER" python3 - "$socket_path" "$message" "$timeout_seconds" <<'PY'
import json
import socket
import sys

sock_path = sys.argv[1]
message = sys.argv[2]
timeout_seconds = int(sys.argv[3])

send_cmd = {"type": "send", "message": message, "mode": "steer"}
subscribe_cmd = {"type": "subscribe", "event": "turn_end"}

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    client.settimeout(timeout_seconds)
    client.connect(sock_path)

    # Send both commands
    client.sendall((json.dumps(send_cmd) + "\n").encode("utf-8"))
    client.sendall((json.dumps(subscribe_cmd) + "\n").encode("utf-8"))

    buf = b""
    send_response = None

    while True:
        chunk = client.recv(8192)
        if not chunk:
            print("connection closed before turn_end", file=sys.stderr)
            sys.exit(1)
        buf += chunk

        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue

            try:
                msg = json.loads(line.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                continue

            if msg.get("type") == "response":
                cmd = msg.get("command", "")
                if cmd == "send":
                    if not msg.get("success", False):
                        print(f"send failed: {msg.get('error', 'unknown')}", file=sys.stderr)
                        sys.exit(1)
                    send_response = msg
                # Ignore subscribe response
                continue

            if msg.get("type") == "event" and msg.get("event") == "turn_end":
                if send_response is None:
                    print("received turn_end before send response", file=sys.stderr)
                    sys.exit(1)
                data = msg.get("data", {})
                assistant_msg = data.get("message", {})
                content = assistant_msg.get("content", "")
                if not content:
                    print("turn completed but no assistant content", file=sys.stderr)
                    sys.exit(1)
                print(content)
                sys.exit(0)

    print("stream ended without turn_end event", file=sys.stderr)
    sys.exit(1)
except socket.timeout:
    print("timeout waiting for inference response", file=sys.stderr)
    sys.exit(1)
finally:
    client.close()
PY
}

inject_api_key() {
  # If a real API key is available in the environment, inject it into the
  # agent's .env so the runtime can authenticate with the provider.
  if [[ -n "${CI_ANTHROPIC_API_KEY:-}" ]]; then
    log "injecting CI API key into agent .env"
    sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${CI_ANTHROPIC_API_KEY}|" "$AGENT_ENV"
  elif grep -q "ANTHROPIC_API_KEY=sk-ant-testkey" "$AGENT_ENV" 2>/dev/null; then
    log "WARNING: agent .env has dummy API key; inference will likely fail"
    log "  set CI_ANTHROPIC_API_KEY to provide a real key"
  fi
}

main() {
  inject_api_key

  log "starting baudbot"
  sudo baudbot start
  started=1

  log "waiting for control-agent socket"
  local socket_path=""
  if ! socket_path="$(wait_for_control_socket)"; then
    log "control-agent socket did not become ready within ${START_TIMEOUT_SECONDS}s"
    dump_diagnostics
    return 1
  fi
  log "control socket ready: ${socket_path}"

  log "sending inference prompt (timeout ${INFERENCE_TIMEOUT_SECONDS}s)"
  local response=""
  if ! response="$(rpc_send_wait_turn_end "$socket_path" \
    "Reply with exactly: ${EXPECTED_TOKEN}" \
    "$INFERENCE_TIMEOUT_SECONDS")"; then
    log "inference failed"
    dump_diagnostics
    return 1
  fi

  # Validate response contains expected token
  if [[ "$response" == *"$EXPECTED_TOKEN"* ]]; then
    log "inference response contains expected token"
  else
    log "unexpected response (missing '${EXPECTED_TOKEN}'):"
    log "  ${response:0:500}"
    dump_diagnostics
    return 1
  fi

  log "stopping baudbot"
  sudo baudbot stop
  started=0

  log "inference smoke passed"
}

main "$@"
