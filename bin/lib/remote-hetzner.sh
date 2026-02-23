#!/bin/bash
# Hetzner provider adapter for baudbot remote workflows.

_REMOTE_HETZNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/remote-common.sh
source "$_REMOTE_HETZNER_LIB_DIR/remote-common.sh"

REMOTE_HETZNER_API_BASE="${REMOTE_HETZNER_API_BASE:-https://api.hetzner.cloud/v1}"

_remote_http_code_allowed() {
  local code="$1"
  shift
  local allowed
  for allowed in "$@"; do
    if [ "$code" = "$allowed" ]; then
      return 0
    fi
  done
  return 1
}

remote_hetzner_extract_error_message() {
  local response_file="$1"

  if ! [ -s "$response_file" ]; then
    printf 'empty response\n'
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local msg=""
    msg="$(jq -er '.error.message // .message // empty' "$response_file" 2>/dev/null || true)"
    if [ -n "$msg" ]; then
      printf '%s\n' "$msg"
      return 0
    fi
  fi

  head -c 200 "$response_file" 2>/dev/null || true
}

remote_hetzner_request() {
  local token="$1"
  local method="$2"
  local endpoint="$3"
  local body="${4:-}"
  shift 4

  if [ -z "$token" ]; then
    remote_error "Hetzner API token is required"
    return 1
  fi

  local -a allowed_codes
  if [ "$#" -gt 0 ]; then
    allowed_codes=("$@")
  else
    allowed_codes=(200 201 202 204)
  fi

  local response_file http_code curl_rc
  response_file="$(mktemp "${TMPDIR:-/tmp}/baudbot-hetzner-response.XXXXXX")"

  if [ -n "$body" ]; then
    http_code="$(curl -sS -X "$method" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -o "$response_file" \
      -w "%{http_code}" \
      "$REMOTE_HETZNER_API_BASE$endpoint" \
      -d "$body")"
    curl_rc=$?
  else
    http_code="$(curl -sS -X "$method" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -o "$response_file" \
      -w "%{http_code}" \
      "$REMOTE_HETZNER_API_BASE$endpoint")"
    curl_rc=$?
  fi

  if [ "$curl_rc" -ne 0 ]; then
    rm -f "$response_file"
    remote_error "Hetzner API request failed (network or TLS error)"
    return 1
  fi

  if _remote_http_code_allowed "$http_code" "${allowed_codes[@]}"; then
    cat "$response_file"
    rm -f "$response_file"
    return 0
  fi

  local api_error
  api_error="$(remote_hetzner_extract_error_message "$response_file")"
  rm -f "$response_file"

  case "$http_code" in
    401|403)
      remote_error "Hetzner API authentication failed ($http_code): $api_error"
      ;;
    404)
      remote_error "Hetzner API resource not found ($http_code): $api_error"
      ;;
    429)
      remote_error "Hetzner API rate limit hit ($http_code): $api_error"
      ;;
    *)
      remote_error "Hetzner API request failed ($http_code): $api_error"
      ;;
  esac

  return 1
}

remote_hetzner_validate_credentials() {
  local token="$1"
  remote_hetzner_request "$token" GET "/account" "" 200 >/dev/null
}

remote_hetzner_create_ssh_key() {
  local token="$1"
  local name="$2"
  local public_key="$3"

  local payload response ssh_key_id
  payload="$(jq -nc --arg name "$name" --arg public_key "$public_key" '{name: $name, public_key: $public_key}')"
  response="$(remote_hetzner_request "$token" POST "/ssh_keys" "$payload" 201)" || return 1

  ssh_key_id="$(printf '%s' "$response" | jq -er '.ssh_key.id' 2>/dev/null || true)"
  if [ -z "$ssh_key_id" ]; then
    remote_error "Hetzner create SSH key response missing ssh_key.id"
    return 1
  fi

  printf '%s\n' "$ssh_key_id"
}

remote_hetzner_list_ssh_keys() {
  local token="$1"
  remote_hetzner_request "$token" GET "/ssh_keys" "" 200
}

remote_hetzner_find_ssh_key_id_by_name() {
  local token="$1"
  local name="$2"
  local response

  response="$(remote_hetzner_list_ssh_keys "$token")" || return 1
  printf '%s' "$response" | jq -er --arg name "$name" '.ssh_keys[]? | select(.name == $name) | .id' 2>/dev/null || true
}

remote_hetzner_delete_ssh_key() {
  local token="$1"
  local ssh_key_id="$2"

  [ -n "$ssh_key_id" ] || return 0
  remote_hetzner_request "$token" DELETE "/ssh_keys/$ssh_key_id" "" 200 204 404 >/dev/null
}

remote_hetzner_create_server() {
  local token="$1"
  local name="$2"
  local server_type="$3"
  local image="$4"
  local location="$5"
  local ssh_key_id="$6"

  local payload response server_id
  payload="$(jq -nc \
    --arg name "$name" \
    --arg server_type "$server_type" \
    --arg image "$image" \
    --arg location "$location" \
    --argjson ssh_key_id "$ssh_key_id" \
    '{name: $name, server_type: $server_type, image: $image, location: $location, ssh_keys: [$ssh_key_id], start_after_create: true}')"

  response="$(remote_hetzner_request "$token" POST "/servers" "$payload" 201 202)" || return 1

  server_id="$(printf '%s' "$response" | jq -er '.server.id' 2>/dev/null || true)"
  if [ -z "$server_id" ]; then
    remote_error "Hetzner create server response missing server.id"
    return 1
  fi

  printf '%s\n' "$server_id"
}

remote_hetzner_list_servers() {
  local token="$1"
  remote_hetzner_request "$token" GET "/servers" "" 200
}

remote_hetzner_find_server_id_by_name() {
  local token="$1"
  local name="$2"
  local response

  response="$(remote_hetzner_list_servers "$token")" || return 1
  printf '%s' "$response" | jq -er --arg name "$name" '.servers[]? | select(.name == $name) | .id' 2>/dev/null || true
}

remote_hetzner_get_server_ipv4() {
  local token="$1"
  local server_id="$2"
  local response

  response="$(remote_hetzner_request "$token" GET "/servers/$server_id" "" 200)" || return 1
  printf '%s' "$response" | jq -er '.server.public_net.ipv4.ip // empty' 2>/dev/null || true
}

remote_hetzner_wait_server_running() {
  local token="$1"
  local server_id="$2"
  local timeout_seconds="${3:-600}"
  local interval_seconds="${4:-5}"

  local elapsed=0
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    local response status server_ip
    response="$(remote_hetzner_request "$token" GET "/servers/$server_id" "" 200)" || return 1

    status="$(printf '%s' "$response" | jq -er '.server.status // empty' 2>/dev/null || true)"
    server_ip="$(printf '%s' "$response" | jq -er '.server.public_net.ipv4.ip // empty' 2>/dev/null || true)"

    if [ "$status" = "running" ] && [ -n "$server_ip" ]; then
      printf '%s\n' "$server_ip"
      return 0
    fi

    sleep "$interval_seconds"
    elapsed=$((elapsed + interval_seconds))
  done

  remote_error "Timed out waiting for Hetzner server $server_id to become running"
  return 1
}

remote_hetzner_delete_server() {
  local token="$1"
  local server_id="$2"

  [ -n "$server_id" ] || return 0
  remote_hetzner_request "$token" DELETE "/servers/$server_id" "" 200 204 404 >/dev/null
}

provider_validate_credentials() {
  local provider="$1"
  local token="$2"

  case "$provider" in
    hetzner)
      remote_hetzner_validate_credentials "$token"
      ;;
    none|"")
      return 0
      ;;
    *)
      remote_error "unsupported provider: $provider"
      return 1
      ;;
  esac
}

provider_create_ssh_key() {
  local provider="$1"
  shift

  case "$provider" in
    hetzner)
      remote_hetzner_create_ssh_key "$@"
      ;;
    *)
      remote_error "provider_create_ssh_key not supported for provider: $provider"
      return 1
      ;;
  esac
}

provider_create_server() {
  local provider="$1"
  shift

  case "$provider" in
    hetzner)
      remote_hetzner_create_server "$@"
      ;;
    *)
      remote_error "provider_create_server not supported for provider: $provider"
      return 1
      ;;
  esac
}

provider_wait_server_running() {
  local provider="$1"
  shift

  case "$provider" in
    hetzner)
      remote_hetzner_wait_server_running "$@"
      ;;
    *)
      remote_error "provider_wait_server_running not supported for provider: $provider"
      return 1
      ;;
  esac
}

provider_delete_server() {
  local provider="$1"
  shift

  case "$provider" in
    hetzner)
      remote_hetzner_delete_server "$@"
      ;;
    *)
      remote_error "provider_delete_server not supported for provider: $provider"
      return 1
      ;;
  esac
}

provider_delete_ssh_key() {
  local provider="$1"
  shift

  case "$provider" in
    hetzner)
      remote_hetzner_delete_ssh_key "$@"
      ;;
    *)
      remote_error "provider_delete_ssh_key not supported for provider: $provider"
      return 1
      ;;
  esac
}
