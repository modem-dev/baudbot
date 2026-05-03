#!/bin/bash
# Baudbot state archive helper.
#
# Creates/restores a zip archive for durable agent state, including:
# - persistent memory (~/.pi/agent/memory)
# - todos (~/.pi/todos)
# - local runtime customizations (extensions/skills/subagents/settings)
# Secrets are intentionally excluded from state archives.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/shell-common.sh
source "$SCRIPT_DIR/lib/shell-common.sh"
# shellcheck source=bin/lib/paths-common.sh
source "$SCRIPT_DIR/lib/paths-common.sh"
bb_enable_strict_mode
bb_init_paths

ALLOW_NON_ROOT="${BAUDBOT_STATE_ALLOW_NON_ROOT:-0}"
STATE_FORMAT="baudbot-state-v1"

STATE_PATHS=(
  ".pi/agent/memory"
  ".pi/todos"
  ".pi/agent/settings.json"
  ".pi/agent/extensions"
  ".pi/agent/skills"
  ".pi/agent/subagents"
  ".pi/agent/subagents-state.json"
)

usage() {
  cat <<'EOF'
Usage:
  sudo baudbot state backup [ARCHIVE.zip] [--force]
  sudo baudbot state restore <ARCHIVE.zip> [--restart]

What gets backed up:
  - ~/.pi/agent/memory
  - ~/.pi/todos
  - ~/.pi/agent/settings.json
  - ~/.pi/agent/extensions
  - ~/.pi/agent/skills
  - ~/.pi/agent/subagents
  - ~/.pi/agent/subagents-state.json (if present)

Never backed up (private by design):
  - ~/.config/.env
  - ~/.pi/agent/auth.json

Examples:
  sudo baudbot state backup /tmp/baudbot-state.zip
  sudo baudbot stop
  sudo baudbot state restore /tmp/baudbot-state.zip
  sudo baudbot start
EOF
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || bb_die "python3 is required for zip archive handling"
}

service_running() {
  if [ "$(id -u)" -eq 0 ] && bb_has_systemd; then
    systemctl is-active --quiet baudbot
    return $?
  fi
  return 1
}

resolve_archive_path() {
  local raw_path="${1:-}"
  local path=""

  if [ -n "$raw_path" ]; then
    path="$raw_path"
  else
    path="baudbot-state-$(date -u +%Y%m%d-%H%M%S).zip"
  fi

  if [[ "$path" != *.zip ]]; then
    path="${path}.zip"
  fi

  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi

  echo "$path"
}

copy_path_if_present() {
  local rel_path="$1"
  local payload_root="$2"
  local source_path="$BAUDBOT_AGENT_HOME/$rel_path"
  local target_path="$payload_root/$rel_path"

  if [ ! -e "$source_path" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$target_path")"
  cp -a "$source_path" "$target_path"
  bb_log "✓ included $rel_path"
}

write_metadata_file() {
  local metadata_file="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local host_name="unknown"
  if command -v hostname >/dev/null 2>&1; then
    host_name="$(hostname 2>/dev/null || echo unknown)"
  fi

  require_python3
  python3 - "$metadata_file" "$STATE_FORMAT" "$now" "$host_name" "$BAUDBOT_AGENT_USER" "$BAUDBOT_AGENT_HOME" <<'PY'
import json
import sys

metadata_path, state_format, created_at, host_name, agent_user, agent_home = sys.argv[1:]

with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "format": state_format,
            "created_at": created_at,
            "host": host_name,
            "agent_user": agent_user,
            "agent_home": agent_home,
            "secrets_included": False,
        },
        handle,
        indent=2,
    )
    handle.write("\n")
PY
}

create_zip_archive() {
  local source_dir="$1"
  local archive_path="$2"

  require_python3

  python3 - "$source_dir" "$archive_path" <<'PY'
import os
import sys
import zipfile

source_dir = os.path.abspath(sys.argv[1])
archive_path = os.path.abspath(sys.argv[2])
archive_dir = os.path.dirname(archive_path)
source_parent = os.path.dirname(source_dir)

if archive_dir:
    os.makedirs(archive_dir, exist_ok=True)

with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as zip_file:
    for root, dirs, files in os.walk(source_dir):
        dirs.sort()
        files.sort()
        for file_name in files:
            full_path = os.path.join(root, file_name)
            arc_name = os.path.relpath(full_path, source_parent)
            zip_file.write(full_path, arc_name)
PY
}

extract_zip_archive_safe() {
  local archive_path="$1"
  local extract_dir="$2"

  require_python3

  python3 - "$archive_path" "$extract_dir" <<'PY'
import os
import pathlib
import stat
import sys
import zipfile

archive_path = os.path.abspath(sys.argv[1])
extract_dir = os.path.abspath(sys.argv[2])
os.makedirs(extract_dir, exist_ok=True)

with zipfile.ZipFile(archive_path, "r") as zip_file:
    for member in zip_file.infolist():
        name = member.filename
        if name.startswith("/") or "\x00" in name:
            raise SystemExit(f"unsafe archive entry: {name}")

        member_mode = (member.external_attr >> 16) & 0o177777
        if stat.S_ISLNK(member_mode):
            raise SystemExit(f"unsafe archive entry (symlink): {name}")

        parts = pathlib.PurePosixPath(name).parts
        if any(part == ".." for part in parts):
            raise SystemExit(f"unsafe archive entry: {name}")

        target_path = os.path.normpath(os.path.join(extract_dir, *parts))
        if not (target_path == extract_dir or target_path.startswith(extract_dir + os.sep)):
            raise SystemExit(f"unsafe archive entry: {name}")

        if member.is_dir():
            os.makedirs(target_path, exist_ok=True)
            dir_mode = member_mode & 0o7777
            if dir_mode:
                os.chmod(target_path, dir_mode)
            continue

        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        with zip_file.open(member, "r") as source, open(target_path, "wb") as target:
            target.write(source.read())

        file_mode = member_mode & 0o7777
        if file_mode:
            os.chmod(target_path, file_mode)
PY
}

restore_secure_permissions() {
  local env_file="$BAUDBOT_AGENT_HOME/.config/.env"
  local auth_file="$BAUDBOT_AGENT_HOME/.pi/agent/auth.json"
  local settings_file="$BAUDBOT_AGENT_HOME/.pi/agent/settings.json"
  local secure_dir=""
  local secure_dirs=(
    "$BAUDBOT_AGENT_HOME/.pi"
    "$BAUDBOT_AGENT_HOME/.pi/agent"
    "$BAUDBOT_AGENT_HOME/.pi/agent/memory"
    "$BAUDBOT_AGENT_HOME/.pi/agent/subagents"
    "$BAUDBOT_AGENT_HOME/.pi/todos"
  )

  for secure_dir in "${secure_dirs[@]}"; do
    if [ -d "$secure_dir" ]; then
      chmod 700 "$secure_dir"
    fi
  done

  if [ -f "$env_file" ]; then
    chmod 600 "$env_file"
  fi

  if [ -f "$auth_file" ]; then
    chmod 600 "$auth_file"
  fi

  if [ -f "$settings_file" ]; then
    chmod 600 "$settings_file"
  fi
}

restore_ownership_if_root() {
  local rel_path=""

  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi

  for rel_path in "${STATE_PATHS[@]}"; do
    if [ -e "$BAUDBOT_AGENT_HOME/$rel_path" ]; then
      chown -R "$BAUDBOT_AGENT_USER:$BAUDBOT_AGENT_USER" "$BAUDBOT_AGENT_HOME/$rel_path"
    fi
  done
}

cmd_backup() {
  local archive_raw=""
  local archive_path=""
  local overwrite="0"
  local tmp_dir=""
  local state_root=""
  local payload_root=""
  local rel_path=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        overwrite="1"
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        if [ -n "$archive_raw" ]; then
          bb_die "unexpected argument: $1"
        fi
        archive_raw="$1"
        ;;
    esac
    shift
  done

  archive_path="$(resolve_archive_path "$archive_raw")"
  bb_require_root "baudbot state backup" "$ALLOW_NON_ROOT"

  [ -d "$BAUDBOT_AGENT_HOME" ] || bb_die "agent home does not exist: $BAUDBOT_AGENT_HOME"

  if [ -e "$archive_path" ] && [ "$overwrite" != "1" ]; then
    bb_die "archive already exists: $archive_path (use --force to overwrite)"
  fi

  if service_running; then
    bb_warn "baudbot service is running; backup may miss in-flight writes"
    bb_warn "for a fully consistent snapshot: sudo baudbot stop && sudo baudbot state backup ... && sudo baudbot start"
  fi

  tmp_dir="$(mktemp -d /tmp/baudbot-state-backup.XXXXXX)"
  trap 'rm -rf "${tmp_dir:-}"' RETURN

  state_root="$tmp_dir/baudbot-state"
  payload_root="$state_root/agent-home"
  mkdir -p "$payload_root"

  for rel_path in "${STATE_PATHS[@]}"; do
    copy_path_if_present "$rel_path" "$payload_root"
  done

  write_metadata_file "$state_root/metadata.json"
  create_zip_archive "$state_root" "$archive_path"

  chmod 600 "$archive_path" 2>/dev/null || true

  echo "✓ state backup created: $archive_path"
  echo "  secrets are excluded by design"
}

cmd_restore() {
  local archive_raw="${1:-}"
  local archive_path=""
  local restart_service="0"
  local tmp_dir=""
  local state_root=""
  local payload_root=""

  [ -n "$archive_raw" ] || bb_die "restore requires an archive path"
  shift || true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --restart)
        restart_service="1"
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        bb_die "unexpected argument: $1"
        ;;
    esac
    shift
  done

  archive_path="$(resolve_archive_path "$archive_raw")"
  bb_require_root "baudbot state restore" "$ALLOW_NON_ROOT"

  [ -f "$archive_path" ] || bb_die "archive not found: $archive_path"
  [ -d "$BAUDBOT_AGENT_HOME" ] || mkdir -p "$BAUDBOT_AGENT_HOME"

  if service_running; then
    bb_die "baudbot service is running. Stop it first: sudo baudbot stop"
  fi

  tmp_dir="$(mktemp -d /tmp/baudbot-state-restore.XXXXXX)"
  trap 'rm -rf "${tmp_dir:-}"' RETURN

  extract_zip_archive_safe "$archive_path" "$tmp_dir"

  state_root="$tmp_dir/baudbot-state"
  payload_root="$state_root/agent-home"

  [ -f "$state_root/metadata.json" ] || bb_die "invalid archive: missing metadata.json"
  [ -d "$payload_root" ] || bb_die "invalid archive: missing agent-home payload"

  require_python3
  python3 - "$state_root/metadata.json" "$STATE_FORMAT" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
expected = sys.argv[2]

with open(metadata_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

fmt = data.get("format")
if fmt != expected:
    raise SystemExit(f"unsupported archive format: {fmt!r}")
PY

  mkdir -p "$BAUDBOT_AGENT_HOME"
  if [ -n "$(ls -A "$BAUDBOT_AGENT_HOME" 2>/dev/null || true)" ]; then
    bb_warn "agent home is not empty; existing files not in the archive will be preserved"
  fi
  cp -a "$payload_root/." "$BAUDBOT_AGENT_HOME/"

  restore_ownership_if_root
  restore_secure_permissions

  echo "✓ state restored from: $archive_path"

  if [ "$restart_service" = "1" ]; then
    if [ "$(id -u)" -eq 0 ] && bb_has_systemd; then
      systemctl start baudbot
      echo "✓ started baudbot service"
    else
      bb_warn "--restart requested, but systemd is not available"
    fi
  else
    echo "Next step: sudo baudbot start"
  fi
}

main() {
  local command="${1:-}"

  if [ -z "$command" ]; then
    usage
    exit 1
  fi
  shift || true

  case "$command" in
    backup)
      cmd_backup "$@"
      ;;
    restore)
      cmd_restore "$@"
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      bb_die "unknown state subcommand: $command"
      ;;
  esac
}

main "$@"
