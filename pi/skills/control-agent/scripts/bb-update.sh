#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bb-update.sh "message text"

Environment (optional):
  BB_SESSION_ID        Current session UUID for sender_info
  BB_SESSION_NAME      Current session alias for sender_info
  BB_CONTROL_SESSION   Target control session alias (default: control-agent)
  BB_CONTROL_SOCKET    Target socket path override
  BB_CONTROL_DIR       Session-control directory (default: ~/.pi/session-control)
  BB_MODE              RPC send mode (default: follow_up)
USAGE
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

MESSAGE="$*"
MODE="${BB_MODE:-follow_up}"
CONTROL_SESSION="${BB_CONTROL_SESSION:-control-agent}"
CONTROL_DIR="${BB_CONTROL_DIR:-$HOME/.pi/session-control}"
SESSION_ID="${BB_SESSION_ID:-}"
SESSION_NAME="${BB_SESSION_NAME:-}"

resolve_socket() {
  if [ -n "${BB_CONTROL_SOCKET:-}" ] && [ -S "${BB_CONTROL_SOCKET}" ]; then
    printf '%s\n' "$BB_CONTROL_SOCKET"
    return 0
  fi

  local alias_path="$CONTROL_DIR/$CONTROL_SESSION.alias"
  if [ -L "$alias_path" ]; then
    local target
    target="$(readlink "$alias_path")"
    if [[ "$target" != /* ]]; then
      target="$CONTROL_DIR/$target"
    fi
    if [ -S "$target" ]; then
      printf '%s\n' "$target"
      return 0
    fi
  fi

  local direct_path="$CONTROL_DIR/$CONTROL_SESSION.sock"
  if [ -S "$direct_path" ]; then
    printf '%s\n' "$direct_path"
    return 0
  fi

  return 1
}

SOCKET_PATH="$(resolve_socket || true)"
if [ -z "$SOCKET_PATH" ]; then
  printf '%s\n' "bb-update: unable to resolve control socket for session '$CONTROL_SESSION'" >&2
  exit 1
fi

build_payload() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MESSAGE" "$MODE" "$SESSION_ID" "$SESSION_NAME" <<'PY'
import json
import sys

message = sys.argv[1]
mode = sys.argv[2]
session_id = sys.argv[3]
session_name = sys.argv[4]

sender = {}
if session_id:
    sender["sessionId"] = session_id
if session_name:
    sender["sessionName"] = session_name

suffix = ""
if sender:
    suffix = "\n\n<sender_info>" + json.dumps(sender, separators=(",", ":")) + "</sender_info>"

payload = {
    "type": "send",
    "message": message + suffix,
    "mode": mode,
}

print(json.dumps(payload, separators=(",", ":")))
PY
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    node -e '
const message = process.argv[1];
const mode = process.argv[2];
const sessionId = process.argv[3];
const sessionName = process.argv[4];
const sender = {};
if (sessionId) sender.sessionId = sessionId;
if (sessionName) sender.sessionName = sessionName;
const suffix = Object.keys(sender).length > 0
  ? "\n\n<sender_info>" + JSON.stringify(sender) + "</sender_info>"
  : "";
const payload = { type: "send", message: message + suffix, mode };
process.stdout.write(JSON.stringify(payload));
' "$MESSAGE" "$MODE" "$SESSION_ID" "$SESSION_NAME"
    return 0
  fi

  printf '%s\n' "bb-update: python3 or node is required to build payload" >&2
  return 1
}

PAYLOAD="$(build_payload)"

send_with_python() {
  python3 - "$SOCKET_PATH" "$PAYLOAD" <<'PY'
import json
import socket
import sys

sock_path = sys.argv[1]
payload = sys.argv[2] + "\n"

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sock_path)
sock.sendall(payload.encode("utf-8"))
response = b""
while b"\n" not in response:
    chunk = sock.recv(4096)
    if not chunk:
        break
    response += chunk
sock.close()

if not response:
    print("bb-update: no RPC response from control socket", file=sys.stderr)
    sys.exit(1)

line = response.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
if not line:
    print("bb-update: empty RPC response from control socket", file=sys.stderr)
    sys.exit(1)

try:
    parsed = json.loads(line)
except Exception as error:
    print(f"bb-update: invalid RPC response: {error}", file=sys.stderr)
    sys.exit(1)

if parsed.get("type") != "response":
    print("bb-update: unexpected RPC response type", file=sys.stderr)
    sys.exit(1)

if not parsed.get("success"):
    err = parsed.get("error") or "unknown error"
    print(f"bb-update: control-agent rejected update: {err}", file=sys.stderr)
    sys.exit(1)
PY
}

send_with_node() {
  node -e '
const net = require("node:net");
const socketPath = process.argv[1];
const payload = process.argv[2] + "\n";
const client = net.createConnection(socketPath, () => {
  client.write(payload);
});
client.setEncoding("utf8");
client.setTimeout(5000, () => {
  console.error("bb-update: timeout waiting for RPC response");
  client.destroy();
  process.exit(1);
});
let buffer = "";
client.on("data", (chunk) => {
  buffer += chunk;
  const newlineIdx = buffer.indexOf("\n");
  if (newlineIdx === -1) return;
  const line = buffer.slice(0, newlineIdx).trim();
  client.end();
  if (!line) {
    console.error("bb-update: empty RPC response from control socket");
    process.exit(1);
  }
  let parsed;
  try {
    parsed = JSON.parse(line);
  } catch (error) {
    console.error("bb-update: invalid RPC response: " + error.message);
    process.exit(1);
  }
  if (parsed.type !== "response") {
    console.error("bb-update: unexpected RPC response type");
    process.exit(1);
  }
  if (!parsed.success) {
    console.error("bb-update: control-agent rejected update: " + (parsed.error || "unknown error"));
    process.exit(1);
  }
  process.exit(0);
});
client.on("error", (error) => {
  console.error(error.message);
  process.exit(1);
});
client.on("end", () => {
  if (!buffer.includes("\n")) {
    console.error("bb-update: no RPC response from control socket");
    process.exit(1);
  }
});
' "$SOCKET_PATH" "$PAYLOAD"
}

if command -v python3 >/dev/null 2>&1; then
  send_with_python
  exit 0
fi

if command -v node >/dev/null 2>&1; then
  send_with_node
  exit 0
fi

printf '%s\n' "bb-update: no supported socket client available (python3/node)" >&2
exit 1
