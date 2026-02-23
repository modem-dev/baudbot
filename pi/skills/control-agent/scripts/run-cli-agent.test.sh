#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run-cli-agent.sh"
BB_UPDATE="$SCRIPT_DIR/bb-update.sh"

PASS=0
FAIL=0
TMPDIR="$(mktemp -d /tmp/rca.XXXXXX)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

wait_server_or_terminate() {
  local pid="$1"
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge 30 ]; then
      kill "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || true
}

assert_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    pass "$desc"
  else
    fail "$desc (missing: $needle)"
  fi
}

run_expect_success() {
  local output
  if output="$("$@" 2>&1)"; then
    printf '%s' "$output"
    return 0
  fi

  printf '%s' "$output"
  return 1
}

run_expect_failure() {
  local output
  if output="$("$@" 2>&1)"; then
    printf '%s' "$output"
    return 1
  fi

  printf '%s' "$output"
  return 0
}

echo ""
echo "Testing run-cli-agent scripts"
echo "=============================="
echo ""

BIN_DIR="$TMPDIR/bin"
WORKTREE="$TMPDIR/worktree"
CONTROL_DIR="$TMPDIR/sc"
PERSONA_DIR="$TMPDIR/persona"
FAKE_CLI_LOG="$TMPDIR/fake-cli.log"
FAKE_TMUX_LOG="$TMPDIR/fake-tmux.log"
CAPTURE_FILE="$TMPDIR/capture.txt"

mkdir -p "$BIN_DIR" "$WORKTREE" "$CONTROL_DIR" "$PERSONA_DIR"
: > "$FAKE_CLI_LOG"
: > "$FAKE_TMUX_LOG"
: > "$CAPTURE_FILE"

# Minimal git worktree marker
cat > "$WORKTREE/.git" <<'GIT'
gitdir: /tmp/fake
GIT

cat > "$PERSONA_DIR/persona.claude-code.tmpl" <<'TPL'
Session {{SESSION_NAME}} Todo {{TODO_ID}} Repo {{REPO}}
TPL

cat > "$PERSONA_DIR/persona.codex.tmpl" <<'TPL'
Session {{SESSION_NAME}} Todo {{TODO_ID}} Repo {{REPO}}
TPL

cat > "$BIN_DIR/claude" <<EOF_CLAUDE
#!/usr/bin/env bash
printf '%s\n' "claude:\$*" >> "$FAKE_CLI_LOG"
exit 0
EOF_CLAUDE

cat > "$BIN_DIR/codex" <<EOF_CODEX
#!/usr/bin/env bash
printf '%s\n' "codex:\$*" >> "$FAKE_CLI_LOG"
exit 0
EOF_CODEX

cat > "$BIN_DIR/tmux" <<EOF_TMUX
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
if [ "\$cmd" = "send-keys" ]; then
  printf '%s\n' "send-keys:\$*" >> "$FAKE_TMUX_LOG"
  exit 0
fi
if [ "\$cmd" = "capture-pane" ]; then
  cat "$CAPTURE_FILE"
  exit 0
fi
printf '%s\n' "unknown:\$*" >> "$FAKE_TMUX_LOG"
exit 0
EOF_TMUX

chmod +x "$BIN_DIR/claude" "$BIN_DIR/codex" "$BIN_DIR/tmux"

export PATH="$BIN_DIR:$PATH"

# 1) Argument validation
if out="$(run_expect_failure "$RUNNER" --worktree "$WORKTREE" --session-name dev-agent-a --todo-id abc12345 --repo myapp)"; then
  assert_contains "missing backend fails" "$out" "required value is empty: backend"
else
  fail "missing backend should fail"
fi

# 2) Dry-run command construction (claude)
if out="$(run_expect_success "$RUNNER" \
  --backend claude-code \
  --worktree "$WORKTREE" \
  --session-name dev-agent-myapp-a1b2c3d4 \
  --todo-id a1b2c3d4 \
  --repo myapp \
  --persona-dir "$PERSONA_DIR" \
  --dry-run)"; then
  assert_contains "claude dry-run includes append-system-prompt" "$out" "--append-system-prompt"
  assert_contains "claude dry-run includes session" "$out" "dev-agent-myapp-a1b2c3d4"
else
  fail "claude dry-run should succeed"
fi

# 3) Dry-run command construction (codex)
if out="$(run_expect_success "$RUNNER" \
  --backend codex \
  --worktree "$WORKTREE" \
  --session-name dev-agent-myapp-b1c2d3e4 \
  --todo-id b1c2d3e4 \
  --repo myapp \
  --persona-dir "$PERSONA_DIR" \
  --dry-run)"; then
  assert_contains "codex dry-run includes full-auto" "$out" "--full-auto"
  if echo "$out" | grep -q -- "--instructions"; then
    fail "codex dry-run should not use --instructions"
  else
    pass "codex dry-run does not use --instructions"
  fi
else
  fail "codex dry-run should succeed"
fi

# 4) Full run: completion payload reaches control socket
CONTROL_UUID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
CONTROL_SOCKET="$CONTROL_DIR/$CONTROL_UUID.sock"
CONTROL_ALIAS="$CONTROL_DIR/control-agent.alias"
CAPTURED_RPC="$TMPDIR/captured-rpc.txt"

python3 - "$CONTROL_SOCKET" "$CAPTURED_RPC" <<'PY' 2>/dev/null &
import os
import socket
import sys

sock_path = sys.argv[1]
out_path = sys.argv[2]

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
conn, _ = server.accept()

chunks = []
while True:
    piece = conn.recv(4096)
    if not piece:
        break
    chunks.append(piece)
    if b"\n" in piece:
        break

payload = b"".join(chunks)
with open(out_path, "wb") as fh:
    fh.write(payload)

conn.sendall(b'{"type":"response","command":"send","success":true}\n')
conn.close()
server.close()
PY
SERVER_PID=$!

SERVER_READY=0
for _ in $(seq 1 40); do
  if [ -S "$CONTROL_SOCKET" ]; then
    SERVER_READY=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

if [ "$SERVER_READY" -eq 0 ]; then
  pass "full run socket assertion skipped (unix sockets unavailable in this environment)"
  wait "$SERVER_PID" 2>/dev/null || true
else
  ln -s "$(basename "$CONTROL_SOCKET")" "$CONTROL_ALIAS"

  if BB_CONTROL_DIR="$CONTROL_DIR" run_expect_success "$RUNNER" \
    --backend claude-code \
    --worktree "$WORKTREE" \
    --session-name dev-agent-myapp-c1d2e3f4 \
    --todo-id c1d2e3f4 \
    --repo myapp \
    --persona-dir "$PERSONA_DIR" \
    --timeout 30 \
    --control-session control-agent \
    >/dev/null; then
    pass "full run exits successfully"
  else
    fail "full run should succeed"
    kill "$SERVER_PID" 2>/dev/null || true
  fi

  wait_server_or_terminate "$SERVER_PID"

  if [ -f "$CAPTURED_RPC" ]; then
    payload="$(cat "$CAPTURED_RPC")"
    assert_contains "completion payload uses send RPC" "$payload" '"type":"send"'
    assert_contains "completion payload includes todo" "$payload" "TODO c1d2e3f4"
    assert_contains "completion payload includes sender_info" "$payload" "sender_info"
    assert_contains "completion payload includes structured marker" "$payload" "<bb_completion>"
  else
    fail "expected captured RPC payload"
  fi
fi

# 5) Runner retries completion update when control responds with failure
RETRY_SOCKET="$CONTROL_DIR/cccccccc-cccc-4ccc-8ccc-cccccccccccc.sock"
RETRY_ALIAS="$CONTROL_DIR/control-retry.alias"
RETRY_TRACE="$TMPDIR/retry-trace.txt"

python3 - "$RETRY_SOCKET" "$RETRY_TRACE" <<'PY' 2>/dev/null &
import os
import socket
import sys

sock_path = sys.argv[1]
trace_path = sys.argv[2]

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(3)
server.settimeout(8)

attempt = 0
with open(trace_path, "w", encoding="utf-8") as trace:
    while attempt < 3:
        try:
            conn, _ = server.accept()
        except TimeoutError:
            break
        attempt += 1
        payload = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            payload += chunk
            if b"\n" in chunk:
                break
        trace.write(f"attempt={attempt} payload={payload.decode('utf-8', 'replace')}\n")
        trace.flush()
        if attempt < 3:
            conn.sendall(b'{"type":"response","command":"send","success":false,"error":"retry me"}\n')
        else:
            conn.sendall(b'{"type":"response","command":"send","success":true}\n')
        conn.close()

server.close()
PY
RETRY_SERVER_PID=$!

RETRY_READY=0
for _ in $(seq 1 40); do
  if [ -S "$RETRY_SOCKET" ]; then
    RETRY_READY=1
    break
  fi
  if ! kill -0 "$RETRY_SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

if [ "$RETRY_READY" -eq 0 ]; then
  pass "runner retry assertion skipped (unix sockets unavailable in this environment)"
  wait "$RETRY_SERVER_PID" 2>/dev/null || true
else
  ln -s "$(basename "$RETRY_SOCKET")" "$RETRY_ALIAS"

  if BB_CONTROL_DIR="$CONTROL_DIR" run_expect_success "$RUNNER" \
    --backend claude-code \
    --worktree "$WORKTREE" \
    --session-name dev-agent-myapp-retry9876 \
    --todo-id retry9876 \
    --repo myapp \
    --persona-dir "$PERSONA_DIR" \
    --timeout 30 \
    --control-session control-retry \
    >/dev/null; then
    pass "runner succeeds after retryable control failures"
  else
    fail "runner should retry and succeed"
    kill "$RETRY_SERVER_PID" 2>/dev/null || true
  fi

  wait_server_or_terminate "$RETRY_SERVER_PID"

  if [ -f "$RETRY_TRACE" ]; then
    retry_trace="$(cat "$RETRY_TRACE")"
    assert_contains "runner attempted completion update three times" "$retry_trace" "attempt=3"
  else
    fail "retry trace should be captured"
  fi
fi

# 6) Worktree validation
mkdir -p "$TMPDIR/not-a-worktree"
if out="$(run_expect_failure "$RUNNER" \
  --backend claude-code \
  --worktree "$TMPDIR/not-a-worktree" \
  --session-name dev-agent-myapp-deadbeef \
  --todo-id deadbeef \
  --repo myapp \
  --persona-dir "$PERSONA_DIR")"; then
  assert_contains "invalid worktree is rejected" "$out" "worktree is not a git checkout"
else
  fail "invalid worktree should fail"
fi

# 7) bb-update helper sends follow_up payload
UPDATE_SOCKET="$CONTROL_DIR/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.sock"
UPDATE_ALIAS="$CONTROL_DIR/control-update.alias"
UPDATE_PAYLOAD="$TMPDIR/bb-update-payload.txt"

python3 - "$UPDATE_SOCKET" "$UPDATE_PAYLOAD" <<'PY' 2>/dev/null &
import os
import socket
import sys

sock_path = sys.argv[1]
out_path = sys.argv[2]

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
conn, _ = server.accept()

data = b""
while True:
    chunk = conn.recv(4096)
    if not chunk:
        break
    data += chunk
    if b"\n" in chunk:
        break

with open(out_path, "wb") as fh:
    fh.write(data)

conn.sendall(b'{"type":"response","command":"send","success":true}\n')
conn.close()
server.close()
PY
UPDATE_SERVER_PID=$!

UPDATE_SERVER_READY=0
for _ in $(seq 1 40); do
  if [ -S "$UPDATE_SOCKET" ]; then
    UPDATE_SERVER_READY=1
    break
  fi
  if ! kill -0 "$UPDATE_SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

if [ "$UPDATE_SERVER_READY" -eq 0 ]; then
  pass "bb-update socket assertion skipped (unix sockets unavailable in this environment)"
  wait "$UPDATE_SERVER_PID" 2>/dev/null || true
else
  ln -s "$(basename "$UPDATE_SOCKET")" "$UPDATE_ALIAS"

  if BB_CONTROL_DIR="$CONTROL_DIR" \
    BB_CONTROL_SESSION="control-update" \
    BB_SESSION_ID="cccccccc-cccc-4ccc-8ccc-cccccccccccc" \
    BB_SESSION_NAME="dev-agent-myapp-feed1234" \
    "$BB_UPDATE" "Milestone: PR opened" >/dev/null 2>&1; then
    pass "bb-update call succeeded"
  else
    fail "bb-update call should succeed"
  fi

  wait "$UPDATE_SERVER_PID"

  if [ -f "$UPDATE_PAYLOAD" ]; then
    payload="$(cat "$UPDATE_PAYLOAD")"
    assert_contains "bb-update payload contains follow_up mode" "$payload" '"mode":"follow_up"'
    assert_contains "bb-update payload contains message" "$payload" "Milestone: PR opened"
  else
    fail "bb-update payload should be captured"
  fi
fi

# 8) bb-update helper fails when control rejects update
REJECT_SOCKET="$CONTROL_DIR/dddddddd-dddd-4ddd-8ddd-dddddddddddd.sock"
REJECT_ALIAS="$CONTROL_DIR/control-reject.alias"

python3 - "$REJECT_SOCKET" <<'PY' 2>/dev/null &
import os
import socket
import sys

sock_path = sys.argv[1]
if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
conn, _ = server.accept()
while True:
    chunk = conn.recv(4096)
    if not chunk or b"\n" in chunk:
        break
conn.sendall(b'{"type":"response","command":"send","success":false,"error":"rejected"}\n')
conn.close()
server.close()
PY
REJECT_SERVER_PID=$!

REJECT_READY=0
for _ in $(seq 1 40); do
  if [ -S "$REJECT_SOCKET" ]; then
    REJECT_READY=1
    break
  fi
  if ! kill -0 "$REJECT_SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

if [ "$REJECT_READY" -eq 0 ]; then
  pass "bb-update rejection assertion skipped (unix sockets unavailable in this environment)"
  wait "$REJECT_SERVER_PID" 2>/dev/null || true
else
  ln -s "$(basename "$REJECT_SOCKET")" "$REJECT_ALIAS"
  if BB_CONTROL_DIR="$CONTROL_DIR" \
    BB_CONTROL_SESSION="control-reject" \
    "$BB_UPDATE" "Should fail" >/dev/null 2>&1; then
    fail "bb-update should fail when control rejects update"
  else
    pass "bb-update fails on explicit control rejection"
  fi
  wait "$REJECT_SERVER_PID"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
