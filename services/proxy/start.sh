#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p data letsencrypt
chown -R 0:0 data letsencrypt
chmod -R u+rwX data letsencrypt
docker compose up -d
