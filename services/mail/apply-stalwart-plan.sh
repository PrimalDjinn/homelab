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

"${compose[@]}" exec -T stalwart sh -lc 'cat /etc/stalwart/apply-plan.ndjson' \
  | grep -v '"object":"Bootstrap"' \
  | grep -v '"object":"AcmeProvider"' \
  | grep -v '"object":"NetworkListener"' > "$plan_file"

docker run --rm \
  --network "$network" \
  -e STALWART_ADMIN_USER \
  -e STALWART_ADMIN_PASSWORD \
  -v "$plan_file:/plan.ndjson:ro" \
  alpine:3.20 sh -lc '
    apk add --no-cache ca-certificates curl >/dev/null
    curl --proto "=https" --tlsv1.2 -LsSf https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh >/dev/null
    /root/.cargo/bin/stalwart-cli \
      --url http://stalwart:8080 \
      --user "$STALWART_ADMIN_USER" \
      --password "$STALWART_ADMIN_PASSWORD" \
      apply --file /plan.ndjson --no-color
  '

"${compose[@]}" restart stalwart
