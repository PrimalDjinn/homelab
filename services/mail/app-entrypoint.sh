#!/bin/sh
set -e
if [ -x /homelab/patch-allowed-domains.sh ]; then
  /homelab/patch-allowed-domains.sh || echo "warn: allowed-domains patch failed" >&2
elif [ -f /homelab/patch-allowed-domains.sh ]; then
  sh /homelab/patch-allowed-domains.sh || echo "warn: allowed-domains patch failed" >&2
fi
exec /app/docker-entrypoint.sh "$@"
