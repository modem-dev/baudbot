#!/bin/bash
# Tests for bin/lib/remote-hetzner.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/remote-hetzner.sh
source "$SCRIPT_DIR/remote-hetzner.sh"

TOTAL=0
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  local out

  TOTAL=$((TOTAL + 1))
  printf "  %-45s " "$name"

  out="$(mktemp /tmp/baudbot-remote-hetzner-test-output.XXXXXX)"
  if "$@" >"$out" 2>&1; then
    echo "✓"
    PASSED=$((PASSED + 1))
  else
    echo "✗ FAILED"
    tail -60 "$out" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
  rm -f "$out"
}

with_mocked_curl() {
  local case_name="$1"
  shift

  local tmp fakebin fakecurl
  tmp="$(mktemp -d /tmp/baudbot-remote-hetzner.XXXXXX)"
  fakebin="$tmp/fakebin"
  fakecurl="$fakebin/curl"
  mkdir -p "$fakebin"

  cat > "$fakecurl" <<'EOF_CURL'
#!/bin/bash
set -euo pipefail

out_file=""
method="GET"
url=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    -w)
      shift 2
      ;;
    -X)
      method="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -d)
      shift 2
      ;;
    -s|-S|-sS)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

code="500"
body='{"error":{"message":"unknown mock case"}}'

case "${MOCK_CURL_CASE:-}" in
  validate_ok)
    code="200"
    body='{"account":{"id":1}}'
    ;;
  unauthorized)
    code="401"
    body='{"error":{"message":"unauthorized"}}'
    ;;
  rate_limit)
    code="429"
    body='{"error":{"message":"too many requests"}}'
    ;;
  create_key)
    code="201"
    body='{"ssh_key":{"id":321}}'
    ;;
  create_server)
    code="201"
    body='{"server":{"id":654}}'
    ;;
  list_servers)
    code="200"
    body='{"servers":[{"id":77,"name":"demo"}]}'
    ;;
  list_keys)
    code="200"
    body='{"ssh_keys":[{"id":88,"name":"demo-key"}]}'
    ;;
  delete_ok)
    code="204"
    body=''
    ;;
  wait_running)
    code="200"
    counter_file="${MOCK_COUNTER_FILE}"
    counter="0"
    if [ -f "$counter_file" ]; then
      counter="$(cat "$counter_file")"
    fi
    counter=$((counter + 1))
    printf '%s' "$counter" > "$counter_file"
    if [ "$counter" -lt 3 ]; then
      body='{"server":{"status":"starting","public_net":{"ipv4":{"ip":""}}}}'
    else
      body='{"server":{"status":"running","public_net":{"ipv4":{"ip":"198.51.100.20"}}}}'
    fi
    ;;
  wait_timeout)
    code="200"
    body='{"server":{"status":"starting","public_net":{"ipv4":{"ip":""}}}}'
    ;;
esac

if [ -n "$out_file" ]; then
  printf '%s' "$body" > "$out_file"
fi

printf '%s' "$code"
exit 0
EOF_CURL

  chmod +x "$fakecurl"

  local rc=0
  (
    set -euo pipefail
    export PATH="$fakebin:$PATH"
    hash -r
    export MOCK_CURL_CASE="$case_name"
    export MOCK_COUNTER_FILE="$tmp/counter"
    "$@"
  ) || rc=$?

  rm -rf "$tmp"
  return "$rc"
}

test_validate_credentials_ok() {
  with_mocked_curl "validate_ok" remote_hetzner_validate_credentials "token123"
}

test_validate_credentials_unauthorized() {
  (
    set -euo pipefail
    if with_mocked_curl "unauthorized" remote_hetzner_validate_credentials "badtoken" >/tmp/baudbot-hetzner-auth.out 2>&1; then
      return 1
    fi
    grep -q "authentication failed" /tmp/baudbot-hetzner-auth.out
    rm -f /tmp/baudbot-hetzner-auth.out
  )
}

test_create_ssh_key_returns_id() {
  (
    set -euo pipefail
    local id
    id="$(with_mocked_curl "create_key" remote_hetzner_create_ssh_key "token123" "demo-key" "ssh-ed25519 AAAA")"
    [ "$id" = "321" ]
  )
}

test_create_server_returns_id() {
  (
    set -euo pipefail
    local id
    id="$(with_mocked_curl "create_server" remote_hetzner_create_server "token123" "demo" "cpx11" "ubuntu-24.04" "ash" "55")"
    [ "$id" = "654" ]
  )
}

test_wait_server_running_polls_until_running() {
  (
    set -euo pipefail
    local ip
    ip="$(with_mocked_curl "wait_running" remote_hetzner_wait_server_running "token123" "654" "5" "1")"
    [ "$ip" = "198.51.100.20" ]
  )
}

test_wait_server_running_timeout() {
  (
    set -euo pipefail
    if with_mocked_curl "wait_timeout" remote_hetzner_wait_server_running "token123" "654" "1" "1" >/tmp/baudbot-hetzner-timeout.out 2>&1; then
      return 1
    fi
    grep -q "Timed out" /tmp/baudbot-hetzner-timeout.out
    rm -f /tmp/baudbot-hetzner-timeout.out
  )
}

test_rate_limit_error_message() {
  (
    set -euo pipefail
    if with_mocked_curl "rate_limit" remote_hetzner_validate_credentials "token123" >/tmp/baudbot-hetzner-rate.out 2>&1; then
      return 1
    fi
    grep -q "rate limit" /tmp/baudbot-hetzner-rate.out
    rm -f /tmp/baudbot-hetzner-rate.out
  )
}

echo "=== remote-hetzner tests ==="
echo ""

run_test "validate credentials success" test_validate_credentials_ok
run_test "validate credentials unauthorized" test_validate_credentials_unauthorized
run_test "create ssh key returns id" test_create_ssh_key_returns_id
run_test "create server returns id" test_create_server_returns_id
run_test "wait running polls" test_wait_server_running_polls_until_running
run_test "wait running timeout" test_wait_server_running_timeout
run_test "rate limit error handling" test_rate_limit_error_message

echo ""
echo "=== $PASSED/$TOTAL passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
