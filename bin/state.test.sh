#!/bin/bash
# Tests for bin/state.sh backup/restore flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_SCRIPT="$SCRIPT_DIR/state.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-state-test-output.XXXXXX)"
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

run_state() {
  local agent_home="$1"
  shift

  BAUDBOT_STATE_ALLOW_NON_ROOT=1 \
    BAUDBOT_AGENT_USER="$(id -un)" \
    BAUDBOT_AGENT_HOME="$agent_home" \
    BAUDBOT_HOME="$agent_home" \
    bash "$STATE_SCRIPT" "$@"
}

seed_agent_state() {
  local agent_home="$1"
  mkdir -p "$agent_home/.pi/agent/memory"
  mkdir -p "$agent_home/.pi/todos"
  mkdir -p "$agent_home/.pi/agent/extensions/custom-ext"
  mkdir -p "$agent_home/.pi/agent/skills/custom-skill"
  mkdir -p "$agent_home/.pi/agent/subagents/custom-subagent"
  mkdir -p "$agent_home/.config"

  printf 'memory-note\n' > "$agent_home/.pi/agent/memory/operational.md"
  printf 'todo-item\n' > "$agent_home/.pi/todos/TODO-demo.md"
  printf '{"theme":"dark"}\n' > "$agent_home/.pi/agent/settings.json"
  printf 'export default true;\n' > "$agent_home/.pi/agent/extensions/custom-ext/index.ts"
  printf '#!/bin/bash\necho custom\n' > "$agent_home/.pi/agent/extensions/custom-ext/run.sh"
  chmod 755 "$agent_home/.pi/agent/extensions/custom-ext/run.sh"
  printf '# custom skill\n' > "$agent_home/.pi/agent/skills/custom-skill/SKILL.md"
  printf '{"enabled":true}\n' > "$agent_home/.pi/agent/subagents-state.json"
  printf 'ANTHROPIC_API_KEY=sk-ant-test\n' > "$agent_home/.config/.env"
  printf '{"anthropic":{"type":"oauth"}}\n' > "$agent_home/.pi/agent/auth.json"
}

test_round_trip_with_secrets() {
  (
    set -euo pipefail
    local tmp source_home target_home archive

    tmp="$(mktemp -d /tmp/baudbot-state-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    source_home="$tmp/source-home"
    target_home="$tmp/target-home"
    archive="$tmp/state.zip"

    seed_agent_state "$source_home"

    run_state "$source_home" backup "$archive"
    run_state "$target_home" restore "$archive"

    grep -q "memory-note" "$target_home/.pi/agent/memory/operational.md"
    grep -q "todo-item" "$target_home/.pi/todos/TODO-demo.md"
    grep -q "theme" "$target_home/.pi/agent/settings.json"
    grep -q "export default" "$target_home/.pi/agent/extensions/custom-ext/index.ts"
    [ "$(stat -c '%a' "$target_home/.pi/agent/extensions/custom-ext/run.sh")" = "755" ]
    grep -q "custom skill" "$target_home/.pi/agent/skills/custom-skill/SKILL.md"
    grep -q "enabled" "$target_home/.pi/agent/subagents-state.json"
    grep -q "ANTHROPIC_API_KEY" "$target_home/.config/.env"
    grep -q "anthropic" "$target_home/.pi/agent/auth.json"
  )
}

test_backup_excludes_secrets_flag() {
  (
    set -euo pipefail
    local tmp source_home target_home archive

    tmp="$(mktemp -d /tmp/baudbot-state-test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    source_home="$tmp/source-home"
    target_home="$tmp/target-home"
    archive="$tmp/state-no-secrets.zip"

    seed_agent_state "$source_home"

    run_state "$source_home" backup "$archive" --exclude-secrets
    run_state "$target_home" restore "$archive"

    [ -f "$target_home/.pi/agent/memory/operational.md" ]
    [ ! -f "$target_home/.config/.env" ]
    [ ! -f "$target_home/.pi/agent/auth.json" ]
  )
}

echo "=== state backup/restore tests ==="
echo ""

run_test "round-trip backup/restore includes secrets" test_round_trip_with_secrets
run_test "backup --exclude-secrets omits secret files" test_backup_excludes_secrets_flag

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
