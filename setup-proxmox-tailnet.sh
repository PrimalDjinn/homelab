#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

require_root

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/.env"
fi

DOMAIN="${SERVER_HOST:-}"
if [[ -z "$DOMAIN" ]]; then
    error "Set SERVER_HOST to your base domain before joining the Proxmox host to the tailnet."
fi

NETWORK_PREFIX="${HOMELAB_NETWORK_PREFIX:-10.10.10}"
HEADSCALE_CTID="${HEADSCALE_CTID:-112}"
HEADSCALE_IP="${HEADSCALE_IP:-$NETWORK_PREFIX.30}"
HEADSCALE_INTERNAL_URL="http://$HEADSCALE_IP:8080"
HEADSCALE_PREAUTH_KEY_EXPIRATION="${HEADSCALE_PREAUTH_KEY_EXPIRATION:-720h}"
PROXMOX_TAILNET_HOSTNAME="${PROXMOX_TAILNET_HOSTNAME:-$(hostname)}"
STATE_DIR="${STATE_DIR:-/root/homelab}"
SECRETS_DIR="$STATE_DIR/secrets"

mkdir -p "$SECRETS_DIR"
chmod 700 "$STATE_DIR" "$SECRETS_DIR"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Required command missing: $1"
}

quote() {
    printf "%q" "$1"
}

pct_exec() {
    local ctid="$1"
    shift
    pct exec "$ctid" -- bash -lc "$*"
}

wait_for_headscale() {
    info "Waiting for Headscale in LXC $HEADSCALE_CTID"
    for _ in $(seq 1 60); do
        pct_exec "$HEADSCALE_CTID" "docker exec headscale headscale -c /shared/headscale_config.yaml health >/dev/null 2>&1" && return
        sleep 2
    done

    error "Headscale did not become ready in LXC $HEADSCALE_CTID"
}

headscale_preauth_key() {
    local file="$1"
    local key
    local user_id

    if [[ -s "$file" ]]; then
        cat "$file"
        return
    fi

    info "Creating reusable Headscale pre-auth key for the Proxmox host" >&2
    pct_exec "$HEADSCALE_CTID" "docker exec headscale headscale -c /shared/headscale_config.yaml users create admin >/dev/null 2>&1 || true"
    user_id="$(pct_exec "$HEADSCALE_CTID" "docker exec headscale headscale -c /shared/headscale_config.yaml users list -o json | jq -r '.[] | select(.name == \"admin\") | .id' | head -n1")"
    [[ -n "$user_id" && "$user_id" != "null" ]] || error "Could not find Headscale user ID for admin"
    key="$(pct_exec "$HEADSCALE_CTID" "docker exec headscale headscale -c /shared/headscale_config.yaml preauthkeys create --user $(quote "$user_id") --reusable --expiration $(quote "$HEADSCALE_PREAUTH_KEY_EXPIRATION")")"
    [[ -n "$key" ]] || error "Could not create Headscale pre-auth key"

    echo "$key" > "$file"
    chmod 600 "$file"
    cat "$file"
}

install_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        return
    fi

    info "Installing Tailscale on the Proxmox host"
    curl -fsSL https://tailscale.com/install.sh | sh
}

main() {
    local key
    local key_file="$SECRETS_DIR/proxmox-host-preauth-key"

    need_cmd pct
    need_cmd curl
    need_cmd jq
    wait_for_headscale
    key="$(headscale_preauth_key "$key_file")"
    install_tailscale

    info "Joining Proxmox host to Headscale as $PROXMOX_TAILNET_HOSTNAME"
    systemctl enable --now tailscaled
    tailscale up \
        --login-server="$HEADSCALE_INTERNAL_URL" \
        --authkey="$key" \
        --hostname="$PROXMOX_TAILNET_HOSTNAME" \
        --accept-dns=false

    info "Proxmox UI should be reachable from joined tailnet devices at:"
    echo "https://$PROXMOX_TAILNET_HOSTNAME.tailnet.$DOMAIN:8006"
    info "If MagicDNS is not available yet, use the host tailnet IP from: tailscale ip -4"
}

main "$@"
