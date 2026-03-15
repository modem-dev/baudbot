#!/usr/bin/env bash
# Inference smoke-test for baudbot.
#
# Verifies that the control-agent can complete at least one real LLM turn
# end-to-end via session-control RPC.
#
# Requires CI_ANTHROPIC_API_KEY in the environment (injected into the
# agent's .env before starting baudbot).
#
# Expects baudbot to be already installed and stoppable via `sudo baudbot`.

set -Eeuo pipefail

readonly AGENT_USER="baudbot_agent"
readonly AGENT_HOME="/home/${AGENT_USER}"
readonly AGENT_ENV="${AGENT_HOME}/.config/.env"
readonly CONTROL_DIR="${AGENT_HOME}/.pi/session-control"
readonly CONTROL_ALIAS="${CONTROL_DIR}/control-agent.alias"
readonly START_TIMEOUT_SECONDS=60
readonly INFERENCE_TIMEOUT_SECONDS=300
# We ask the agent to run a health check and respond with structured JSON.
# A successful inference proves: socket → RPC → model API → tool use → response.
# We parse the JSON and validate the health fields.

started=0

log() {
  printf '[inference-smoke] %s\n' "$*"
}

journal_pid=""

cleanup() {
  local exit_code=$?
  [[ -n "$journal_pid" ]] && kill "$journal_pid" 2>/dev/null || true
  if [[ $started -eq 1 ]]; then
    log "cleanup: stopping baudbot"
    sudo baudbot stop >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

socket_is_connectable() {
  local sock="$1"
  sudo -u "$AGENT_USER" python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(2)
    s.connect(sys.argv[1])
    s.close()
except Exception:
    sys.exit(1)
" "$sock" 2>/dev/null
}

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
        if [[ -S "$target" ]] && socket_is_connectable "$target"; then
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

# Send a follow-up message and wait for a turn_end whose response contains
# a marker string. This handles the agent's multi-turn startup gracefully:
# the message is queued after the current turn, and we keep consuming
# turn_end events until we find one with our expected content.
rpc_send_and_wait_for_marker() {
  local socket_path="$1"
  local message="$2"
  local marker="$3"
  local timeout_seconds="$4"

  sudo -u "$AGENT_USER" python3 - "$socket_path" "$message" "$marker" "$timeout_seconds" <<'PY'
import json
import socket
import sys
import re

sock_path = sys.argv[1]
message = sys.argv[2]
marker = sys.argv[3]
timeout_seconds = int(sys.argv[4])

send_cmd = {"type": "send", "message": message, "mode": "follow_up"}
subscribe_cmd = {"type": "subscribe", "event": "turn_end"}

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    client.settimeout(timeout_seconds)
    client.connect(sock_path)

    client.sendall((json.dumps(send_cmd) + "\n").encode("utf-8"))
    client.sendall((json.dumps(subscribe_cmd) + "\n").encode("utf-8"))

    buf = b""
    send_ack = False

    while True:
        chunk = client.recv(8192)
        if not chunk:
            print("connection closed", file=sys.stderr)
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

            if msg.get("type") == "response" and msg.get("command") == "send":
                if not msg.get("success", False):
                    print(f"send failed: {msg.get('error', 'unknown')}", file=sys.stderr)
                    sys.exit(1)
                send_ack = True
                # turn_end subscriptions are one-shot; re-subscribe so we
                # keep receiving events across multiple startup turns.
                client.sendall((json.dumps(subscribe_cmd) + "\n").encode("utf-8"))
                continue

            if msg.get("type") == "event" and msg.get("event") == "turn_end":
                data = msg.get("data", {})
                content = (data.get("message") or {}).get("content", "")
                if marker in content:
                    # This is the turn that answered our prompt
                    print(content)
                    sys.exit(0)
                # Not our turn — re-subscribe for the next one
                client.sendall((json.dumps(subscribe_cmd) + "\n").encode("utf-8"))
                continue

except socket.timeout:
    print("timeout waiting for inference response", file=sys.stderr)
    sys.exit(1)
finally:
    client.close()
PY
}

readonly CI_MODEL="anthropic/claude-haiku-4-5"

inject_ci_config() {
  if [[ -z "${CI_ANTHROPIC_API_KEY:-}" ]]; then
    log "ERROR: CI_ANTHROPIC_API_KEY is not set"
    return 1
  fi
  log "injecting CI API key and model override into agent .env"
  # Run as the agent user to preserve file ownership and permissions (600).
  sudo -u "$AGENT_USER" sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${CI_ANTHROPIC_API_KEY}|" "$AGENT_ENV"
  # Use a cheap model for the smoke test — no need to burn Sonnet/Opus tokens.
  if grep -q "^BAUDBOT_MODEL=" "$AGENT_ENV" 2>/dev/null; then
    sudo -u "$AGENT_USER" sed -i "s|^BAUDBOT_MODEL=.*|BAUDBOT_MODEL=${CI_MODEL}|" "$AGENT_ENV"
  else
    sudo -u "$AGENT_USER" bash -c "echo 'BAUDBOT_MODEL=${CI_MODEL}' >> '${AGENT_ENV}'"
  fi
}

main() {
  inject_ci_config

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

  # Unique marker so we can identify our response among startup turns.
  local marker="CI_HEALTH_CHECK_RESPONSE"

  local prompt
  prompt=$(cat <<PROMPT
Run a quick health check: verify your session is live and check heartbeat status.
Then respond with ONLY a JSON object (no markdown fences, no other text) matching this schema.
You MUST include the marker field exactly as shown.

{
  "marker": "${marker}",
  "status": "healthy" | "degraded" | "unhealthy",
  "session_alive": true | false,
  "heartbeat_active": true | false,
  "message": "<one-line summary>"
}
PROMPT
)

  # Stream agent logs in the background so CI output shows what the agent is doing.
  sudo journalctl -u baudbot -f --no-pager -o cat &
  journal_pid=$!

  # Send the health check as a follow-up (queued after the current turn).
  # The agent may be mid-startup, so we keep consuming turn_end events
  # until we find the one containing our marker.
  log "sending health check prompt (timeout ${INFERENCE_TIMEOUT_SECONDS}s)"
  local response=""
  if ! response="$(rpc_send_and_wait_for_marker "$socket_path" \
    "$prompt" \
    "$marker" \
    "$INFERENCE_TIMEOUT_SECONDS")"; then
    log "inference failed — no response from model"
    dump_diagnostics
    return 1
  fi

  log "raw response: ${response:0:500}"

  # Extract JSON object from response (skip any surrounding text)
  local json=""
  json="$(echo "$response" | python3 -c "
import json, sys, re
text = sys.stdin.read()
# Try to find a JSON object in the text
match = re.search(r'\{[^{}]*\}', text, re.DOTALL)
if not match:
    print('NO_JSON', end='')
    sys.exit(0)
try:
    obj = json.loads(match.group())
    print(json.dumps(obj), end='')
except json.JSONDecodeError:
    print('INVALID_JSON', end='')
")"

  if [[ "$json" == "NO_JSON" ]]; then
    log "health check failed — no JSON object in response"
    dump_diagnostics
    return 1
  fi
  if [[ "$json" == "INVALID_JSON" ]]; then
    log "health check failed — malformed JSON in response"
    dump_diagnostics
    return 1
  fi

  # Validate fields
  local valid=""
  valid="$(echo "$json" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
errors = []
status = obj.get('status')
if status not in ('healthy', 'degraded', 'unhealthy'):
    errors.append(f'bad status: {status}')
if not isinstance(obj.get('session_alive'), bool):
    errors.append('missing/invalid session_alive')
if not isinstance(obj.get('heartbeat_active'), bool):
    errors.append('missing/invalid heartbeat_active')
if errors:
    print('FAIL:' + '; '.join(errors), end='')
else:
    print(json.dumps(obj), end='')
")"

  if [[ "$valid" == FAIL:* ]]; then
    log "health check failed — schema validation: ${valid#FAIL:}"
    dump_diagnostics
    return 1
  fi

  # Check actual health values
  local status session_alive heartbeat_active message
  status="$(echo "$valid" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")"
  session_alive="$(echo "$valid" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_alive'])")"
  heartbeat_active="$(echo "$valid" | python3 -c "import json,sys; print(json.load(sys.stdin)['heartbeat_active'])")"
  message="$(echo "$valid" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',''))")"

  log "status=$status session_alive=$session_alive heartbeat_active=$heartbeat_active"
  log "message: $message"

  # In CI the Gateway bridge has dummy tokens, so the agent correctly reports
  # "degraded" (bridge auth failure). Both "healthy" and "degraded" are
  # acceptable — "unhealthy" means core inference/session is broken.
  if [[ "$status" == "unhealthy" ]]; then
    log "agent reports unhealthy — core runtime failure"
    dump_diagnostics
    return 1
  fi
  if [[ "$session_alive" != "True" ]]; then
    log "agent reports session not alive"
    dump_diagnostics
    return 1
  fi

  log "health check passed"

  log "stopping baudbot"
  sudo baudbot stop
  started=0

  log "inference smoke passed"
}

main "$@"
