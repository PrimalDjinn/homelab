#!/usr/bin/env bash
set -euo pipefail

DOKPLOY_URL="${DOKPLOY_URL:-http://127.0.0.1:3000}"
DOKPLOY_API_BASE="${DOKPLOY_API_BASE:-$DOKPLOY_URL/api}"
DOKPLOY_ADMIN_EMAIL="${DOKPLOY_ADMIN_EMAIL:?DOKPLOY_ADMIN_EMAIL is required}"
DOKPLOY_ADMIN_PASSWORD="${DOKPLOY_ADMIN_PASSWORD:?DOKPLOY_ADMIN_PASSWORD is required}"
DOKPLOY_ADMIN_FIRST_NAME="${DOKPLOY_ADMIN_FIRST_NAME:-Homelab}"
DOKPLOY_ADMIN_LAST_NAME="${DOKPLOY_ADMIN_LAST_NAME:-Admin}"
DOKPLOY_API_TOKEN_FILE="${DOKPLOY_API_TOKEN_FILE:-/etc/homelab/dokploy-api-key}"
DOKPLOY_API_KEY_NAME="${DOKPLOY_API_KEY_NAME:-homelab-domain-sync}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required command missing: $1" >&2
        exit 1
    }
}

api_key_works() {
    local token="$1"
    curl -fsS \
        -H "x-api-key: $token" \
        -H 'Content-Type: application/json' \
        "$DOKPLOY_API_BASE/user.get" >/dev/null 2>&1
}

wait_for_dokploy() {
    for _ in $(seq 1 90); do
        curl -fsS "$DOKPLOY_API_BASE/trpc/settings.health" >/dev/null 2>&1 && return 0
        curl -fsS "$DOKPLOY_URL" >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo "Dokploy did not become ready at $DOKPLOY_URL" >&2
    exit 1
}

post_auth() {
    local path="$1"
    local data="$2"
    curl -fsS \
        -c "$COOKIE_JAR" \
        -b "$COOKIE_JAR" \
        -H 'Content-Type: application/json' \
        -X POST \
        --data "$data" \
        "$DOKPLOY_API_BASE/auth/$path"
}

signed_in() {
    curl -fsS \
        -b "$COOKIE_JAR" \
        -H 'Content-Type: application/json' \
        "$DOKPLOY_API_BASE/user.get" >/dev/null 2>&1
}

organization_id() {
    curl -fsS \
        -b "$COOKIE_JAR" \
        -H 'Content-Type: application/json' \
        "$DOKPLOY_API_BASE/user.get" | \
        jq -r '.. | objects | .organizationId? // empty' | head -n1
}

create_api_key() {
    local org_id="$1"
    curl -fsS \
        -b "$COOKIE_JAR" \
        -H 'Content-Type: application/json' \
        -X POST \
        --data "$(jq -nc --arg name "$DOKPLOY_API_KEY_NAME" --arg organizationId "$org_id" '{name:$name,metadata:{organizationId:$organizationId},rateLimitEnabled:false}')" \
        "$DOKPLOY_API_BASE/user.createApiKey" | \
        jq -r '.. | objects | .key? // empty' | head -n1
}

need_cmd curl
need_cmd jq
mkdir -p "$(dirname "$DOKPLOY_API_TOKEN_FILE")"
chmod 700 "$(dirname "$DOKPLOY_API_TOKEN_FILE")"

if [[ -s "$DOKPLOY_API_TOKEN_FILE" ]] && api_key_works "$(cat "$DOKPLOY_API_TOKEN_FILE")"; then
    cat "$DOKPLOY_API_TOKEN_FILE"
    exit 0
fi

wait_for_dokploy
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

signup_payload="$(jq -nc \
    --arg email "$DOKPLOY_ADMIN_EMAIL" \
    --arg password "$DOKPLOY_ADMIN_PASSWORD" \
    --arg name "$DOKPLOY_ADMIN_FIRST_NAME" \
    --arg lastName "$DOKPLOY_ADMIN_LAST_NAME" \
    '{email:$email,password:$password,name:$name,lastName:$lastName}')"

signin_payload="$(jq -nc \
    --arg email "$DOKPLOY_ADMIN_EMAIL" \
    --arg password "$DOKPLOY_ADMIN_PASSWORD" \
    '{email:$email,password:$password}')"

post_auth 'sign-up/email' "$signup_payload" >/dev/null 2>&1 || true
if ! signed_in; then
    post_auth 'sign-in/email' "$signin_payload" >/dev/null
fi

org_id="$(organization_id)"
if [[ -z "$org_id" ]]; then
    echo "Could not determine Dokploy organization ID after login" >&2
    exit 1
fi

token="$(create_api_key "$org_id")"
if [[ -z "$token" ]]; then
    echo "Dokploy API key creation returned no key" >&2
    exit 1
fi

printf '%s\n' "$token" > "$DOKPLOY_API_TOKEN_FILE"
chmod 600 "$DOKPLOY_API_TOKEN_FILE"
printf '%s\n' "$token"
