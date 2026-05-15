#!/usr/bin/env bash
set -euo pipefail

if command -v opencli >/dev/null 2>&1; then
    echo "OpenPanel is already installed"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl

bash <(curl -sSL https://openpanel.org)
