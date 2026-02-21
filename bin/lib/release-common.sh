#!/bin/bash
# Shared helpers for release/update/rollback scripts.

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

verify_git_free_release() {
  local dir="$1"

  [ -d "$dir" ] || return 1
  [ ! -d "$dir/.git" ] || return 1

  if find "$dir" -type d -name .git -print -quit | grep -q .; then
    return 1
  fi

  return 0
}

atomic_symlink_swap() {
  local target="$1"
  local link_path="$2"
  local parent
  local tmp_link

  parent="$(dirname "$link_path")"
  mkdir -p "$parent"

  tmp_link="$parent/.tmp.$(basename "$link_path").$$"
  ln -s "$target" "$tmp_link"
  mv -Tf "$tmp_link" "$link_path"
}

restart_baudbot_service_if_active() {
  if has_systemd && systemctl is-enabled baudbot >/dev/null 2>&1; then
    if systemctl is-active baudbot >/dev/null 2>&1; then
      log "restarting baudbot service"
      systemctl restart baudbot
      sleep 3
      systemctl is-active baudbot >/dev/null 2>&1 || die "service failed to restart"
    else
      log "service installed but not active; skipping restart"
    fi
  else
    log "systemd unavailable; skipping restart"
  fi
}
