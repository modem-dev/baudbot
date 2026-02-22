#!/bin/bash
# Shared path constants for baudbot shell scripts.

# shellcheck disable=SC2120 # Optional args are used by callers in other scripts.
bb_refresh_release_paths() {
  local release_root="${BAUDBOT_RELEASE_ROOT:-/opt/baudbot}"
  local force="0"

  if [ "$#" -ge 1 ]; then
    release_root="$1"
  fi
  if [ "$#" -ge 2 ]; then
    force="$2"
  fi

  BAUDBOT_RELEASE_ROOT="$release_root"

  if [ "$force" = "1" ]; then
    BAUDBOT_RELEASES_DIR="$BAUDBOT_RELEASE_ROOT/releases"
    BAUDBOT_CURRENT_LINK="$BAUDBOT_RELEASE_ROOT/current"
    BAUDBOT_PREVIOUS_LINK="$BAUDBOT_RELEASE_ROOT/previous"
    BAUDBOT_SOURCE_URL_FILE="$BAUDBOT_RELEASE_ROOT/source.url"
    BAUDBOT_SOURCE_BRANCH_FILE="$BAUDBOT_RELEASE_ROOT/source.branch"
  else
    : "${BAUDBOT_RELEASES_DIR:=$BAUDBOT_RELEASE_ROOT/releases}"
    : "${BAUDBOT_CURRENT_LINK:=$BAUDBOT_RELEASE_ROOT/current}"
    : "${BAUDBOT_PREVIOUS_LINK:=$BAUDBOT_RELEASE_ROOT/previous}"
    : "${BAUDBOT_SOURCE_URL_FILE:=$BAUDBOT_RELEASE_ROOT/source.url}"
    : "${BAUDBOT_SOURCE_BRANCH_FILE:=$BAUDBOT_RELEASE_ROOT/source.branch}"
  fi
}

bb_init_paths() {
  : "${BAUDBOT_AGENT_USER:=baudbot_agent}"

  if [ -n "${BAUDBOT_HOME:-}" ] && [ -z "${BAUDBOT_AGENT_HOME:-}" ]; then
    BAUDBOT_AGENT_HOME="$BAUDBOT_HOME"
  fi

  if [ -z "${BAUDBOT_AGENT_HOME:-}" ]; then
    BAUDBOT_AGENT_HOME="$(bb_resolve_user_home "$BAUDBOT_AGENT_USER" 2>/dev/null || true)"
  fi
  : "${BAUDBOT_AGENT_HOME:=/home/$BAUDBOT_AGENT_USER}"

  if [ -z "${BAUDBOT_HOME:-}" ]; then
    BAUDBOT_HOME="$BAUDBOT_AGENT_HOME"
  fi

  : "${BAUDBOT_RUNTIME_DIR:=$BAUDBOT_AGENT_HOME/runtime}"
  : "${BAUDBOT_PI_DIR:=$BAUDBOT_AGENT_HOME/.pi}"
  : "${BAUDBOT_AGENT_DIR:=$BAUDBOT_PI_DIR/agent}"
  : "${BAUDBOT_AGENT_EXT_DIR:=$BAUDBOT_AGENT_DIR/extensions}"
  : "${BAUDBOT_AGENT_SKILLS_DIR:=$BAUDBOT_AGENT_DIR/skills}"
  : "${BAUDBOT_AGENT_SETTINGS_FILE:=$BAUDBOT_AGENT_DIR/settings.json}"
  : "${BAUDBOT_VERSION_FILE:=$BAUDBOT_AGENT_DIR/baudbot-version.json}"
  : "${BAUDBOT_MANIFEST_FILE:=$BAUDBOT_AGENT_DIR/baudbot-manifest.json}"
  : "${BAUDBOT_ENV_FILE:=$BAUDBOT_AGENT_HOME/.config/.env}"

  bb_refresh_release_paths

  export BAUDBOT_AGENT_USER BAUDBOT_AGENT_HOME BAUDBOT_HOME
  export BAUDBOT_RUNTIME_DIR BAUDBOT_PI_DIR BAUDBOT_AGENT_DIR
  export BAUDBOT_AGENT_EXT_DIR BAUDBOT_AGENT_SKILLS_DIR BAUDBOT_AGENT_SETTINGS_FILE
  export BAUDBOT_VERSION_FILE BAUDBOT_MANIFEST_FILE BAUDBOT_ENV_FILE
  export BAUDBOT_RELEASE_ROOT BAUDBOT_RELEASES_DIR BAUDBOT_CURRENT_LINK BAUDBOT_PREVIOUS_LINK
  export BAUDBOT_SOURCE_URL_FILE BAUDBOT_SOURCE_BRANCH_FILE
}
