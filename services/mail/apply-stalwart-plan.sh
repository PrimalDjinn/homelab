#!/usr/bin/env bash
set -euo pipefail

cd /opt/email-service

set -a
# shellcheck disable=SC1091
source .env
set +a

compose=(docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env)
network="${COMPOSE_PROJECT_NAME:-email-service}_default"
plan_file="$(mktemp)"
trap 'rm -f "$plan_file"' EXIT

hostname="${STALWART_HOSTNAME:-mail.example.com}"
domain="${STALWART_DEFAULT_DOMAIN:-}"
if [[ -z "$domain" ]]; then
  if [[ "$hostname" == *.* ]]; then
    domain="${hostname#*.}"
  else
    domain="$hostname"
  fi
fi

"${compose[@]}" exec -T stalwart sh -lc 'cat /etc/stalwart/apply-plan.ndjson' \
  | grep -v '"object":"Bootstrap"' \
  | grep -v '"object":"AcmeProvider"' \
  | grep -v '"object":"NetworkListener"' > "$plan_file"

docker run --rm \
  --network "$network" \
  -e STALWART_ADMIN_USER \
  -e STALWART_ADMIN_PASSWORD \
  -e STALWART_HOSTNAME="$hostname" \
  -e STALWART_DEFAULT_DOMAIN="$domain" \
  -e PLAN_FILE=/plan.ndjson \
  -v "$plan_file:/plan.ndjson:rw" \
  -v /opt/email-service/scripts/stalwart-homelab/apply-inside.sh:/apply-inside.sh:ro \
  alpine:3.20 sh /apply-inside.sh

"${compose[@]}" restart stalwart
