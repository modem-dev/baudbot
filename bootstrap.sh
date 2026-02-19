#!/bin/bash
# Baudbot bootstrap installer (non-root entrypoint)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/modem-dev/baudbot/main/bootstrap.sh | bash
#   baudbot install
#
# What this does:
#   1) Downloads the bootstrap baudbot CLI from GitHub
#   2) Installs it to /usr/local/bin/baudbot (using sudo/doas if needed)
#   3) Prints next step: `baudbot install`

set -euo pipefail

BAUDBOT_CLI_URL="${BAUDBOT_CLI_URL:-https://raw.githubusercontent.com/modem-dev/baudbot/main/bin/baudbot}"
BAUDBOT_TARGET_BIN="${BAUDBOT_BOOTSTRAP_TARGET:-/usr/local/bin/baudbot}"
TARGET_DIR="$(dirname "$BAUDBOT_TARGET_BIN")"
TMP_CLI="$(mktemp /tmp/baudbot-cli.XXXXXX)"

cleanup() {
  rm -f "$TMP_CLI"
}
trap cleanup EXIT

download_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
    return 0
  fi

  echo "❌ bootstrap requires curl or wget" >&2
  exit 1
}

escalate_prefix() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    echo "sudo"
    return 0
  fi

  if command -v doas >/dev/null 2>&1; then
    echo "doas"
    return 0
  fi

  echo ""
  return 1
}

echo "==> Downloading baudbot bootstrap CLI"
download_file "$BAUDBOT_CLI_URL" "$TMP_CLI"
chmod 0755 "$TMP_CLI"

if [ -w "$TARGET_DIR" ]; then
  mkdir -p "$TARGET_DIR"
  install -m 0755 "$TMP_CLI" "$BAUDBOT_TARGET_BIN"
else
  ESCALATOR="$(escalate_prefix || true)"
  if [ -z "$ESCALATOR" ]; then
    echo "❌ cannot write to $TARGET_DIR and no sudo/doas found" >&2
    echo "Try running as root, or set BAUDBOT_BOOTSTRAP_TARGET to a user-writable path." >&2
    exit 1
  fi

  echo "==> Installing to $BAUDBOT_TARGET_BIN using $ESCALATOR"
  "$ESCALATOR" mkdir -p "$TARGET_DIR"
  "$ESCALATOR" install -m 0755 "$TMP_CLI" "$BAUDBOT_TARGET_BIN"
fi

echo "✅ Installed baudbot bootstrap CLI to $BAUDBOT_TARGET_BIN"
echo ""
echo "Next step:"
echo "  baudbot install"
