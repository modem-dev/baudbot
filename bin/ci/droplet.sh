#!/bin/bash
# Manage ephemeral DigitalOcean droplets for CI.
#
# Usage:
#   bin/ci/droplet.sh create <name> <image> <ssh_pub_key_file>
#   bin/ci/droplet.sh destroy <droplet_id> [ssh_key_id] [droplet_name]
#   bin/ci/droplet.sh wait-ssh <ip> <ssh_private_key_file>
#   bin/ci/droplet.sh run <ip> <ssh_private_key_file> <script>
#   bin/ci/droplet.sh list
#
# Requires: DO_API_TOKEN env var
#
# create:    Registers SSH key with DO, creates droplet (tagged baudbot-ci),
#            polls until active. Outputs: DROPLET_ID=xxx DROPLET_IP=xxx SSH_KEY_ID=xxx
# destroy:   Deletes droplet and (optionally) SSH key from DO. If droplet_id is
#            empty but droplet_name is given, looks up the droplet by name.
#            This handles cancelled CI runs where the ID was never captured.
# wait-ssh:  Polls until SSH is reachable (up to 120s).
# run:       Executes a script on the droplet via SSH.
# list:      Lists all droplets tagged baudbot-ci.

set -euo pipefail

DO_API="https://api.digitalocean.com/v2"
REGION="${DO_REGION:-tor1}"
SIZE="${DO_SIZE:-s-2vcpu-4gb}"

die() { echo "❌ $1" >&2; exit 1; }

require_token() {
  if [ -z "${DO_API_TOKEN:-}" ]; then
    die "DO_API_TOKEN not set"
  fi
}

do_api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -s -X "$method" \
    -H "Authorization: Bearer $DO_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$DO_API/$endpoint" "$@"
}

# ── create <name> <image> <ssh_pub_key_file> ─────────────────────────────────
cmd_create() {
  require_token
  local name="${1:?Usage: droplet.sh create <name> <image> <ssh_pub_key_file>}"
  local image="${2:?}"
  local pub_key_file="${3:?}"

  [ -f "$pub_key_file" ] || die "SSH public key not found: $pub_key_file"

  local pub_key
  pub_key=$(cat "$pub_key_file")

  # Register ephemeral SSH key
  local key_name
  key_name="ci-${name}-$(date +%s)"
  local key_result
  key_result=$(do_api POST "account/keys" -d "{\"name\":\"$key_name\",\"public_key\":\"$pub_key\"}")

  local ssh_key_id
  ssh_key_id=$(echo "$key_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ssh_key']['id'])" 2>/dev/null) \
    || die "Failed to register SSH key: $key_result"

  echo "  SSH key registered: $ssh_key_id ($key_name)" >&2

  # Create droplet
  local create_result
  create_result=$(do_api POST "droplets" -d "{
    \"name\": \"$name\",
    \"region\": \"$REGION\",
    \"size\": \"$SIZE\",
    \"image\": \"$image\",
    \"ssh_keys\": [$ssh_key_id],
    \"backups\": false,
    \"monitoring\": false,
    \"tags\": [\"baudbot-ci\"]
  }")

  local droplet_id
  droplet_id=$(echo "$create_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['droplet']['id'])" 2>/dev/null) \
    || die "Failed to create droplet: $create_result"

  echo "  Droplet created: $droplet_id (polling for IP...)" >&2

  # Poll until active with public IP
  local ip="none"
  for i in $(seq 1 60); do
    local data
    data=$(do_api GET "droplets/$droplet_id")
    local status
    status=$(echo "$data" | python3 -c "import json,sys; print(json.load(sys.stdin)['droplet']['status'])")
    ip=$(echo "$data" | python3 -c "
import json,sys
d=json.load(sys.stdin)['droplet']
v4=[n for n in d['networks']['v4'] if n['type']=='public']
print(v4[0]['ip_address'] if v4 else 'none')
" 2>/dev/null || echo "none")

    if [ "$status" = "active" ] && [ "$ip" != "none" ]; then
      echo "  Droplet active: $ip" >&2
      break
    fi
    sleep 3
  done

  if [ "$ip" = "none" ]; then
    die "Droplet $droplet_id never became active"
  fi

  # Output for GitHub Actions $GITHUB_OUTPUT or eval
  echo "DROPLET_ID=$droplet_id"
  echo "DROPLET_IP=$ip"
  echo "SSH_KEY_ID=$ssh_key_id"
}

# ── destroy <droplet_id> [ssh_key_id] [droplet_name] ─────────────────────────
# If droplet_id is empty but droplet_name is provided, looks up the droplet by
# name. This handles the case where a CI run was cancelled before the create
# step wrote the droplet ID to GITHUB_OUTPUT.
cmd_destroy() {
  require_token
  local droplet_id="${1:-}"
  local ssh_key_id="${2:-}"
  local droplet_name="${3:-}"

  # If no ID but we have a name, look it up
  if [ -z "$droplet_id" ] && [ -n "$droplet_name" ]; then
    echo "  No droplet ID, looking up by name: $droplet_name" >&2
    local data
    data=$(do_api GET "droplets?per_page=200&tag_name=baudbot-ci")
    droplet_id=$(python3 -c "
import json, sys
for d in json.load(sys.stdin).get('droplets', []):
    if d['name'] == '$droplet_name':
        print(d['id'])
        break
" <<< "$data" 2>/dev/null || true)

    if [ -z "$droplet_id" ]; then
      echo "  No droplet found with name $droplet_name" >&2
    fi
  fi

  if [ -n "$droplet_id" ]; then
    local http_code
    http_code=$(do_api DELETE "droplets/$droplet_id" -o /dev/null -w "%{http_code}")
    if [ "$http_code" = "204" ]; then
      echo "  Droplet $droplet_id destroyed" >&2
    else
      echo "  ⚠️  Droplet destroy returned $http_code (may already be gone)" >&2
    fi
  fi

  if [ -n "$ssh_key_id" ]; then
    local http_code
    http_code=$(do_api DELETE "account/keys/$ssh_key_id" -o /dev/null -w "%{http_code}")
    if [ "$http_code" = "204" ]; then
      echo "  SSH key $ssh_key_id deleted" >&2
    else
      echo "  ⚠️  SSH key delete returned $http_code (may already be gone)" >&2
    fi
  fi
}

# ── wait-ssh <ip> <ssh_private_key_file> ──────────────────────────────────────
cmd_wait_ssh() {
  local ip="${1:?Usage: droplet.sh wait-ssh <ip> <ssh_private_key_file>}"
  local key_file="${2:?}"

  echo "  Waiting for SSH on $ip..." >&2
  for i in $(seq 1 40); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
         -i "$key_file" "root@$ip" true 2>/dev/null; then
      echo "  SSH ready ($((i * 3))s)" >&2
      return 0
    fi
    sleep 3
  done
  die "SSH not reachable on $ip after 120s"
}

# ── run <ip> <ssh_private_key_file> <script> ──────────────────────────────────
cmd_run() {
  local ip="${1:?Usage: droplet.sh run <ip> <ssh_private_key_file> <script>}"
  local key_file="${2:?}"
  local script="${3:?}"

  ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
    -i "$key_file" "root@$ip" bash -s < "$script"
}

# ── list ──────────────────────────────────────────────────────────────────────
cmd_list() {
  require_token
  local data
  data=$(do_api GET "droplets?per_page=200&tag_name=baudbot-ci")

  python3 -c "
import json, sys
droplets = json.load(sys.stdin).get('droplets', [])
if not droplets:
    print('  No CI droplets found', file=sys.stderr)
    sys.exit(0)
for d in droplets:
    ip = 'no-ip'
    for n in d.get('networks', {}).get('v4', []):
        if n['type'] == 'public':
            ip = n['ip_address']
            break
    print(f'{d[\"id\"]}  {d[\"name\"]}  {d[\"created_at\"]}  {ip}')
" <<< "$data"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  create)    shift; cmd_create "$@" ;;
  destroy)   shift; cmd_destroy "$@" ;;
  wait-ssh)  shift; cmd_wait_ssh "$@" ;;
  run)       shift; cmd_run "$@" ;;
  list)      shift; cmd_list "$@" ;;
  *)         die "Usage: droplet.sh {create|destroy|wait-ssh|run|list} ..." ;;
esac
