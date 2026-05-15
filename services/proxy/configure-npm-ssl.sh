#!/usr/bin/env bash
set -euo pipefail

NPM_URL="${NPM_URL:-http://127.0.0.1:81}"
NPM_EMAIL="${NPM_EMAIL:?NPM_EMAIL is required}"
NPM_PASSWORD="${NPM_PASSWORD:?NPM_PASSWORD is required}"
AUTH_DOMAIN="${AUTH_DOMAIN:?AUTH_DOMAIN is required}"
HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN:?HEADSCALE_DOMAIN is required}"
HEADPLANE_DOMAIN="${HEADPLANE_DOMAIN:?HEADPLANE_DOMAIN is required}"
OPENPANEL_CLIENT_PANEL_DOMAIN="${OPENPANEL_CLIENT_PANEL_DOMAIN:-}"
MAIL_DOMAIN="${MAIL_DOMAIN:-}"
EMAIL_APP_DOMAIN="${EMAIL_APP_DOMAIN:-}"
WEBMAIL_DOMAIN="${WEBMAIL_DOMAIN:-}"
LISTMONK_DOMAIN="${LISTMONK_DOMAIN:-}"
POSTAL_DOMAIN="${POSTAL_DOMAIN:-}"
LIBREDESK_DOMAIN="${LIBREDESK_DOMAIN:-}"
AUTODISCOVER_DOMAIN="${AUTODISCOVER_DOMAIN:-}"
AUTOCONFIG_DOMAIN="${AUTOCONFIG_DOMAIN:-}"
MTA_STS_DOMAIN="${MTA_STS_DOMAIN:-}"
NPM_DNS_CHALLENGE_PROVIDER="${NPM_DNS_CHALLENGE_PROVIDER:-cloudflare}"
NPM_DNS_PROPAGATION_SECONDS="${NPM_DNS_PROPAGATION_SECONDS:-60}"
NPM_SKIP_CLOUDFLARE_DNS_TOKEN="${NPM_SKIP_CLOUDFLARE_DNS_TOKEN:-false}"
CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-}"

api_body=""
CERT_DOMAINS=("$AUTH_DOMAIN" "$HEADSCALE_DOMAIN" "$HEADPLANE_DOMAIN")
[[ -n "$OPENPANEL_CLIENT_PANEL_DOMAIN" ]] && CERT_DOMAINS+=("$OPENPANEL_CLIENT_PANEL_DOMAIN")
for domain in "$MAIL_DOMAIN" "$EMAIL_APP_DOMAIN" "$WEBMAIL_DOMAIN" "$LISTMONK_DOMAIN" "$POSTAL_DOMAIN" "$LIBREDESK_DOMAIN" "$AUTODISCOVER_DOMAIN" "$AUTOCONFIG_DOMAIN" "$MTA_STS_DOMAIN"; do
    [[ -n "$domain" ]] && CERT_DOMAINS+=("$domain")
done
cert_domains_json="$(printf '%s\n' "${CERT_DOMAINS[@]}" | jq -R . | jq -s 'unique')"

truthy() {
    case "${1,,}" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

use_dns_challenge() {
    [[ "$NPM_DNS_CHALLENGE_PROVIDER" == "cloudflare" ]] && ! truthy "$NPM_SKIP_CLOUDFLARE_DNS_TOKEN"
}

api() {
    local method="$1"
    local path="$2"
    local token="${3:-}"
    local data="${4:-}"
    local body status
    local -a curl_args

    body="$(mktemp)"
    curl_args=(-sS -o "$body" -w '%{http_code}' -X "$method" "$NPM_URL$path" -H 'Content-Type: application/json')
    if [[ -n "$token" ]]; then
        curl_args+=(-H "Authorization: Bearer $token")
    fi

    if [[ -n "$data" ]]; then
        curl_args+=(--data "$data")
    fi

    status="$(curl "${curl_args[@]}")"

    api_body="$(cat "$body")"
    rm -f "$body"

    if [[ ! "$status" =~ ^2 ]]; then
        printf 'NPM API %s %s failed with HTTP %s\n%s\n' "$method" "$path" "$status" "$api_body" >&2
        return 1
    fi

    printf '%s' "$api_body"
}

login_payload="$(
    jq -nc \
        --arg identity "$NPM_EMAIL" \
        --arg secret "$NPM_PASSWORD" \
        '{identity: $identity, secret: $secret}'
)"
token="$(api POST /api/tokens "" "$login_payload" | jq -r '.token // empty')"
if [[ -z "$token" ]]; then
    printf 'NPM login succeeded but no token was returned.\n' >&2
    exit 1
fi

domain_filter='
    map(select(
        . as $cert
        | $cert.provider == "letsencrypt"
        and ([$domains[] | (($cert.domain_names // []) | index(.))] | all)
    ))
    | sort_by(.id)
    | last
    | .id // empty
'

cert_id="$(
    api GET /api/nginx/certificates "$token" |
        jq -r \
            --argjson domains "$cert_domains_json" \
            "$domain_filter"
)"

if [[ -z "$cert_id" ]]; then
    if use_dns_challenge; then
        if [[ -z "$CLOUDFLARE_DNS_API_TOKEN" ]]; then
            printf 'CLOUDFLARE_DNS_API_TOKEN is required inside the NPM SSL helper for Cloudflare DNS-01 certificates. The outer installer fills it from NPM_CLOUDFLARE_DNS_API_TOKEN, CLOUDFLARE_DNS_API_TOKEN, or STALWART_ACME_DNS_CF_SECRET. Set NPM_SKIP_CLOUDFLARE_DNS_TOKEN=true only if you intentionally want HTTP-01 instead.\n' >&2
            exit 1
        fi

        cert_payload="$(
            jq -nc \
                --argjson domains "$cert_domains_json" \
                --arg provider "$NPM_DNS_CHALLENGE_PROVIDER" \
                --arg credentials "# Cloudflare API token"$'\n'"dns_cloudflare_api_token = $CLOUDFLARE_DNS_API_TOKEN" \
                --argjson propagation "$NPM_DNS_PROPAGATION_SECONDS" \
                '{
                    provider: "letsencrypt",
                    nice_name: "homelab services",
                    domain_names: $domains,
                    meta: {
                        dns_challenge: true,
                        dns_provider: $provider,
                        dns_provider_credentials: $credentials,
                        propagation_seconds: $propagation
                    }
                }'
        )"
    else
        cert_payload="$(
            jq -nc \
                --argjson domains "$cert_domains_json" \
                '{
                    provider: "letsencrypt",
                    nice_name: "homelab services",
                    domain_names: $domains,
                    meta: {
                        dns_challenge: false
                    }
                }'
        )"
    fi
    cert_id="$(api POST /api/nginx/certificates "$token" "$cert_payload" | jq -r '.id // empty')"
    if [[ -z "$cert_id" ]]; then
        printf 'NPM certificate creation returned no certificate id.\n' >&2
        exit 1
    fi
fi

hosts="$(api GET /api/nginx/proxy-hosts "$token")"
for domain in "${CERT_DOMAINS[@]}"; do
    host="$(
        printf '%s' "$hosts" |
            jq -c --arg domain "$domain" '.[] | select((.domain_names // []) | index($domain))' |
            head -n1
    )"
    if [[ -z "$host" ]]; then
        printf 'No NPM proxy host found for %s; skipping certificate attach.\n' "$domain" >&2
        continue
    fi

    host_id="$(printf '%s' "$host" | jq -r '.id')"
    update_payload="$(
        printf '%s' "$host" |
            jq -c \
                --argjson cert_id "$cert_id" \
                '{
                    domain_names,
                    forward_scheme,
                    forward_host,
                    forward_port,
                    access_list_id: (.access_list_id // 0),
                    certificate_id: $cert_id,
                    ssl_forced: true,
                    caching_enabled: (.caching_enabled // false),
                    block_exploits: (.block_exploits // true),
                    allow_websocket_upgrade: (.allow_websocket_upgrade // true),
                    http2_support: true,
                    hsts_enabled: false,
                    hsts_subdomains: false,
                    meta: (.meta // {}),
                    advanced_config: (.advanced_config // ""),
                    locations: (.locations // [])
                }'
    )"
    api PUT "/api/nginx/proxy-hosts/$host_id" "$token" "$update_payload" >/dev/null
done

printf 'NPM certificate %s is attached to homelab proxy hosts.\n' "$cert_id"
