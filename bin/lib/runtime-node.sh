#!/bin/bash
# Shared embedded Node runtime helpers.

# Canonical embedded Node version used by setup/install unless overridden.
: "${BAUDBOT_RUNTIME_NODE_VERSION_DEFAULT:=22.14.0}"

bb_runtime_node_version() {
  echo "${BAUDBOT_RUNTIME_NODE_VERSION:-$BAUDBOT_RUNTIME_NODE_VERSION_DEFAULT}"
}

bb_runtime_node_versioned_dir() {
  local home_dir="${1:?home directory required}"
  echo "$home_dir/opt/node-v$(bb_runtime_node_version)-linux-x64"
}

bb_runtime_node_bin_dir() {
  local home_dir="${1:?home directory required}"

  if [ -n "${BAUDBOT_RUNTIME_NODE_BIN_DIR:-}" ]; then
    echo "$BAUDBOT_RUNTIME_NODE_BIN_DIR"
    return 0
  fi

  if [ -n "${BAUDBOT_RUNTIME_NODE_DIR:-}" ]; then
    echo "$BAUDBOT_RUNTIME_NODE_DIR/bin"
    return 0
  fi

  echo "$home_dir/opt/node/bin"
}

bb_resolve_runtime_node_bin() {
  local home_dir="${1:-${HOME:-}}"
  local candidate=""

  [ -n "$home_dir" ] || return 1

  for candidate in \
    "${BAUDBOT_RUNTIME_NODE_BIN:-}" \
    "$(bb_runtime_node_bin_dir "$home_dir")/node" \
    "$(bb_runtime_node_versioned_dir "$home_dir")/bin/node" \
    "$home_dir/opt/node-v"*-linux-x64/bin/node; do
    [ -n "$candidate" ] || continue

    # If the glob didn't expand, skip the literal pattern.
    case "$candidate" in
      *\**)
        continue
        ;;
    esac

    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

bb_resolve_runtime_node_bin_dir() {
  local home_dir="${1:-${HOME:-}}"
  local node_bin=""

  if node_bin="$(bb_resolve_runtime_node_bin "$home_dir")"; then
    dirname "$node_bin"
    return 0
  fi

  bb_runtime_node_bin_dir "$home_dir"
}
