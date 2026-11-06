#!/usr/bin/env bash
set -euo pipefail

cd /opt/email-service

compose=(docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env)

"${compose[@]}" run --rm stalwart-config
"${compose[@]}" up -d --force-recreate stalwart
"${compose[@]}" exec -T stalwart sh -lc 'test -s /etc/stalwart/datastore.json && test -s /etc/stalwart/apply-plan.ndjson && ls -l /etc/stalwart/datastore.json /etc/stalwart/apply-plan.ndjson'
./apply-stalwart-plan.sh
