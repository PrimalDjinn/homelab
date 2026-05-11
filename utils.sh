RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

pm () {
    if command -v apt >/dev/null 2>&1; then
        apt "$@"
        elif command -v dnf >/dev/null 2>&1; then
        dnf "$@"
        elif command -v yum >/dev/null 2>&1; then
        yum "$@"
    else
        echo "No supported package manager found" >&2
        return 1
    fi
}

update_server () {
    pm update && pm upgrade
}

get_ip() {
    local ip=""
    
    # Try IPv4 first
    # First attempt: ifconfig.io
    ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
    
    # Second attempt: icanhazip.com
    if [ -z "$ip" ]; then
        ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
    fi
    
    # Third attempt: ipecho.net
    if [ -z "$ip" ]; then
        ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
    fi
    
    # If no IPv4, try IPv6
    if [ -z "$ip" ]; then
        # Try IPv6 with ifconfig.io
        ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        
        # Try IPv6 with icanhazip.com
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        
        # Try IPv6 with ipecho.net
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi
    fi
    
    if [ -z "$ip" ]; then
        echo "Error: Could not determine server IP address automatically (neither IPv4 nor IPv6)." >&2
        echo "Please set the ADVERTISE_ADDR environment variable manually." >&2
        echo "Example: export ADVERTISE_ADDR=<your-server-ip>" >&2
        exit 1
    fi
    
    echo "$ip"
}

get_private_ip() {
    ip addr show | grep -E "inet (192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)" | head -n1 | awk '{print $2}' | cut -d/ -f1
}


require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi
}


free_mail_ports() {
    set -eu

    PORTS="25 110 143 465 587 993 995 4190"
    COMMON_SERVICES="postfix exim4 dovecot courier-imap courier-pop"

    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Free the standard Stalwart mail ports on a Linux host.

Usage:
  sudo ./scripts/stalwart/free-ports.sh

What it does:
  1. Stops common host mail services if they exist.
  2. Stops Docker containers publishing the Stalwart mail ports.
  3. Kills any remaining listeners on those ports.

Ports:
  25 110 143 465 587 993 995 4190
EOF
        exit 0
    fi

    if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root or with sudo."
    exit 1
    fi

    echo "Checking current listeners on: $PORTS"
    ss -ltnp | grep -E ':(25|110|143|465|587|993|995|4190)\s' || true

    if command -v systemctl >/dev/null 2>&1; then
    for service in $COMMON_SERVICES; do
        if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$service"; then
            echo "Stopping service: $service"
            systemctl stop "$service"
        fi

        if systemctl is-enabled --quiet "$service" >/dev/null 2>&1; then
            echo "Disabling service: $service"
            systemctl disable "$service" >/dev/null 2>&1 || true
        fi
        fi
    done
    fi

    if command -v docker >/dev/null 2>&1; then
    container_ids="$(docker ps --format '{{.ID}} {{.Ports}}' | grep -E '(:25->|:110->|:143->|:465->|:587->|:993->|:995->|:4190->)' | awk '{print $1}' || true)"

    if [ -n "$container_ids" ]; then
        echo "Stopping Docker containers using Stalwart mail ports"
        echo "$container_ids" | xargs docker stop
    fi
    fi

    if command -v fuser >/dev/null 2>&1; then
    echo "Killing remaining listeners on Stalwart mail ports"
    fuser -k 25/tcp 110/tcp 143/tcp 465/tcp 587/tcp 993/tcp 995/tcp 4190/tcp >/dev/null 2>&1 || true
    else
    echo "fuser is not installed; skipping process termination step."
    fi

    echo "Remaining listeners after cleanup:"
    ss -ltnp | grep -E ':(25|110|143|465|587|993|995|4190)\s' || true

    echo "Done. You can retry: docker compose -f ./docker-compose.prod.yml --env-file .env up -d"
}