#!/bin/bash
# Tests for bin/lib/version-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/json-common.sh
source "$SCRIPT_DIR/json-common.sh"
# shellcheck source=bin/lib/version-common.sh
source "$SCRIPT_DIR/version-common.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-version-common-test-output.XXXXXX)"
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

test_reads_package_version() {
  (
    set -euo pipefail
    local tmp
    tmp="$(mktemp -d /tmp/baudbot-version-common.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT

    printf '{"version":"1.2.3"}\n' > "$tmp/package.json"
    [ "$(bb_package_version "$tmp")" = "1.2.3" ]
  )
}

test_formats_release_tag() {
  (
    set -euo pipefail
    [ "$(bb_release_tag_for_version "2.3.4")" = "v2.3.4" ]
  )
}

echo "=== version-common tests ==="
echo ""

run_test "reads package.json version" test_reads_package_version
run_test "formats release tag" test_formats_release_tag

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
