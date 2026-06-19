#!/bin/bash
# Shared varlock install/version helpers for Baudbot shell scripts.
#
# varlock is installed as a standalone SEA binary (not an npm dependency)
# because it runs at the shell/process-supervision layer for the agent user,
# outside any Node project. To keep installs reproducible we pin a version and
# reconcile to it on both first-time setup and `baudbot update`.

# Pinned varlock version. Env-overridable, mirroring the PI_VERSION convention.
bb_varlock_pinned_version() {
  echo "${BAUDBOT_VARLOCK_VERSION:-1.7.1}"
}

# Print the version reported by a varlock binary, whitespace-stripped.
# Args: $1 = path to varlock binary. Returns non-zero if not runnable.
bb_varlock_installed_version() {
  local bin="$1"
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  "$bin" --version 2>/dev/null | head -n1 | tr -d '[:space:]'
}

# Decide whether a (re)install is needed.
# Args: $1 = installed version (may be empty), $2 = pinned version.
# Returns 0 (needs install) when missing or mismatched, 1 when up to date.
bb_varlock_needs_install() {
  local installed="$1" pinned="$2"
  [ -n "$installed" ] && [ "$installed" = "$pinned" ] && return 1
  return 0
}

# Return 0 if a varlock config.json has telemetry explicitly disabled.
# `varlock telemetry disable` leaves an anonymousId in the file but adds
# "telemetryDisabled": true — so we key off that flag, not anonymousId presence.
# Args: $1 = path to config.json.
bb_varlock_telemetry_disabled() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1
  grep -qE '"telemetryDisabled"[[:space:]]*:[[:space:]]*true' "$cfg"
}

# Install or upgrade varlock for the agent user to the pinned version, persist
# the telemetry opt-out, and keep the legacy ~/.varlock/bin symlink. Idempotent:
# safe to call from setup.sh (first install) and update-release.sh (upgrades).
# Args: $1 = agent unix user, $2 = agent home directory.
bb_reconcile_varlock() {
  local agent_user="$1" agent_home="$2"
  local pinned legacy_bin config_bin config_dir cur_bin="" installed=""

  # Nothing to do if the agent user doesn't exist yet (e.g. test sandboxes, or
  # update invoked before setup created the user).
  if ! id "$agent_user" >/dev/null 2>&1; then
    echo "agent user '$agent_user' not found; skipping varlock reconcile"
    return 0
  fi

  pinned="$(bb_varlock_pinned_version)"
  legacy_bin="$agent_home/.varlock/bin/varlock"
  config_dir="$agent_home/.config/varlock/bin"
  config_bin="$config_dir/varlock"

  if [ -x "$config_bin" ]; then
    cur_bin="$config_bin"
  elif [ -x "$legacy_bin" ]; then
    cur_bin="$legacy_bin"
  fi
  if [ -n "$cur_bin" ]; then
    installed="$(sudo -u "$agent_user" "$cur_bin" --version 2>/dev/null | head -n1 | tr -d '[:space:]')"
  fi

  if bb_varlock_needs_install "$installed" "$pinned"; then
    echo "Installing varlock $pinned for $agent_user (current: ${installed:-none})..."
    # The installer takes the version as a CLI arg (NOT an env var), defaults to
    # "latest", and prefers Homebrew when present. Pin the version, force the
    # binary path (so the pin is honored — brew only tracks latest), and fix the
    # install dir so upgrades always land at the same place. The installer's
    # trailing `varlock --post-install curl` line prints a harmless "Invalid
    # subcommand" warning on current versions but still exits 0.
    sudo -u "$agent_user" bash -c \
      "curl -sSfL https://varlock.dev/install.sh | sh -s -- --version='$pinned' --dir='$config_dir' --force-no-brew"
  else
    echo "varlock $pinned already installed for $agent_user, skipping"
  fi

  # Persist telemetry opt-out (writes "telemetryDisabled": true). Best-effort:
  # never fail the install if the telemetry command misbehaves.
  local vbin="$config_bin"
  [ -x "$vbin" ] || vbin="$legacy_bin"
  if [ -x "$vbin" ]; then
    sudo -u "$agent_user" "$vbin" telemetry disable >/dev/null 2>&1 || true
  fi

  # Newer installers place the binary under ~/.config/varlock/bin. Keep a
  # compatibility link at ~/.varlock/bin/varlock for existing runtime scripts,
  # but never clobber a real (non-symlink) legacy binary.
  if [ -x "$config_bin" ]; then
    if [ -x "$legacy_bin" ] && [ ! -L "$legacy_bin" ]; then
      echo "Keeping existing legacy varlock binary at $legacy_bin"
    else
      sudo -u "$agent_user" bash -c "mkdir -p '$agent_home/.varlock/bin' && ln -sfn '$config_bin' '$legacy_bin'"
    fi
  fi
}
