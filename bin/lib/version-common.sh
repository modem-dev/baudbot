#!/bin/bash
# Shared version helpers for Baudbot shell scripts.

bb_package_json_path() {
  local root="${1:?repo root required}"
  echo "$root/package.json"
}

bb_package_lock_json_path() {
  local root="${1:?repo root required}"
  echo "$root/package-lock.json"
}

bb_package_version() {
  local root="${1:?repo root required}"
  local package_json=""

  package_json="$(bb_package_json_path "$root")"
  [ -r "$package_json" ] || return 1

  json_get_string "$package_json" "version"
}

bb_package_version_or_unknown() {
  local root="${1:?repo root required}"
  bb_package_version "$root" 2>/dev/null || echo "unknown"
}

bb_release_tag_for_version() {
  local version="${1:?version required}"
  echo "v$version"
}
