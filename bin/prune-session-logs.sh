#!/bin/bash
# Prune old pi session logs to reduce sensitive transcript retention.
#
# Deletes *.jsonl files under ~/.pi/agent/sessions older than N days,
# then removes empty session directories.
#
# Usage: ~/baudbot/bin/prune-session-logs.sh [--days N] [--dry-run]
# Default retention: 14 days

set -euo pipefail

RETENTION_DAYS=14
DRY_RUN=0

usage() {
  echo "Usage: $0 [--days N] [--dry-run]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --days)
      [ "$#" -lt 2 ] && { usage; exit 2; }
      RETENTION_DAYS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! echo "$RETENTION_DAYS" | grep -Eq '^[0-9]+$'; then
  echo "Invalid --days value: $RETENTION_DAYS (must be a non-negative integer)" >&2
  exit 2
fi

SESSION_DIR="${HOME}/.pi/agent/sessions"

if [ ! -d "$SESSION_DIR" ]; then
  echo "No sessions directory found at $SESSION_DIR"
  exit 0
fi

deleted_logs=0
deleted_dirs=0
scanned_logs=0

while IFS= read -r -d '' logfile; do
  scanned_logs=$((scanned_logs + 1))

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "WOULD DELETE: $logfile"
    deleted_logs=$((deleted_logs + 1))
    continue
  fi

  rm -f "$logfile"
  echo "  ✓ Deleted log: $logfile"
  deleted_logs=$((deleted_logs + 1))
done < <(find "$SESSION_DIR" -type f -name '*.jsonl' -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

while IFS= read -r -d '' dir; do
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "WOULD DELETE EMPTY DIR: $dir"
    deleted_dirs=$((deleted_dirs + 1))
    continue
  fi

  rmdir "$dir" 2>/dev/null || true
  if [ ! -d "$dir" ]; then
    echo "  ✓ Deleted empty dir: $dir"
    deleted_dirs=$((deleted_dirs + 1))
  fi
done < <(find "$SESSION_DIR" -mindepth 1 -type d -empty -print0 2>/dev/null)

echo ""
echo "Session log pruning complete"
echo "  Retention days: $RETENTION_DAYS"
echo "  Old logs found: $scanned_logs"
echo "  Logs deleted: $deleted_logs"
echo "  Empty dirs deleted: $deleted_dirs"

if [ "$DRY_RUN" -eq 1 ] && [ "$deleted_logs" -gt 0 ]; then
  echo ""
  echo "  (dry run — no files were modified)"
fi
