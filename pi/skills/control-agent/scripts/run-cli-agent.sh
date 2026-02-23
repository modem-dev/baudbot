#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '%s\n' "[run-cli-agent] $*"
}

die() {
  printf '%s\n' "[run-cli-agent] ERROR: $*" >&2
  exit 1
}

require_non_empty() {
  local name="$1"
  local value="${2:-}"
  if [ -z "$value" ]; then
    die "required value is empty: $name"
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

random_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    node -e 'console.log(require("crypto").randomUUID())'
    return 0
  fi

  die "unable to generate UUID (uuidgen/python3/node missing)"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BACKEND=""
WORKTREE=""
SESSION_NAME=""
TODO_ID=""
REPO=""
MODEL=""
TIMEOUT_SEC=3600
CONTROL_SESSION="control-agent"
PERSONA_DIR=""
SHIM_SCRIPT=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)
      BACKEND="${2:-}"
      shift 2
      ;;
    --worktree)
      WORKTREE="${2:-}"
      shift 2
      ;;
    --session-name)
      SESSION_NAME="${2:-}"
      shift 2
      ;;
    --todo-id)
      TODO_ID="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="${2:-}"
      shift 2
      ;;
    --control-session)
      CONTROL_SESSION="${2:-}"
      shift 2
      ;;
    --persona-dir)
      PERSONA_DIR="${2:-}"
      shift 2
      ;;
    --shim-script)
      SHIM_SCRIPT="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: run-cli-agent.sh \
  --backend <claude-code|codex> \
  --worktree <path> \
  --session-name <name> \
  --todo-id <id> \
  --repo <name> \
  [--model <model>] \
  [--timeout <seconds>] \
  [--control-session <name>] \
  [--dry-run]
USAGE
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_non_empty "backend" "$BACKEND"
require_non_empty "worktree" "$WORKTREE"
require_non_empty "session-name" "$SESSION_NAME"
require_non_empty "todo-id" "$TODO_ID"
require_non_empty "repo" "$REPO"

case "$BACKEND" in
  claude-code|codex)
    ;;
  *)
    die "invalid --backend: $BACKEND (expected claude-code or codex)"
    ;;
esac

if [ ! -d "$WORKTREE" ]; then
  die "worktree does not exist: $WORKTREE"
fi

if [ ! -d "$WORKTREE/.git" ] && [ ! -f "$WORKTREE/.git" ]; then
  die "worktree is not a git checkout: $WORKTREE"
fi

if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
  die "--timeout must be an integer number of seconds"
fi

if [ -z "$PERSONA_DIR" ]; then
  if [ -d "$HOME/.pi/agent/skills/dev-agent-cli" ]; then
    PERSONA_DIR="$HOME/.pi/agent/skills/dev-agent-cli"
  else
    PERSONA_DIR="$SKILLS_ROOT/dev-agent-cli"
  fi
fi

if [ -z "$SHIM_SCRIPT" ]; then
  if [ -f "$HOME/.pi/agent/extensions/cli-session-shim.mjs" ]; then
    SHIM_SCRIPT="$HOME/.pi/agent/extensions/cli-session-shim.mjs"
  else
    SHIM_SCRIPT="$SCRIPT_DIR/../../../extensions/cli-session-shim.mjs"
  fi
fi

case "$BACKEND" in
  claude-code)
    TEMPLATE_PATH="$PERSONA_DIR/persona.claude-code.tmpl"
    CLI_BIN="claude"
    ;;
  codex)
    TEMPLATE_PATH="$PERSONA_DIR/persona.codex.tmpl"
    CLI_BIN="codex"
    ;;
esac

if ! command -v "$CLI_BIN" >/dev/null 2>&1; then
  die "required CLI binary not found in PATH: $CLI_BIN"
fi
if ! command -v node >/dev/null 2>&1; then
  die "node is required to run the CLI session shim"
fi
if ! command -v tmux >/dev/null 2>&1; then
  die "tmux is required"
fi
if [ ! -f "$TEMPLATE_PATH" ]; then
  die "persona template not found: $TEMPLATE_PATH"
fi
if [ ! -f "$SHIM_SCRIPT" ]; then
  die "shim script not found: $SHIM_SCRIPT"
fi

TEMPLATE_RENDERED="$(sed \
  -e "s/{{TODO_ID}}/$(escape_sed_replacement "$TODO_ID")/g" \
  -e "s/{{SESSION_NAME}}/$(escape_sed_replacement "$SESSION_NAME")/g" \
  -e "s/{{REPO}}/$(escape_sed_replacement "$REPO")/g" \
  "$TEMPLATE_PATH")"

if echo "$TEMPLATE_RENDERED" | grep -Eq '{{[A-Z0-9_]+}}'; then
  die "persona template still contains unsubstituted placeholders"
fi

BOOTSTRAP_PROMPT="$(cat <<EOF_BOOTSTRAP
$TEMPLATE_RENDERED

Bootstrap instructions:
1. Send readiness update immediately using:
   ~/.pi/agent/skills/control-agent/scripts/bb-update.sh "Ready — session $SESSION_NAME (TODO $TODO_ID)"
2. Wait for task instructions in this terminal.
3. Never call Slack APIs directly.
4. Report milestone and completion updates only through bb-update.sh.
EOF_BOOTSTRAP
)"

BB_SESSION_ID="$(random_uuid)"
CONTROL_DIR="${BB_CONTROL_DIR:-$HOME/.pi/session-control}"
SOCKET_PATH="$CONTROL_DIR/$BB_SESSION_ID.sock"

CLI_CMD=()
case "$BACKEND" in
  claude-code)
    CLI_CMD=(
      claude
      --dangerously-skip-permissions
      --append-system-prompt "$TEMPLATE_RENDERED"
    )
    if [ -n "$MODEL" ]; then
      CLI_CMD+=(--model "$MODEL")
    fi
    CLI_CMD+=("$BOOTSTRAP_PROMPT")
    ;;
  codex)
    CLI_CMD=(
      codex
      --full-auto
    )
    if [ -n "$MODEL" ]; then
      CLI_CMD+=(-m "$MODEL")
    fi
    CLI_CMD+=("$BOOTSTRAP_PROMPT")
    ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run mode enabled"
  log "backend=$BACKEND"
  log "worktree=$WORKTREE"
  log "session_name=$SESSION_NAME"
  log "todo_id=$TODO_ID"
  log "repo=$REPO"
  log "model=${MODEL:-<default>}"
  log "control_session=$CONTROL_SESSION"
  log "template=$TEMPLATE_PATH"
  log "shim=$SHIM_SCRIPT"
  log "session_id=$BB_SESSION_ID"
  log "socket=$SOCKET_PATH"
  printf '[run-cli-agent] command=' >&2
  printf '%q ' "${CLI_CMD[@]}" >&2
  printf '\n' >&2
  exit 0
fi

SHIM_LOG=""

cleanup() {
  set +e
  if [ -n "${WATCHDOG_PID:-}" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "${SHIM_PID:-}" ]; then
    kill "$SHIM_PID" 2>/dev/null || true
    wait "$SHIM_PID" 2>/dev/null || true
  fi
  if [ -n "${SHIM_LOG:-}" ]; then
    rm -f "$SHIM_LOG"
  fi
}
trap cleanup EXIT

SHIM_LOG="$(mktemp "${TMPDIR:-/tmp}/cli-session-shim.XXXXXX")"

log "starting cli-session-shim"
node "$SHIM_SCRIPT" \
  --session-id "$BB_SESSION_ID" \
  --session-name "$SESSION_NAME" \
  --tmux-session "$SESSION_NAME" \
  --control-dir "$CONTROL_DIR" \
  >"$SHIM_LOG" 2>&1 &
SHIM_PID=$!

for _ in $(seq 1 75); do
  if [ -S "$SOCKET_PATH" ]; then
    break
  fi

  if ! kill -0 "$SHIM_PID" 2>/dev/null; then
    cat "$SHIM_LOG" >&2 || true
    die "cli-session-shim exited before creating socket"
  fi

  sleep 0.2
done

if [ ! -S "$SOCKET_PATH" ]; then
  cat "$SHIM_LOG" >&2 || true
  die "timed out waiting for shim socket: $SOCKET_PATH"
fi

export BB_SESSION_ID
export BB_SESSION_NAME="$SESSION_NAME"
export BB_CONTROL_SESSION="$CONTROL_SESSION"
export BB_CONTROL_DIR="$CONTROL_DIR"

BB_UPDATE_SCRIPT="$SCRIPT_DIR/bb-update.sh"
if [ ! -x "$BB_UPDATE_SCRIPT" ]; then
  die "bb-update helper is missing or not executable: $BB_UPDATE_SCRIPT"
fi

cd "$WORKTREE"

log "launching backend=$BACKEND in $WORKTREE"
set +e
"${CLI_CMD[@]}" &
CLI_PID=$!

if [ "$TIMEOUT_SEC" -gt 0 ]; then
  (
    sleep "$TIMEOUT_SEC"
    if kill -0 "$CLI_PID" 2>/dev/null; then
      printf '%s\n' "[run-cli-agent] timeout reached (${TIMEOUT_SEC}s), terminating CLI process $CLI_PID" >&2
      kill "$CLI_PID" 2>/dev/null || true
      sleep 5
      kill -9 "$CLI_PID" 2>/dev/null || true
    fi
  ) &
  WATCHDOG_PID=$!
fi

wait "$CLI_PID"
CLI_EXIT=$?
set -e

if [ -n "${WATCHDOG_PID:-}" ]; then
  kill "$WATCHDOG_PID" 2>/dev/null || true
fi

status_label="success"
if [ "$CLI_EXIT" -ne 0 ]; then
  status_label="failure"
fi

COMPLETION_JSON="$(printf '{"type":"cli_runner_completion","todo_id":"%s","session_name":"%s","repo":"%s","backend":"%s","status":"%s","exit_code":%d}' \
  "$(json_escape "$TODO_ID")" \
  "$(json_escape "$SESSION_NAME")" \
  "$(json_escape "$REPO")" \
  "$(json_escape "$BACKEND")" \
  "$(json_escape "$status_label")" \
  "$CLI_EXIT")"

COMPLETION_MSG="$(cat <<EOF_COMPLETION
CLI agent runner exit for TODO $TODO_ID.
Session: $SESSION_NAME
Repo: $REPO
Backend: $BACKEND
Status: $status_label
Exit code: $CLI_EXIT

<bb_completion>$COMPLETION_JSON</bb_completion>
EOF_COMPLETION
)"

notify_control() {
  local attempts=3
  local attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if "$BB_UPDATE_SCRIPT" "$COMPLETION_MSG"; then
      return 0
    fi
    sleep "$attempt"
    attempt=$((attempt + 1))
  done
  return 1
}

if ! notify_control; then
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  runner_log="$HOME/.pi/agent/cli-runner-errors.log"
  mkdir -p "$(dirname "$runner_log")"
  printf '%s\n' "[$ts] failed to notify control-agent for TODO $TODO_ID (session=$SESSION_NAME backend=$BACKEND exit=$CLI_EXIT)" >> "$runner_log"

  todo_suffix="${TODO_ID#TODO-}"
  for todo_file in "$HOME/.pi/todos/$todo_suffix.md" "$HOME/.pi/todos/$TODO_ID.md"; do
    if [ -f "$todo_file" ]; then
      printf '\n[cli-runner-error %s] failed to notify control-agent (exit=%s backend=%s session=%s)\n' \
        "$ts" "$CLI_EXIT" "$BACKEND" "$SESSION_NAME" >> "$todo_file"
      break
    fi
  done
fi

exit "$CLI_EXIT"
