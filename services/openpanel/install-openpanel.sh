#!/usr/bin/env bash
set -euo pipefail

if command -v opencli >/dev/null 2>&1; then
    echo "OpenPanel is already installed"
    exit 0
fi

if [[ -f /.dockerenv || -f /run/.containerenv ]] || tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qi '^container='; then
    cat >&2 <<'EOF'
OpenPanel upstream does not support installation inside containers/LXCs.
Use a dedicated VM for OpenPanel, then point the homelab NPM sync at that VM's internal IP.
EOF
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl

bash <(curl -sSL https://openpanel.org) "$@"
