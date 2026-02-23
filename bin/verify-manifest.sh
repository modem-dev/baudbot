#!/bin/bash
# Verify deployed runtime files against ~/.pi/agent/baudbot-manifest.json.
#
# Modes:
#   off    - skip verification (exit 0)
#   warn   - log warnings on mismatch (exit 0)
#   strict - fail on mismatch (exit 1)

set -euo pipefail

MODE="${BAUDBOT_STARTUP_INTEGRITY_MODE:-warn}"
MANIFEST_FILE="${BAUDBOT_MANIFEST_FILE:-$HOME/.pi/agent/baudbot-manifest.json}"
STATUS_FILE="${BAUDBOT_INTEGRITY_STATUS_FILE:-$HOME/.pi/agent/manifest-integrity-status.json}"
AGENT_HOME="${BAUDBOT_HOME:-$HOME}"
RELEASE_ROOT="${BAUDBOT_CURRENT_LINK:-/opt/baudbot/current}"

# Expected mutable content that should not block startup if present in a manifest.
EXCLUDE_REGEX='^\.pi/agent/(sessions|memory|logs)/|\.log$'

mkdir -p "$(dirname "$STATUS_FILE")"

write_status() {
  local status="$1"
  local checked_files="$2"
  local skipped_files="$3"
  local missing_files="$4"
  local hash_mismatches="$5"

  cat >"$STATUS_FILE" <<EOF
{
  "checked_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mode": "$MODE",
  "status": "$status",
  "manifest": "$MANIFEST_FILE",
  "checked_files": $checked_files,
  "skipped_files": $skipped_files,
  "missing_files": $missing_files,
  "hash_mismatches": $hash_mismatches
}
EOF
  chmod 600 "$STATUS_FILE" 2>/dev/null || true
}

case "$MODE" in
  off|warn|strict) ;;
  *)
    echo "⚠️  Unknown BAUDBOT_STARTUP_INTEGRITY_MODE='$MODE' (expected: off|warn|strict). Falling back to warn." >&2
    MODE="warn"
    ;;
esac

if [ "$MODE" = "off" ]; then
  echo "Startup integrity check disabled (BAUDBOT_STARTUP_INTEGRITY_MODE=off)."
  write_status "skipped" 0 0 0 0
  exit 0
fi

if [ ! -f "$MANIFEST_FILE" ]; then
  echo "⚠️  Deploy manifest not found: $MANIFEST_FILE" >&2
  write_status "warn" 0 0 0 0
  if [ "$MODE" = "strict" ]; then
    echo "❌ Startup integrity verification failed (missing manifest, strict mode)." >&2
    exit 1
  fi
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  jq not found; cannot parse deploy manifest for startup integrity check." >&2
  write_status "warn" 0 0 0 0
  if [ "$MODE" = "strict" ]; then
    echo "❌ Startup integrity verification failed (jq missing, strict mode)." >&2
    exit 1
  fi
  exit 0
fi

if ! jq -e '.files and (.files | type == "object")' "$MANIFEST_FILE" >/dev/null 2>&1; then
  echo "⚠️  Invalid manifest format (missing .files object): $MANIFEST_FILE" >&2
  write_status "warn" 0 0 0 0
  if [ "$MODE" = "strict" ]; then
    echo "❌ Startup integrity verification failed (invalid manifest, strict mode)." >&2
    exit 1
  fi
  exit 0
fi

checked_files=0
skipped_files=0
missing_files=0
hash_mismatches=0

while IFS=$'\t' read -r rel_path expected_hash; do
  [ -n "$rel_path" ] || continue

  if [[ "$rel_path" =~ $EXCLUDE_REGEX ]]; then
    skipped_files=$((skipped_files + 1))
    continue
  fi

  if [[ "$rel_path" == release/* ]]; then
    full_path="$RELEASE_ROOT/${rel_path#release/}"
  else
    full_path="$AGENT_HOME/$rel_path"
  fi

  checked_files=$((checked_files + 1))

  if [ ! -f "$full_path" ]; then
    echo "⚠️  Missing file from manifest: $rel_path ($full_path)" >&2
    missing_files=$((missing_files + 1))
    continue
  fi

  actual_hash=$(sha256sum "$full_path" | awk '{print $1}')
  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "⚠️  Hash mismatch: $rel_path" >&2
    hash_mismatches=$((hash_mismatches + 1))
  fi
done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' "$MANIFEST_FILE")

if [ "$missing_files" -eq 0 ] && [ "$hash_mismatches" -eq 0 ]; then
  echo "✅ Startup integrity check passed ($checked_files files, $skipped_files skipped)."
  write_status "pass" "$checked_files" "$skipped_files" 0 0
  exit 0
fi

total_issues=$((missing_files + hash_mismatches))
echo "⚠️  Startup integrity check found $total_issues issue(s) ($missing_files missing, $hash_mismatches hash mismatch)." >&2

if [ "$MODE" = "strict" ]; then
  write_status "fail" "$checked_files" "$skipped_files" "$missing_files" "$hash_mismatches"
  echo "❌ Strict mode enabled; refusing to start." >&2
  exit 1
fi

write_status "warn" "$checked_files" "$skipped_files" "$missing_files" "$hash_mismatches"
exit 0
