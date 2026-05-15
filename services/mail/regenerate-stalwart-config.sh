#!/usr/bin/env bash
set -euo pipefail

cd /opt/email-service

compose=(docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env)

"${compose[@]}" up --force-recreate stalwart-config
"${compose[@]}" up -d --force-recreate stalwart
"${compose[@]}" exec -T stalwart sh -lc 'test -s /opt/stalwart/etc/config.toml && ls -l /opt/stalwart/etc/config.toml'
