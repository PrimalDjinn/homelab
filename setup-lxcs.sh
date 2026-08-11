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
    error "Set SERVER_HOST to your base domain before provisioning service LXCs."
fi

secret_file() {
    local file="$1"
    local length="${2:-32}"
    if [[ ! -s "$file" ]]; then
        random_token "$length" > "$file"
        chmod 600 "$file"
    fi
    cat "$file"
}

strong_secret_file() {
    local file="$1"
    local length="${2:-24}"
    local value

    if [[ -s "$file" ]]; then
        value="$(cat "$file")"
    fi

    if [[ ! "${value:-}" =~ [A-Z] || ! "${value:-}" =~ [a-z] || ! "${value:-}" =~ [0-9] || ! "${value:-}" =~ [^a-zA-Z0-9] || ${#value} -lt 10 || ${#value} -gt 72 ]]; then
        value="A1!$(random_token "$((length - 3))")"
        printf '%s\n' "$value" > "$file"
        chmod 600 "$file"
    fi
    cat "$file"
}

VM_BRIDGE="${HOMELAB_BRIDGE:-vmbr10}"
NETWORK_PREFIX="${HOMELAB_NETWORK_PREFIX:-10.10.10}"
GATEWAY_IP="${HOMELAB_GATEWAY_IP:-$NETWORK_PREFIX.1}"
HOMELAB_IPV6_MODE="${HOMELAB_IPV6_MODE:-disabled}"
HOMELAB_FORCE_IPV4="${HOMELAB_FORCE_IPV4:-true}"
HOMELAB_DISABLE_IPV6_IN_LXCS="${HOMELAB_DISABLE_IPV6_IN_LXCS:-true}"
HOMELAB_DNS_SERVERS="${HOMELAB_DNS_SERVERS:-$GATEWAY_IP 1.1.1.1 9.9.9.9}"
HOMELAB_DOCKER_DNS_SERVERS="${HOMELAB_DOCKER_DNS_SERVERS:-$GATEWAY_IP 1.1.1.1 9.9.9.9}"
HOMELAB_NETWORK_DIAGNOSTICS="${HOMELAB_NETWORK_DIAGNOSTICS:-false}"
HOMELAB_PRUNE_MANAGED_NPM_HOSTS="${HOMELAB_PRUNE_MANAGED_NPM_HOSTS:-false}"
PROXY_CTID="${PROXY_CTID:-110}"
AUTH_CTID="${AUTH_CTID:-111}"
HEADSCALE_CTID="${HEADSCALE_CTID:-112}"
MAIL_CTID="${MAIL_CTID:-113}"
OPENPANEL_VMID="${OPENPANEL_VMID:-114}"
DOKPLOY_CTID="${DOKPLOY_CTID:-115}"
PROXY_IP="${PROXY_IP:-$NETWORK_PREFIX.10}"
PROXY_TAILNET_IP="${PROXY_TAILNET_IP:-}"
AUTH_IP="${AUTH_IP:-$NETWORK_PREFIX.20}"
HEADSCALE_IP="${HEADSCALE_IP:-$NETWORK_PREFIX.30}"
MAIL_IP="${MAIL_IP:-$NETWORK_PREFIX.40}"
OPENPANEL_IP="${OPENPANEL_IP:-$NETWORK_PREFIX.50}"
DOKPLOY_IP="${DOKPLOY_IP:-$NETWORK_PREFIX.60}"
PROXY_HOSTNAME="${PROXY_HOSTNAME:-homelab-proxy}"
AUTH_HOSTNAME="${AUTH_HOSTNAME:-homelab-auth}"
HEADSCALE_HOSTNAME="${HEADSCALE_HOSTNAME:-homelab-headscale}"
MAIL_HOSTNAME="${MAIL_HOSTNAME:-homelab-mail}"
OPENPANEL_HOSTNAME="${OPENPANEL_HOSTNAME:-homelab-openpanel}"
DOKPLOY_HOSTNAME="${DOKPLOY_HOSTNAME:-homelab-dokploy}"
OPENPANEL_PROVISION_LXC="${OPENPANEL_PROVISION_LXC:-false}"
OPENPANEL_PROVISION_VM="${OPENPANEL_PROVISION_VM:-true}"
OPENPANEL_VM_INSTALL_METHOD="${OPENPANEL_VM_INSTALL_METHOD:-cloud-image}"
OPENPANEL_CLOUD_IMAGE_URL="${OPENPANEL_CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
OPENPANEL_ISO="${OPENPANEL_ISO:-auto}"
OPENPANEL_ISO_STORAGE="${OPENPANEL_ISO_STORAGE:-auto}"
OPENPANEL_VM_STORAGE="${OPENPANEL_VM_STORAGE:-auto}"
OPENPANEL_SSH_USER="${OPENPANEL_SSH_USER:-openpanel}"
PROXY_DOMAIN="${PROXY_DOMAIN:-proxy.$DOMAIN}"
AUTH_DOMAIN="${AUTH_DOMAIN:-auth.$DOMAIN}"
HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN:-headscale.$DOMAIN}"
HEADPLANE_DOMAIN="${HEADPLANE_DOMAIN:-headplane.$DOMAIN}"
OPENPANEL_CLIENT_PANEL_DOMAIN="${OPENPANEL_CLIENT_PANEL_DOMAIN:-openpanel.$DOMAIN}"
OPENPANEL_ADMIN_DOMAIN="${OPENPANEL_ADMIN_DOMAIN:-openadmin.$DOMAIN}"
DOKPLOY_DOMAIN="${DOKPLOY_DOMAIN:-dokploy.$DOMAIN}"
MAIL_DOMAIN="${MAIL_DOMAIN:-mail.$DOMAIN}"
EMAIL_APP_DOMAIN="${EMAIL_APP_DOMAIN:-email.$DOMAIN}"
WEBMAIL_DOMAIN="${WEBMAIL_DOMAIN:-webmail.$DOMAIN}"
LISTMONK_DOMAIN="${LISTMONK_DOMAIN:-listmonk.$DOMAIN}"
POSTAL_DOMAIN="${POSTAL_DOMAIN:-postal.$DOMAIN}"
LIBREDESK_DOMAIN="${LIBREDESK_DOMAIN:-libredesk.$DOMAIN}"
AUTODISCOVER_DOMAIN="${AUTODISCOVER_DOMAIN:-autodiscover.$DOMAIN}"
AUTOCONFIG_DOMAIN="${AUTOCONFIG_DOMAIN:-autoconfig.$DOMAIN}"
MTA_STS_DOMAIN="${MTA_STS_DOMAIN:-mta-sts.$DOMAIN}"
LE_EMAIL="${LE_EMAIL:-admin@$DOMAIN}"
AUTH_PORT="${AUTH_PORT:-9000}"
AUTHENTIK_MEMORY_MB="${AUTHENTIK_MEMORY_MB:-3072}"
AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-admin@$DOMAIN}"
AUTHENTIK_BOOTSTRAP_PASSWORD="${AUTHENTIK_BOOTSTRAP_PASSWORD:-}"
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
AUTHENTIK_IMAGE="${AUTHENTIK_IMAGE:-ghcr.io/goauthentik/server}"
AUTHENTIK_TAG="${AUTHENTIK_TAG:-2026.2.3}"
AUTHENTIK_POSTGRES_USER="${AUTHENTIK_POSTGRES_USER:-authentik}"
AUTHENTIK_POSTGRES_DB="${AUTHENTIK_POSTGRES_DB:-authentik}"
AUTHENTIK_EMAIL__HOST="${AUTHENTIK_EMAIL__HOST:-}"
AUTHENTIK_EMAIL__PORT="${AUTHENTIK_EMAIL__PORT:-587}"
AUTHENTIK_EMAIL__USERNAME="${AUTHENTIK_EMAIL__USERNAME:-}"
AUTHENTIK_EMAIL__PASSWORD="${AUTHENTIK_EMAIL__PASSWORD:-}"
AUTHENTIK_EMAIL__FROM="${AUTHENTIK_EMAIL__FROM:-Authentik <noreply@$DOMAIN>}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-$LE_EMAIL}"
NPM_PASSWORD="${NPM_PASSWORD:-${NPM_DEFAULT_PASSWORD:-}}"
NPM_DNS_CHALLENGE_PROVIDER="${NPM_DNS_CHALLENGE_PROVIDER:-cloudflare}"
NPM_DNS_PROPAGATION_SECONDS="${NPM_DNS_PROPAGATION_SECONDS:-60}"
NPM_SKIP_CLOUDFLARE_DNS_TOKEN="${NPM_SKIP_CLOUDFLARE_DNS_TOKEN:-false}"
CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-}"
NPM_CLOUDFLARE_DNS_API_TOKEN="${NPM_CLOUDFLARE_DNS_API_TOKEN:-${CLOUDFLARE_DNS_API_TOKEN:-${STALWART_ACME_DNS_CF_SECRET:-}}}"
STALWART_ACME_ENABLED="${STALWART_ACME_ENABLED:-true}"
STALWART_ACME_DNS_PROVIDER="${STALWART_ACME_DNS_PROVIDER:-cloudflare}"
STALWART_ACME_DNS_CF_SECRET="${STALWART_ACME_DNS_CF_SECRET:-}"
EMAIL_SERVICE_REPO="${EMAIL_SERVICE_REPO:-https://github.com/ChibaLLC/email-service}"
EMAIL_SERVICE_REF="${EMAIL_SERVICE_REF:-main}"
MAIL_PORTS="${MAIL_PORTS:-25 110 143 465 587 993 995 4190}"
HEADSCALE_PREAUTH_KEY_EXPIRATION="${HEADSCALE_PREAUTH_KEY_EXPIRATION:-720h}"
HEADSCALE_PUBLIC_URL="https://$HEADSCALE_DOMAIN"
HEADSCALE_INTERNAL_URL="http://$HEADSCALE_IP:8080"
OPENPANEL_MEMORY_MB="${OPENPANEL_MEMORY_MB:-auto}"
OPENPANEL_MIN_MEMORY_MB="${OPENPANEL_MIN_MEMORY_MB:-2048}"
OPENPANEL_MAX_MEMORY_MB="${OPENPANEL_MAX_MEMORY_MB:-4096}"
OPENPANEL_HOST_RESERVE_MB="${OPENPANEL_HOST_RESERVE_MB:-4096}"
OPENPANEL_DIAGNOSTIC_VM_RESERVE_MB="${OPENPANEL_DIAGNOSTIC_VM_RESERVE_MB:-0}"
OPENPANEL_CORES="${OPENPANEL_CORES:-auto}"
OPENPANEL_CPU_RESERVE="${OPENPANEL_CPU_RESERVE:-2}"
OPENPANEL_MAX_CORES="${OPENPANEL_MAX_CORES:-2}"
OPENPANEL_DISK_GB="${OPENPANEL_DISK_GB:-120}"
DOKPLOY_MEMORY_MB="${DOKPLOY_MEMORY_MB:-auto}"
DOKPLOY_MIN_MEMORY_MB="${DOKPLOY_MIN_MEMORY_MB:-4096}"
DOKPLOY_HOST_RESERVE_MB="${DOKPLOY_HOST_RESERVE_MB:-4096}"
DOKPLOY_CORES="${DOKPLOY_CORES:-auto}"
DOKPLOY_DISK_GB="${DOKPLOY_DISK_GB:-80}"
DOKPLOY_PORT="${DOKPLOY_PORT:-3000}"
DOKPLOY_INSTALL_URL="${DOKPLOY_INSTALL_URL:-https://dokploy.com/install.sh}"
DOKPLOY_API_TOKEN="${DOKPLOY_API_TOKEN:-}"
DOKPLOY_ADMIN_EMAIL="${DOKPLOY_ADMIN_EMAIL:-admin@$DOMAIN}"
DOKPLOY_ADMIN_PASSWORD="${DOKPLOY_ADMIN_PASSWORD:-}"
DOKPLOY_ADMIN_FIRST_NAME="${DOKPLOY_ADMIN_FIRST_NAME:-Homelab}"
DOKPLOY_ADMIN_LAST_NAME="${DOKPLOY_ADMIN_LAST_NAME:-Admin}"
DOKPLOY_NPM_SYNC_INTERVAL_SECONDS="${DOKPLOY_NPM_SYNC_INTERVAL_SECONDS:-60}"
DOKPLOY_NPM_AUTO_CERTS="${DOKPLOY_NPM_AUTO_CERTS:-true}"
DOKPLOY_NPM_FORWARD_SCHEME="${DOKPLOY_NPM_FORWARD_SCHEME:-http}"
DOKPLOY_NPM_FORWARD_PORT="${DOKPLOY_NPM_FORWARD_PORT:-80}"
DOKPLOY_CLOUDFLARE_DNS_API_TOKEN="${DOKPLOY_CLOUDFLARE_DNS_API_TOKEN:-${CLOUDFLARE_DNS_API_TOKEN:-${NPM_CLOUDFLARE_DNS_API_TOKEN:-${STALWART_ACME_DNS_CF_SECRET:-}}}}"
DOKPLOY_CLOUDFLARE_DNS_TARGET="${DOKPLOY_CLOUDFLARE_DNS_TARGET:-}"
DOKPLOY_CLOUDFLARE_DNS_ZONES="${DOKPLOY_CLOUDFLARE_DNS_ZONES:-}"
DOKPLOY_CLOUDFLARE_DNS_PROXIED="${DOKPLOY_CLOUDFLARE_DNS_PROXIED:-false}"
DOKPLOY_CLOUDFLARE_DNS_TTL="${DOKPLOY_CLOUDFLARE_DNS_TTL:-1}"
OPENPANEL_PUBLIC_BACKEND_PORT="${OPENPANEL_PUBLIC_BACKEND_PORT:-80}"
OPENPANEL_CLIENT_PANEL_PORT="${OPENPANEL_CLIENT_PANEL_PORT:-2083}"
OPENPANEL_CLIENT_PANEL_SCHEME="${OPENPANEL_CLIENT_PANEL_SCHEME:-http}"
OPENPANEL_NPM_SYNC_INTERVAL_SECONDS="${OPENPANEL_NPM_SYNC_INTERVAL_SECONDS:-60}"
OPENPANEL_NPM_AUTO_CERTS="${OPENPANEL_NPM_AUTO_CERTS:-true}"
OPENPANEL_CLOUDFLARE_DNS_API_TOKEN="${OPENPANEL_CLOUDFLARE_DNS_API_TOKEN:-${CLOUDFLARE_DNS_API_TOKEN:-${NPM_CLOUDFLARE_DNS_API_TOKEN:-${STALWART_ACME_DNS_CF_SECRET:-}}}}"
OPENPANEL_CLOUDFLARE_DNS_TARGET="${OPENPANEL_CLOUDFLARE_DNS_TARGET:-}"
OPENPANEL_CLOUDFLARE_DNS_ZONES="${OPENPANEL_CLOUDFLARE_DNS_ZONES:-}"
OPENPANEL_CLOUDFLARE_DNS_PROXIED="${OPENPANEL_CLOUDFLARE_DNS_PROXIED:-false}"
OPENPANEL_CLOUDFLARE_DNS_TTL="${OPENPANEL_CLOUDFLARE_DNS_TTL:-1}"
STATE_DIR="${STATE_DIR:-/root/homelab}"
SECRETS_DIR="$STATE_DIR/secrets"
GENERATED_DIR="$STATE_DIR/generated"
SERVICES_DIR="$SCRIPT_DIR/services"

mkdir -p "$SECRETS_DIR" "$GENERATED_DIR"
chmod 700 "$STATE_DIR" "$SECRETS_DIR" "$GENERATED_DIR"
NPM_PASSWORD="${NPM_PASSWORD:-$(secret_file "$SECRETS_DIR/npm-admin-password" 32)}"
NPM_DEFAULT_PASSWORD="$NPM_PASSWORD"
NPM_LOGIN_EMAIL="$NPM_ADMIN_EMAIL"
NPM_LOGIN_PASSWORD="$NPM_PASSWORD"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Required command missing: $1"
}

validate_homelab_network_mode() {
    case "$HOMELAB_IPV6_MODE" in
        disabled)
            ;;
        future)
            warn "HOMELAB_IPV6_MODE=future is a placeholder only. IPv6 enablement is still TODO; keeping IPv4-only defaults."
            ;;
        *)
            error "Unsupported HOMELAB_IPV6_MODE: $HOMELAB_IPV6_MODE (allowed: disabled, future)"
            ;;
    esac
}

docker_dns_servers_json() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' $HOMELAB_DOCKER_DNS_SERVERS
}

diagnose_lxc_networking() {
    local ctid="$1"

    info "Running networking diagnostics in LXC $ctid"
    pct_exec "$ctid" 'hostname; ip -4 route; ip -6 route || true; cat /etc/resolv.conf; getent ahostsv4 google.com || true; getent ahostsv6 google.com || true; curl -4 -I https://google.com || true; curl -6 -I https://google.com || true'
}

configure_lxc_ipv4_only_networking() {
    local ctid="$1"

    info "Configuring IPv4-safe networking defaults in LXC $ctid"
    pct_exec "$ctid" "set -eu
touch /etc/gai.conf
tmp_gai=\$(mktemp)
awk '
    /^# BEGIN HOMELAB IPV4 PREFERENCE$/ { skip = 1; next }
    /^# END HOMELAB IPV4 PREFERENCE$/ { skip = 0; next }
    !skip { print }
' /etc/gai.conf > \"\$tmp_gai\"
cat >> \"\$tmp_gai\" <<'EOF'
# BEGIN HOMELAB IPV4 PREFERENCE
precedence ::ffff:0:0/96  100
# END HOMELAB IPV4 PREFERENCE
EOF
if ! cmp -s \"\$tmp_gai\" /etc/gai.conf; then
    cp \"\$tmp_gai\" /etc/gai.conf
fi
rm -f \"\$tmp_gai\"

if [[ $(quote "$HOMELAB_FORCE_IPV4") == true ]]; then
    cat > /etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 \"true\";
EOF
else
    rm -f /etc/apt/apt.conf.d/99force-ipv4
fi

sysctl_written=false
if [[ $(quote "$HOMELAB_DISABLE_IPV6_IN_LXCS") == true ]]; then
    tmp_sysctl=\$(mktemp)
    cat > \"\$tmp_sysctl\" <<'EOF'
# Managed by homelab setup-lxcs.sh.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    if [[ ! -f /etc/sysctl.d/99-homelab-ipv4-only.conf ]] || ! cmp -s \"\$tmp_sysctl\" /etc/sysctl.d/99-homelab-ipv4-only.conf; then
        cp \"\$tmp_sysctl\" /etc/sysctl.d/99-homelab-ipv4-only.conf
        sysctl_written=true
    fi
    rm -f \"\$tmp_sysctl\"
else
    had_sysctl_file=false
    [[ -f /etc/sysctl.d/99-homelab-ipv4-only.conf ]] && had_sysctl_file=true
    rm -f /etc/sysctl.d/99-homelab-ipv4-only.conf
    if [[ \"\$had_sysctl_file\" == true ]]; then
        if ! sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1; then
            echo '[!] Could not restore net.ipv6.conf.all.disable_ipv6=0; key may be unavailable in this LXC.'
        fi
        if ! sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1; then
            echo '[!] Could not restore net.ipv6.conf.default.disable_ipv6=0; key may be unavailable in this LXC.'
        fi
    fi
fi

if [[ \"\$sysctl_written\" == true ]]; then
    if ! sysctl --system; then
        echo '[!] sysctl --system reported unavailable keys or non-fatal apply errors; continuing with IPv4 preference only.'
    fi
fi

ip -4 route
ip -6 route || true
getent ahostsv4 deb.debian.org || true"
}

ensure_host_python() {
    if command -v python3 >/dev/null 2>&1; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        info "Installing python3 on the Proxmox host for config rendering"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3
        return
    fi

    error "python3 is required for config rendering and could not be installed automatically."
}

ensure_host_jq() {
    if command -v jq >/dev/null 2>&1; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        info "Installing jq on the Proxmox host for API payload handling"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq
        return
    fi

    error "jq is required for API payload handling and could not be installed automatically."
}

ensure_host_curl() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        info "Installing curl on the Proxmox host"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl
        return
    fi

    error "curl is required to download the OpenPanel cloud image."
}

ensure_host_genisoimage() {
    if command -v genisoimage >/dev/null 2>&1; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        info "Installing genisoimage on the Proxmox host for OpenPanel VM seed ISO"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y genisoimage
        return
    fi

    error "genisoimage is required to create the OpenPanel VM unattended seed ISO."
}

random_token() {
    openssl rand -hex "$(((${1:-32} + 1) / 2))" | cut -c "1-${1:-32}"
}

ensure_ssh_keypair() {
    local key_file="$SECRETS_DIR/openpanel-vm-ed25519"

    if [[ ! -s "$key_file" ]]; then
        ssh-keygen -t ed25519 -N '' -f "$key_file" -C "homelab-openpanel" >/dev/null
        chmod 600 "$key_file"
    fi

    echo "$key_file"
}

quote() {
    printf "%q" "$1"
}

pct_exec() {
    local ctid="$1"
    shift
    pct exec "$ctid" -- bash -lc "$*"
}

free_mail_ports_in_lxc() {
    local ctid="$1"

    pct_exec "$ctid" '
        set -eu
        ports="25 110 143 465 587 993 995 4190"
        services="postfix exim4 dovecot courier-imap courier-pop"

        if command -v systemctl >/dev/null 2>&1; then
            for service in $services; do
                if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
                    systemctl stop "$service" >/dev/null 2>&1 || true
                    systemctl disable "$service" >/dev/null 2>&1 || true
                fi
            done
        fi

        if command -v docker >/dev/null 2>&1; then
            container_ids="$(docker ps --format "{{.ID}} {{.Ports}}" | grep -E "(:25->|:110->|:143->|:465->|:587->|:993->|:995->|:4190->)" | awk "{print \$1}" || true)"
            if [ -n "$container_ids" ]; then
                echo "$container_ids" | xargs docker stop
            fi
        fi

        if command -v fuser >/dev/null 2>&1; then
            for port in $ports; do
                fuser -k "$port/tcp" >/dev/null 2>&1 || true
            done
        fi
    '
}

wait_for_lxc() {
    local ctid="$1"

    for _ in $(seq 1 60); do
        pct_exec "$ctid" "true" >/dev/null 2>&1 && return
        sleep 2
    done

    error "LXC $ctid did not become ready in time"
}

copy_dir_to_lxc() {
    local ctid="$1" src="$2" dest="$3"

    pct_exec "$ctid" "rm -rf $(quote "$dest") && mkdir -p $(quote "$dest")"
    tar -C "$src" -cf - . | pct exec "$ctid" -- tar -C "$dest" -xf -
}

require_proxmox() {
    need_cmd pct
    need_cmd qm
    need_cmd pveam
    need_cmd pvesm
    need_cmd openssl
    ensure_host_python
    ensure_host_jq
    ensure_host_curl
    ensure_host_genisoimage
    require_pve_config_fs
}

require_pve_config_fs() {
    local node
    local node_dir
    local lxc_dir
    local tmp

    if [[ ! -d /etc/pve/nodes ]]; then
        error "Proxmox config filesystem is unavailable at /etc/pve/nodes. Try: sudo systemctl restart pve-cluster"
    fi

    node="$(hostname)"
    node_dir="/etc/pve/nodes/$node"
    if [[ ! -d "$node_dir" ]]; then
        node_dir="$(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d | head -n1)"
    fi

    if [[ -z "$node_dir" || ! -d "$node_dir" ]]; then
        error "No Proxmox node directory found under /etc/pve/nodes. Try: sudo systemctl restart pve-cluster"
    fi

    lxc_dir="$node_dir/lxc"
    if [[ ! -d "$lxc_dir" ]]; then
        error "Proxmox LXC config directory is missing: $lxc_dir. Try: sudo systemctl restart pve-cluster"
    fi

    tmp="$lxc_dir/.homelab-write-test.$$"
    if ! : > "$tmp" 2>/dev/null; then
        error "Cannot write to $lxc_dir. Try: sudo systemctl restart pve-cluster"
    fi
    rm -f "$tmp"
}

template_storage() {
    pvesm status --content vztmpl | awk 'NR > 1 { print $1; exit }'
}

rootfs_storage() {
    pvesm status --content rootdir | awk 'NR > 1 { print $1; exit }'
}

vm_disk_storage() {
    if [[ "$OPENPANEL_VM_STORAGE" != "auto" ]]; then
        echo "$OPENPANEL_VM_STORAGE"
        return
    fi

    pvesm status --content images | awk 'NR > 1 { print $1; exit }'
}

iso_storages() {
    if [[ "$OPENPANEL_ISO_STORAGE" != "auto" ]]; then
        echo "$OPENPANEL_ISO_STORAGE"
        return
    fi

    pvesm status --content iso | awk 'NR > 1 { print $1 }'
}

select_openpanel_iso() {
    local storage volids selected

    if [[ "$OPENPANEL_ISO" != "auto" ]]; then
        for storage in $(iso_storages); do
            if pvesm list "$storage" --content iso | awk 'NR > 1 { print $1 }' | grep -q "/$OPENPANEL_ISO$"; then
                echo "$storage:iso/$OPENPANEL_ISO"
                return
            fi
        done
        error "Could not find OpenPanel ISO filename in Proxmox ISO storage: $OPENPANEL_ISO"
    fi

    volids="$(for storage in $(iso_storages); do pvesm list "$storage" --content iso 2>/dev/null | awk 'NR > 1 { print $1 }'; done)"
    selected="$(printf '%s\n' "$volids" | grep -Ei '/(ubuntu|debian).*(server|live|netinst).*amd64.*\.iso$' | sort -V | tail -n1 || true)"
    if [[ -z "$selected" ]]; then
        selected="$(printf '%s\n' "$volids" | grep -Ei '/(ubuntu|debian).*\.iso$' | sort -V | tail -n1 || true)"
    fi
    [[ -n "$selected" ]] || error "No Ubuntu/Debian ISO found in Proxmox ISO storage. Upload an ISO or set OPENPANEL_ISO."
    echo "$selected"
}

write_openpanel_seed_iso() {
    local key_file="$1"
    local password="$2"
    local seed_dir="$GENERATED_DIR/openpanel-seed"
    local seed_iso="$GENERATED_DIR/openpanel-seed.iso"
    local password_hash

    rm -rf "$seed_dir"
    mkdir -p "$seed_dir"
    password_hash="$(openssl passwd -6 "$password")"

    cat > "$seed_dir/meta-data" <<EOF
instance-id: $OPENPANEL_HOSTNAME
local-hostname: $OPENPANEL_HOSTNAME
EOF

    cat > "$seed_dir/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: $OPENPANEL_HOSTNAME
    username: $OPENPANEL_SSH_USER
    password: "$password_hash"
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - $(cat "$key_file.pub")
  packages:
    - qemu-guest-agent
    - curl
    - ca-certificates
  network:
    version: 2
    ethernets:
      ens18:
        dhcp4: false
        addresses:
          - $OPENPANEL_IP/24
        routes:
          - to: default
            via: $GATEWAY_IP
        nameservers:
          addresses:
            - $GATEWAY_IP
            - 1.1.1.1
  late-commands:
    - curtin in-target --target=/target -- systemctl enable qemu-guest-agent
EOF

    genisoimage -quiet -output "$seed_iso" -volid cidata -joliet -rock "$seed_dir"
    echo "$seed_iso"
}

upload_iso_file() {
    local source="$1"
    local name="$2"
    local storage path

    storage="$(iso_storages | head -n1)"
    [[ -n "$storage" ]] || error "No Proxmox storage with ISO content found."
    path="$(pvesm path "$storage:iso/$name" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
        if [[ "$storage" == "local" ]]; then
            path="/var/lib/vz/template/iso/$name"
        else
            error "Could not resolve ISO storage path for $storage:iso/$name"
        fi
    fi
    mkdir -p "$(dirname "$path")"
    cp "$source" "$path"
    echo "$storage:iso/$name"
}

wait_for_ssh() {
    local ip="$1" key_file="$2" user="$3"

    for _ in $(seq 1 90); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$key_file" "$user@$ip" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 10
    done
    return 1
}

openpanel_ssh() {
    local key_file="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$key_file" "$OPENPANEL_SSH_USER@$OPENPANEL_IP" "$@"
}

openpanel_scp() {
    local key_file="$1" source="$2" dest="$3"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$key_file" "$source" "$OPENPANEL_SSH_USER@$OPENPANEL_IP:$dest"
}

ensure_openpanel_cloud_image() {
    local image="$GENERATED_DIR/openpanel-cloud.img"

    if [[ ! -s "$image" ]]; then
        info "Downloading OpenPanel VM cloud image" >&2
        curl -fL "$OPENPANEL_CLOUD_IMAGE_URL" -o "$image"
    fi

    echo "$image"
}

create_openpanel_cloud_vm() {
    local vmid="$1" memory="$2" cores="$3" disk_storage="$4" key_file="$5"
    local image imported_disk

    image="$(ensure_openpanel_cloud_image)"
    info "Creating OpenPanel VM $vmid ($OPENPANEL_HOSTNAME) from cloud image"
    qm create "$vmid" \
        --name "$OPENPANEL_HOSTNAME" \
        --memory "$memory" \
        --cores "$cores" \
        --cpu host \
        --machine q35 \
        --scsihw virtio-scsi-pci \
        --net0 "virtio,bridge=$VM_BRIDGE" \
        --agent enabled=1 \
        --ostype l26 \
        --onboot 1

    qm importdisk "$vmid" "$image" "$disk_storage"
    imported_disk="$(qm config "$vmid" | awk '/unused[0-9]+:/ { print $2; exit }')"
    [[ -n "$imported_disk" ]] || error "Could not find imported OpenPanel VM disk for VM $vmid"
    qm set "$vmid" \
        --scsi0 "$imported_disk" \
        --ide2 "$disk_storage:cloudinit" \
        --boot order=scsi0 \
        --serial0 socket \
        --vga serial0 \
        --ciuser "$OPENPANEL_SSH_USER" \
        --sshkeys "$key_file.pub" \
        --ipconfig0 "ip=$OPENPANEL_IP/24,gw=$GATEWAY_IP" \
        --nameserver "$GATEWAY_IP" \
        --searchdomain "$DOMAIN"
    qm resize "$vmid" scsi0 "${OPENPANEL_DISK_GB}G" >/dev/null 2>&1 || true
    qm start "$vmid"
}

create_openpanel_iso_vm() {
    local vmid="$1" memory="$2" cores="$3" disk_storage="$4" key_file="$5" password="$6"
    local iso_ref seed_iso seed_ref

    iso_ref="$(select_openpanel_iso)"
    seed_iso="$(write_openpanel_seed_iso "$key_file" "$password")"
    seed_ref="$(upload_iso_file "$seed_iso" "homelab-openpanel-seed.iso")"

    warn "ISO autoinstall may still require adding 'autoinstall' to the installer kernel command line. Prefer OPENPANEL_VM_INSTALL_METHOD=cloud-image."
    info "Creating OpenPanel VM $vmid ($OPENPANEL_HOSTNAME) from $iso_ref"
    qm create "$vmid" \
        --name "$OPENPANEL_HOSTNAME" \
        --memory "$memory" \
        --cores "$cores" \
        --cpu host \
        --machine q35 \
        --scsihw virtio-scsi-pci \
        --scsi0 "$disk_storage:${OPENPANEL_DISK_GB}" \
        --ide2 "$iso_ref,media=cdrom" \
        --ide3 "$seed_ref,media=cdrom" \
        --boot order=ide2 \
        --net0 "virtio,bridge=$VM_BRIDGE" \
        --agent enabled=1 \
        --ostype l26 \
        --onboot 1
    qm start "$vmid"
}

lxc_config_file() {
    local ctid="$1"
    local config

    config="$(find /etc/pve/nodes -mindepth 3 -maxdepth 3 -path "*/lxc/$ctid.conf" -print -quit 2>/dev/null || true)"
    if [[ -z "$config" && -f "/etc/pve/lxc/$ctid.conf" ]]; then
        config="/etc/pve/lxc/$ctid.conf"
    fi

    echo "$config"
}

ensure_proxy_tun() {
    local ctid="$1"
    local config
    local changed=false

    mkdir -p /dev/net
    if [[ ! -c /dev/net/tun ]]; then
        mknod /dev/net/tun c 10 200
        chmod 666 /dev/net/tun
    fi

    config="$(lxc_config_file "$ctid")"
    [[ -n "$config" ]] || error "Could not find Proxmox config for LXC $ctid"

    if ! grep -q '^lxc.cgroup2.devices.allow: c 10:200 rwm$' "$config"; then
        echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> "$config"
        changed=true
    fi

    if ! grep -q '^lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file$' "$config"; then
        echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> "$config"
        changed=true
    fi

    if [[ "$changed" == true ]]; then
        info "Restarting proxy LXC $ctid to enable /dev/net/tun"
        pct reboot "$ctid" >/dev/null 2>&1 || {
            pct stop "$ctid" >/dev/null 2>&1 || true
            pct start "$ctid"
        }
        wait_for_lxc "$ctid"
    fi
}

ensure_template() {
    local storage template
    storage="$(template_storage)"
    [[ -n "$storage" ]] || error "No Proxmox storage with vztmpl content found."

    pveam update >&2
    template="$(
      pveam available --section system |
      awk '$1 == "system" && $2 ~ /^debian-13-standard_/ && $3 == "amd64" { print $2 }' |
      sort -V |
      tail -n1
    )"
    [[ -n "$template" ]] || error "Could not find a Debian 13 LXC template."

    if ! pveam list "$storage" | awk '{ print $1 }' | grep -q "/$template$"; then
        info "Downloading LXC template $template to $storage" >&2
        pveam download "$storage" "$template" >&2
    fi

    echo "$storage:vztmpl/$template"
}

validate_template_ref() {
    local template="$1"

    if [[ "$template" == *$'\n'* || "$template" == *$'\r'* ]]; then
        error "Resolved LXC template contains unexpected output: $template"
    fi

    if ((${#template} > 255)); then
        error "Resolved LXC template is too long for pct: $template"
    fi
}

clamp_number() {
    local value="$1" min="$2" max="$3"

    if ((value < min)); then
        echo "$min"
    elif ((value > max)); then
        echo "$max"
    else
        echo "$value"
    fi
}

host_memory_mb() {
    awk '/MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo
}

resolve_openpanel_memory_mb() {
    local total reserved available

    if [[ "$OPENPANEL_MEMORY_MB" != "auto" ]]; then
        echo "$OPENPANEL_MEMORY_MB"
        return
    fi

    total="$(host_memory_mb)"
    reserved=$((OPENPANEL_HOST_RESERVE_MB + OPENPANEL_DIAGNOSTIC_VM_RESERVE_MB + 768 + 768 + 768 + 5120))
    available=$((total - reserved))
    clamp_number "$available" "$OPENPANEL_MIN_MEMORY_MB" "$OPENPANEL_MAX_MEMORY_MB"
}

resolve_dokploy_memory_mb() {
    local total reserved available

    if [[ "$DOKPLOY_MEMORY_MB" != "auto" ]]; then
        echo "$DOKPLOY_MEMORY_MB"
        return
    fi

    total="$(host_memory_mb)"
    reserved=$((DOKPLOY_HOST_RESERVE_MB + 768 + 768 + 768 + 5120 + OPENPANEL_MAX_MEMORY_MB))
    available=$((total - reserved))
    if ((available < DOKPLOY_MIN_MEMORY_MB)); then
        echo "$DOKPLOY_MIN_MEMORY_MB"
    else
        echo "$available"
    fi
}

resolve_openpanel_cores() {
    local total available

    if [[ "$OPENPANEL_CORES" != "auto" ]]; then
        echo "$OPENPANEL_CORES"
        return
    fi

    total="$(nproc)"
    available=$((total - OPENPANEL_CPU_RESERVE))
    clamp_number "$available" 1 "$OPENPANEL_MAX_CORES"
}

resolve_dokploy_cores() {
    if [[ "$DOKPLOY_CORES" != "auto" ]]; then
        echo "$DOKPLOY_CORES"
        return
    fi

    nproc
}

ensure_lxc_resources() {
    local ctid="$1" memory="$2" cores="$3"

    if pct status "$ctid" >/dev/null 2>&1; then
        info "Ensuring LXC $ctid has memory=$memory MB and cores=$cores"
        pct set "$ctid" --memory "$memory" --cores "$cores" >/dev/null
    fi
}

ensure_lxc() {
    local ctid="$1" hostname="$2" ip="$3" memory="$4" cores="$5" disk="$6" template="$7"
    local root_storage root_password
    local create_output

    if pct status "$ctid" >/dev/null 2>&1; then
        info "LXC $ctid ($hostname) already exists; ensuring it is running"
        pct start "$ctid" >/dev/null 2>&1 || true
        return
    fi

    root_storage="$(rootfs_storage)"
    [[ -n "$root_storage" ]] || error "No Proxmox storage with rootdir content found."
    root_password="$(secret_file "$SECRETS_DIR/lxc-root-password" 32)"

    info "Creating LXC $ctid ($hostname) at $ip"
    if ! create_output="$(pct create "$ctid" "$template" \
        --hostname "$hostname" \
        --memory "$memory" \
        --cores "$cores" \
        --rootfs "$root_storage:$disk" \
        --ostype debian \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --net0 "name=eth0,bridge=$VM_BRIDGE,ip=$ip/24,gw=$GATEWAY_IP" \
        --nameserver "$GATEWAY_IP" \
        --onboot 1 \
        --password "$root_password" \
        --start 1 2>&1)"; then
        printf '%s\n' "$create_output" >&2
        pct unlock "$ctid" >/dev/null 2>&1 || true
        pct destroy "$ctid" --purge 1 >/dev/null 2>&1 || true
        error "Failed to create LXC $ctid. If this mentions /etc/pve, run: sudo systemctl restart pve-cluster"
    fi

    [[ -n "$create_output" ]] && printf '%s\n' "$create_output"
}

bootstrap_lxc() {
    local ctid="$1"
    info "Bootstrapping base packages in LXC $ctid"
    configure_lxc_ipv4_only_networking "$ctid"
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ca-certificates curl file gnupg jq openssl psmisc sqlite3 tar unattended-upgrades"
    pct_exec "$ctid" "cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
EOF
cat > /etc/apt/apt.conf.d/51homelab-unattended-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        \"origin=Debian,codename=\${distro_codename},label=Debian-Security\";
        \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";
};
Unattended-Upgrade::Automatic-Reboot \"false\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
EOF
systemctl enable --now unattended-upgrades"
}

install_docker() {
    local ctid="$1"
    local docker_installed_now="false"
    local dns_result=""
    local dns_script

    if ! pct_exec "$ctid" "command -v docker >/dev/null 2>&1"; then
        info "Installing Docker in LXC $ctid"
        pct_exec "$ctid" "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh"
        docker_installed_now="true"
    fi

    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get install -y docker-compose-plugin python3"
    pct_exec "$ctid" "systemctl enable --now docker"

    info "Configuring Docker DNS defaults in LXC $ctid"
    dns_script="$(mktemp)"
    cat > "$dns_script" <<'PY'
import json
import os
from pathlib import Path

path = Path("/etc/docker/daemon.json")
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Existing /etc/docker/daemon.json is invalid JSON: {exc}")

data["ipv6"] = False
data["dns"] = json.loads(os.environ["HOMELAB_DOCKER_DNS_JSON"])
rendered = json.dumps(data, indent=2, sort_keys=True) + "\n"
if path.exists() and path.read_text() == rendered:
    print("unchanged")
else:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered)
    print("changed")
PY
    pct push "$ctid" "$dns_script" /tmp/homelab-docker-dns.py
    rm -f "$dns_script"
    dns_result="$(
        pct_exec "$ctid" "HOMELAB_DOCKER_DNS_JSON=$(quote "$(docker_dns_servers_json)") python3 /tmp/homelab-docker-dns.py"
    )"
    dns_result="${dns_result//$'\r'/}"
    dns_result="${dns_result##*$'\n'}"

    if [[ "$docker_installed_now" == "true" || "$dns_result" == "changed" ]]; then
        info "Restarting Docker in LXC $ctid to apply daemon.json"
        pct_exec "$ctid" "systemctl restart docker"
    elif [[ "$dns_result" != "unchanged" ]]; then
        error "Unexpected Docker DNS configure result in LXC $ctid: ${dns_result:-<empty>}"
    fi
}

export_mail_env() {
    export DOMAIN MAIL_DOMAIN EMAIL_APP_DOMAIN WEBMAIL_DOMAIN LISTMONK_DOMAIN POSTAL_DOMAIN
    export LIBREDESK_DOMAIN AUTODISCOVER_DOMAIN AUTOCONFIG_DOMAIN MTA_STS_DOMAIN LE_EMAIL
    export CLOUDFLARE_DNS_API_TOKEN STALWART_ACME_ENABLED STALWART_ACME_DNS_PROVIDER STALWART_ACME_DNS_CF_SECRET
    export STALWART_HTTP_PERMISSIVE_CORS STALWART_DEFAULT_DOMAIN
    export STALWART_ALLOWED_IP="${STALWART_ALLOWED_IP:-$PROXY_IP}"
    export STALWART_DNS_RESOLVER STALWART_DNS_USE_TLS
    export HOMELAB_DNS_SERVERS HOMELAB_DOCKER_DNS_SERVERS BULWARK_JMAP_SERVER_URL
    export SETTINGS_ENCRYPTION_KEY ALLOWED_DOMAINS

    export EMAIL_POSTGRES_USER="${EMAIL_POSTGRES_USER:-email_service}"
    export EMAIL_POSTGRES_PASSWORD="${EMAIL_POSTGRES_PASSWORD:-$(secret_file "$SECRETS_DIR/email-postgres-password" 32)}"
    export EMAIL_POSTGRES_DB="${EMAIL_POSTGRES_DB:-email_service}"
    export EMAIL_JWT_SECRET="${EMAIL_JWT_SECRET:-$(secret_file "$SECRETS_DIR/email-jwt-secret" 64)}"
    if [[ ! -s "$SECRETS_DIR/email-settings-encryption-key" ]]; then
        openssl rand -base64 32 > "$SECRETS_DIR/email-settings-encryption-key"
        chmod 600 "$SECRETS_DIR/email-settings-encryption-key"
    fi
    export SETTINGS_ENCRYPTION_KEY="${SETTINGS_ENCRYPTION_KEY:-$(cat "$SECRETS_DIR/email-settings-encryption-key")}"
    if [[ ! -s "$SECRETS_DIR/email-inbound-config-encryption-key" ]]; then
        openssl rand -base64 32 > "$SECRETS_DIR/email-inbound-config-encryption-key"
        chmod 600 "$SECRETS_DIR/email-inbound-config-encryption-key"
    fi
    export INBOUND_CONFIG_ENCRYPTION_KEY="${INBOUND_CONFIG_ENCRYPTION_KEY:-$(cat "$SECRETS_DIR/email-inbound-config-encryption-key")}"
    export DASHBOARD_ADMIN_EMAILS="${DASHBOARD_ADMIN_EMAILS:-allan.bosire@ifkafin.com}"
    export LISTMONK_PASSWORD="${LISTMONK_PASSWORD:-$(secret_file "$SECRETS_DIR/listmonk-api-password" 32)}"
    export POSTAL_DB_ROOT_PASSWORD="${POSTAL_DB_ROOT_PASSWORD:-$(secret_file "$SECRETS_DIR/postal-db-root-password" 32)}"
    export POSTAL_RAILS_SECRET_KEY="${POSTAL_RAILS_SECRET_KEY:-$(secret_file "$SECRETS_DIR/postal-rails-secret-key" 64)}"
    export LISTMONK_DB_PASSWORD="${LISTMONK_DB_PASSWORD:-$(secret_file "$SECRETS_DIR/listmonk-db-password" 32)}"
    export LISTMONK_ADMIN_PASSWORD="${LISTMONK_ADMIN_PASSWORD:-$(secret_file "$SECRETS_DIR/listmonk-admin-password" 24)}"
    export STALWART_ADMIN_PASSWORD="${STALWART_ADMIN_PASSWORD:-$(secret_file "$SECRETS_DIR/stalwart-admin-password" 24)}"
    export STALWART_DB_PASSWORD="${STALWART_DB_PASSWORD:-$(secret_file "$SECRETS_DIR/stalwart-db-password" 32)}"
    export STALWART_REDIS_PASSWORD="${STALWART_REDIS_PASSWORD:-$(secret_file "$SECRETS_DIR/stalwart-redis-password" 32)}"
    export STALWART_MINIO_ROOT_PASSWORD="${STALWART_MINIO_ROOT_PASSWORD:-$(secret_file "$SECRETS_DIR/stalwart-minio-root-password" 32)}"
    export BULWARK_SESSION_SECRET="${BULWARK_SESSION_SECRET:-$(secret_file "$SECRETS_DIR/bulwark-session-secret" 64)}"
    export LIBREDESK_SYSTEM_USER_PASSWORD="${LIBREDESK_SYSTEM_USER_PASSWORD:-$(strong_secret_file "$SECRETS_DIR/libredesk-system-user-password" 24)}"
    export LIBREDESK_DB__PASSWORD="${LIBREDESK_DB__PASSWORD:-$(secret_file "$SECRETS_DIR/libredesk-db-password" 32)}"
    export LIBREDESK_APP__ENCRYPTION_KEY="${LIBREDESK_APP__ENCRYPTION_KEY:-$(secret_file "$SECRETS_DIR/libredesk-encryption-key" 32)}"
}

install_mail_lxc() {
    local ctid="$1"
    local stalwart_dns_secret

    bootstrap_lxc "$ctid"
    install_docker "$ctid"
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get install -y git"

    stalwart_dns_secret="${STALWART_ACME_DNS_CF_SECRET:-$CLOUDFLARE_DNS_API_TOKEN}"
    if [[ "$STALWART_ACME_ENABLED" == "true" && "$STALWART_ACME_DNS_PROVIDER" == "cloudflare" && -z "$stalwart_dns_secret" ]]; then
        error "Set STALWART_ACME_DNS_CF_SECRET or CLOUDFLARE_DNS_API_TOKEN for Stalwart Cloudflare DNS-01 ACME."
    fi

    info "Cloning/updating email-service in LXC $ctid"
    pct_exec "$ctid" "if [[ -d /opt/email-service/.git ]]; then git -C /opt/email-service fetch --all --tags && git -C /opt/email-service checkout $(quote "$EMAIL_SERVICE_REF") && (git -C /opt/email-service pull --ff-only || true); else rm -rf /opt/email-service && git clone $(quote "$EMAIL_SERVICE_REPO") /opt/email-service && git -C /opt/email-service checkout $(quote "$EMAIL_SERVICE_REF"); fi"

    info "Rendering email-service .env"
    export_mail_env
    python3 "$SERVICES_DIR/mail/render.py" --output-dir "$GENERATED_DIR/mail"
    pct push "$ctid" "$GENERATED_DIR/mail/.env" /opt/email-service/.env
    pct push "$ctid" "$GENERATED_DIR/mail/docker-compose.homelab.yml" /opt/email-service/docker-compose.homelab.yml
    pct_exec "$ctid" "mkdir -p /opt/email-service/scripts/stalwart-homelab"
    pct push "$ctid" "$GENERATED_DIR/mail/scripts/stalwart-homelab/init.py" /opt/email-service/scripts/stalwart-homelab/init.py
    pct push "$ctid" "$GENERATED_DIR/mail/scripts/stalwart-homelab/apply-inside.sh" /opt/email-service/scripts/stalwart-homelab/apply-inside.sh
    pct push "$ctid" "$SERVICES_DIR/mail/apply-stalwart-plan.sh" /opt/email-service/apply-stalwart-plan.sh
    pct push "$ctid" "$SERVICES_DIR/mail/regenerate-stalwart-config.sh" /opt/email-service/regenerate-stalwart-config.sh
    pct_exec "$ctid" "mkdir -p /opt/email-service/scripts/homelab-app"
    pct push "$ctid" "$SERVICES_DIR/mail/patch-allowed-domains.sh" /opt/email-service/scripts/homelab-app/patch-allowed-domains.sh
    pct push "$ctid" "$SERVICES_DIR/mail/app-entrypoint.sh" /opt/email-service/scripts/homelab-app/app-entrypoint.sh
    pct_exec "$ctid" "chmod 600 /opt/email-service/.env && chmod +x /opt/email-service/apply-stalwart-plan.sh /opt/email-service/regenerate-stalwart-config.sh /opt/email-service/scripts/stalwart-homelab/apply-inside.sh /opt/email-service/scripts/homelab-app/patch-allowed-domains.sh /opt/email-service/scripts/homelab-app/app-entrypoint.sh"

    info "Freeing mail ports inside LXC $ctid before starting email-service"
    free_mail_ports_in_lxc "$ctid"

    info "Regenerating Stalwart config in LXC $ctid"
    pct_exec "$ctid" "cd /opt/email-service && docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up --force-recreate stalwart-config"

    info "Starting email-service production stack in LXC $ctid"
    pct_exec "$ctid" "cd /opt/email-service && docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d && docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d --force-recreate stalwart"

    info "Applying Stalwart declarative configuration in LXC $ctid"
    pct_exec "$ctid" "cd /opt/email-service && ./apply-stalwart-plan.sh"

    if [[ "$HOMELAB_NETWORK_DIAGNOSTICS" == "true" ]]; then
        diagnose_lxc_networking "$ctid"
    fi
}

install_openpanel_lxc() {
    local ctid="$1"
    local sync_env
    local sync_timer
    local cloudflare_dns_target

    if [[ "$OPENPANEL_PROVISION_LXC" != "true" ]]; then
        warn "Skipping OpenPanel LXC provisioning. OpenPanel upstream does not support containers/LXCs; use a dedicated VM and set OPENPANEL_IP."
        return
    fi

    bootstrap_lxc "$ctid"
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get install -y curl python3"

    info "Installing OpenPanel Community Edition in LXC $ctid"
    pct push "$ctid" "$SERVICES_DIR/openpanel/install-openpanel.sh" /tmp/install-openpanel.sh
    pct_exec "$ctid" "chmod +x /tmp/install-openpanel.sh && /tmp/install-openpanel.sh"

    info "Installing OpenPanel to NPM sync timer in LXC $ctid"
    pct push "$ctid" "$SERVICES_DIR/openpanel/sync_npm_domains.py" /usr/local/bin/sync-openpanel-npm-domains
    pct push "$ctid" "$SERVICES_DIR/openpanel/sync-npm-domains.service" /etc/systemd/system/sync-npm-domains.service
    pct_exec "$ctid" "chmod +x /usr/local/bin/sync-openpanel-npm-domains && mkdir -p /etc/homelab"

    sync_timer="$(mktemp)"
    cat > "$sync_timer" <<EOF
[Unit]
Description=Periodic OpenPanel to Nginx Proxy Manager domain sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=${OPENPANEL_NPM_SYNC_INTERVAL_SECONDS}s
AccuracySec=10s
Unit=sync-npm-domains.service

[Install]
WantedBy=timers.target
EOF
    pct push "$ctid" "$sync_timer" /etc/systemd/system/sync-npm-domains.timer
    rm -f "$sync_timer"

    cloudflare_dns_target="${OPENPANEL_CLOUDFLARE_DNS_TARGET:-$(get_ip)}"
    sync_env="$(mktemp)"
    cat > "$sync_env" <<EOF
NPM_URL=http://$PROXY_IP:81
NPM_EMAIL=$NPM_LOGIN_EMAIL
NPM_PASSWORD=$NPM_LOGIN_PASSWORD
OPENPANEL_IP=$OPENPANEL_IP
OPENPANEL_CLIENT_PANEL_DOMAIN=$OPENPANEL_CLIENT_PANEL_DOMAIN
OPENPANEL_ADMIN_DOMAIN=$OPENPANEL_ADMIN_DOMAIN
OPENPANEL_PUBLIC_BACKEND_PORT=$OPENPANEL_PUBLIC_BACKEND_PORT
OPENPANEL_CLIENT_PANEL_PORT=$OPENPANEL_CLIENT_PANEL_PORT
OPENPANEL_CLIENT_PANEL_SCHEME=$OPENPANEL_CLIENT_PANEL_SCHEME
OPENPANEL_NPM_AUTO_CERTS=$OPENPANEL_NPM_AUTO_CERTS
NPM_DNS_PROPAGATION_SECONDS=$NPM_DNS_PROPAGATION_SECONDS
OPENPANEL_SYNC_HTTP_TIMEOUT=180
OPENPANEL_CLOUDFLARE_DNS_API_TOKEN=$OPENPANEL_CLOUDFLARE_DNS_API_TOKEN
OPENPANEL_CLOUDFLARE_DNS_TARGET=$cloudflare_dns_target
OPENPANEL_CLOUDFLARE_DNS_ZONES=$OPENPANEL_CLOUDFLARE_DNS_ZONES
OPENPANEL_CLOUDFLARE_DNS_PROXIED=$OPENPANEL_CLOUDFLARE_DNS_PROXIED
OPENPANEL_CLOUDFLARE_DNS_TTL=$OPENPANEL_CLOUDFLARE_DNS_TTL
EOF
    chmod 600 "$sync_env"
    pct push "$ctid" "$sync_env" /etc/homelab/openpanel-npm-sync.env
    rm -f "$sync_env"
    pct_exec "$ctid" "chmod 600 /etc/homelab/openpanel-npm-sync.env && systemctl daemon-reload && systemctl enable --now sync-npm-domains.timer"
}

ensure_openpanel_vm() {
    local vmid="$OPENPANEL_VMID"
    local memory="$1"
    local cores="$2"
    local disk_storage key_file password

    if [[ "$OPENPANEL_PROVISION_VM" != "true" ]]; then
        warn "Skipping OpenPanel VM provisioning because OPENPANEL_PROVISION_VM is not true."
        return
    fi

    key_file="$(ensure_ssh_keypair)"
    password="$(secret_file "$SECRETS_DIR/openpanel-vm-password" 24)"
    disk_storage="$(vm_disk_storage)"
    [[ -n "$disk_storage" ]] || error "No Proxmox storage with VM image content found."

    if qm status "$vmid" >/dev/null 2>&1; then
        info "OpenPanel VM $vmid already exists; ensuring it is running"
        qm set "$vmid" --memory "$memory" --cores "$cores" >/dev/null
        qm start "$vmid" >/dev/null 2>&1 || true
    else
        case "$OPENPANEL_VM_INSTALL_METHOD" in
            cloud-image)
                create_openpanel_cloud_vm "$vmid" "$memory" "$cores" "$disk_storage" "$key_file"
                ;;
            iso)
                create_openpanel_iso_vm "$vmid" "$memory" "$cores" "$disk_storage" "$key_file" "$password"
                ;;
            *)
                error "Unsupported OPENPANEL_VM_INSTALL_METHOD: $OPENPANEL_VM_INSTALL_METHOD"
                ;;
        esac
    fi

    if ! wait_for_ssh "$OPENPANEL_IP" "$key_file" "$OPENPANEL_SSH_USER"; then
        warn "OpenPanel VM is not reachable over SSH at $OPENPANEL_IP. Complete the OS install manually if the ISO did not autoinstall, then rerun this script."
        return
    fi

    install_openpanel_vm_services "$key_file"
}

install_openpanel_vm_services() {
    local key_file="$1"
    local sync_env
    local sync_timer
    local cloudflare_dns_target

    info "Installing OpenPanel Community Edition in VM $OPENPANEL_VMID"
    openpanel_scp "$key_file" "$SERVICES_DIR/openpanel/install-openpanel.sh" /tmp/install-openpanel.sh
    openpanel_ssh "$key_file" "sudo chmod +x /tmp/install-openpanel.sh && sudo /tmp/install-openpanel.sh --domain=$(quote "$OPENPANEL_ADMIN_DOMAIN") --panel-domain=$(quote "$OPENPANEL_CLIENT_PANEL_DOMAIN") --admin-port=2087 --user-port=$(quote "$OPENPANEL_CLIENT_PANEL_PORT") --skip-firewall --skip-dns-server"

    info "Installing OpenPanel to NPM sync timer in VM $OPENPANEL_VMID"
    openpanel_scp "$key_file" "$SERVICES_DIR/openpanel/sync_npm_domains.py" /tmp/sync-openpanel-npm-domains
    openpanel_scp "$key_file" "$SERVICES_DIR/openpanel/sync-npm-domains.service" /tmp/sync-npm-domains.service
    openpanel_ssh "$key_file" "sudo install -m 755 /tmp/sync-openpanel-npm-domains /usr/local/bin/sync-openpanel-npm-domains && sudo install -m 644 /tmp/sync-npm-domains.service /etc/systemd/system/sync-npm-domains.service && sudo mkdir -p /etc/homelab"

    sync_timer="$(mktemp)"
    cat > "$sync_timer" <<EOF
[Unit]
Description=Periodic OpenPanel to Nginx Proxy Manager domain sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=${OPENPANEL_NPM_SYNC_INTERVAL_SECONDS}s
AccuracySec=10s
Unit=sync-npm-domains.service

[Install]
WantedBy=timers.target
EOF
    openpanel_scp "$key_file" "$sync_timer" /tmp/sync-npm-domains.timer
    rm -f "$sync_timer"

    cloudflare_dns_target="${OPENPANEL_CLOUDFLARE_DNS_TARGET:-$(get_ip)}"
    sync_env="$(mktemp)"
    cat > "$sync_env" <<EOF
NPM_URL=http://$PROXY_IP:81
NPM_EMAIL=$NPM_LOGIN_EMAIL
NPM_PASSWORD=$NPM_LOGIN_PASSWORD
OPENPANEL_IP=$OPENPANEL_IP
OPENPANEL_CLIENT_PANEL_DOMAIN=$OPENPANEL_CLIENT_PANEL_DOMAIN
OPENPANEL_ADMIN_DOMAIN=$OPENPANEL_ADMIN_DOMAIN
OPENPANEL_PUBLIC_BACKEND_PORT=$OPENPANEL_PUBLIC_BACKEND_PORT
OPENPANEL_CLIENT_PANEL_PORT=$OPENPANEL_CLIENT_PANEL_PORT
OPENPANEL_CLIENT_PANEL_SCHEME=$OPENPANEL_CLIENT_PANEL_SCHEME
OPENPANEL_NPM_AUTO_CERTS=$OPENPANEL_NPM_AUTO_CERTS
NPM_DNS_PROPAGATION_SECONDS=$NPM_DNS_PROPAGATION_SECONDS
OPENPANEL_SYNC_HTTP_TIMEOUT=180
OPENPANEL_CLOUDFLARE_DNS_API_TOKEN=$OPENPANEL_CLOUDFLARE_DNS_API_TOKEN
OPENPANEL_CLOUDFLARE_DNS_TARGET=$cloudflare_dns_target
OPENPANEL_CLOUDFLARE_DNS_ZONES=$OPENPANEL_CLOUDFLARE_DNS_ZONES
OPENPANEL_CLOUDFLARE_DNS_PROXIED=$OPENPANEL_CLOUDFLARE_DNS_PROXIED
OPENPANEL_CLOUDFLARE_DNS_TTL=$OPENPANEL_CLOUDFLARE_DNS_TTL
EOF
    chmod 600 "$sync_env"
    openpanel_scp "$key_file" "$sync_env" /tmp/openpanel-npm-sync.env
    rm -f "$sync_env"
    openpanel_ssh "$key_file" "sudo install -m 644 /tmp/sync-npm-domains.timer /etc/systemd/system/sync-npm-domains.timer && sudo install -m 600 /tmp/openpanel-npm-sync.env /etc/homelab/openpanel-npm-sync.env && sudo systemctl daemon-reload && sudo systemctl enable --now sync-npm-domains.timer"

    ensure_openadmin_credentials "$key_file"
}

ensure_openadmin_credentials() {
    local key_file="$1"
    local admin_user
    local admin_password

    admin_password="$(secret_file "$SECRETS_DIR/openadmin-password" 24)"
    admin_user="$(openpanel_ssh "$key_file" "sudo opencli admin list 2>/dev/null | awk -F'|' 'NF >= 1 { print \\$1; exit }'" || true)"
    admin_user="${admin_user:-admin}"

    printf '%s\n' "$admin_user" > "$SECRETS_DIR/openadmin-user"
    chmod 600 "$SECRETS_DIR/openadmin-user"

    if ! openpanel_ssh "$key_file" "sudo opencli admin list 2>/dev/null | awk -F'|' '{ print \\$1 }' | grep -Fxq $(quote "$admin_user")"; then
        openpanel_ssh "$key_file" "sudo env OPENADMIN_USER=$(quote "$admin_user") OPENADMIN_PASSWORD=$(quote "$admin_password") python3 -c 'import os, subprocess; subprocess.run([\"opencli\", \"admin\", \"new\", os.environ[\"OPENADMIN_USER\"], os.environ[\"OPENADMIN_PASSWORD\"]], check=True)' >/dev/null"
    else
        openpanel_ssh "$key_file" "sudo env OPENADMIN_USER=$(quote "$admin_user") OPENADMIN_PASSWORD=$(quote "$admin_password") python3 -c 'import os, subprocess; subprocess.run([\"opencli\", \"admin\", \"password\", os.environ[\"OPENADMIN_USER\"], os.environ[\"OPENADMIN_PASSWORD\"]], check=True)' >/dev/null"
    fi
}

install_proxy_lxc() {
    local ctid="$1"
    bootstrap_lxc "$ctid"
    install_docker "$ctid"

    info "Installing Nginx Proxy Manager in LXC $ctid"
    export NPM_VERSION="${NPM_VERSION:-latest}"
    export NPM_ADMIN_EMAIL NPM_PASSWORD
    python3 "$SERVICES_DIR/proxy/render.py" --output-dir "$GENERATED_DIR/proxy"
    pct_exec "$ctid" "mkdir -p /opt/nginx-proxy-manager/data /opt/nginx-proxy-manager/letsencrypt"
    pct push "$ctid" "$GENERATED_DIR/proxy/docker-compose.yml" /opt/nginx-proxy-manager/docker-compose.yml
    pct push "$ctid" "$GENERATED_DIR/proxy/.env" /opt/nginx-proxy-manager/.env
    pct push "$ctid" "$GENERATED_DIR/proxy/start.sh" /opt/nginx-proxy-manager/start.sh
    pct push "$ctid" "$GENERATED_DIR/proxy/README.md" /opt/nginx-proxy-manager/README.md
    pct_exec "$ctid" "chmod +x /opt/nginx-proxy-manager/start.sh && /opt/nginx-proxy-manager/start.sh"

    if [[ "$HOMELAB_NETWORK_DIAGNOSTICS" == "true" ]]; then
        diagnose_lxc_networking "$ctid"
    fi
}

harden_npm_admin() {
    local token
    local verified_token
    local ctid="$PROXY_CTID"
    local login_email=""
    local login_password=""

    info "Ensuring Nginx Proxy Manager admin credentials are not left at first-run defaults"
    pct_exec "$ctid" "for i in \$(seq 1 60); do curl -fsS http://127.0.0.1:81/api >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || {
        warn "Nginx Proxy Manager API was not ready; change the default admin credentials manually."
        return
    }

    token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_ADMIN_EMAIL") --arg secret $(quote "$NPM_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
        NPM_LOGIN_EMAIL="$NPM_ADMIN_EMAIL"
        NPM_LOGIN_PASSWORD="$NPM_PASSWORD"
        info "Nginx Proxy Manager admin credentials are already updated"
        return
    fi

    if [[ -n "${NPM_BOOTSTRAP_EMAIL:-}" && -n "${NPM_BOOTSTRAP_PASSWORD:-}" ]]; then
        token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_BOOTSTRAP_EMAIL") --arg secret $(quote "$NPM_BOOTSTRAP_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
        if [[ -n "$token" ]]; then
            login_email="$NPM_BOOTSTRAP_EMAIL"
            login_password="$NPM_BOOTSTRAP_PASSWORD"
        fi
    fi

    if [[ -z "$token" ]]; then
        token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity admin@example.com --arg secret changeme '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
        if [[ -n "$token" ]]; then
            login_email="admin@example.com"
            login_password="changeme"
        fi
    fi

    if [[ -z "$token" ]]; then
        warn "Could not log in to Nginx Proxy Manager with configured, bootstrap, or legacy default credentials; change the admin credentials manually."
        return
    fi

    pct_exec "$ctid" "curl -fsS -X PUT http://127.0.0.1:81/api/users/1/auth -H 'Authorization: Bearer $(quote "$token")' -H 'Content-Type: application/json' --data \"\$(jq -nc --arg current $(quote "$login_password") --arg secret $(quote "$NPM_PASSWORD") '{type:\"password\",current:\$current,secret:\$secret}')\" >/dev/null" || {
        warn "Could not update the Nginx Proxy Manager admin password automatically."
    }

    verified_token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$login_email") --arg secret $(quote "$NPM_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -n "$verified_token" ]]; then
        token="$verified_token"
        NPM_LOGIN_EMAIL="$login_email"
        NPM_LOGIN_PASSWORD="$NPM_PASSWORD"
    else
        NPM_LOGIN_EMAIL="$login_email"
        NPM_LOGIN_PASSWORD="$login_password"
    fi

    pct_exec "$ctid" "curl -fsS -X PUT http://127.0.0.1:81/api/users/1 -H 'Authorization: Bearer $(quote "$token")' -H 'Content-Type: application/json' --data \"\$(jq -nc --arg email $(quote "$NPM_ADMIN_EMAIL") '{name:\"Homelab Admin\",nickname:\"Homelab\",email:\$email,roles:[\"admin\"],is_disabled:false}')\" >/dev/null" || {
        warn "Could not update the Nginx Proxy Manager admin email automatically."
    }

    token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_ADMIN_EMAIL") --arg secret $(quote "$NPM_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -z "$token" ]]; then
        warn "Nginx Proxy Manager admin email update could not be verified; using the verified bootstrap email for API automation."
        return
    fi

    NPM_LOGIN_EMAIL="$NPM_ADMIN_EMAIL"
    NPM_LOGIN_PASSWORD="$NPM_PASSWORD"
    info "Nginx Proxy Manager admin credentials updated"
}

seed_npm_proxy_hosts() {
    local token payload name existing
    local ctid="$PROXY_CTID"
    local sync_script="/tmp/sync-npm-hosts.py"

    info "Trying to seed Nginx Proxy Manager proxy hosts"
    pct_exec "$ctid" "for i in \$(seq 1 60); do curl -fsS http://127.0.0.1:81/api >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || {
        warn "Nginx Proxy Manager API was not ready; proxy hosts are listed in $STATE_DIR/access.txt"
        return
    }

    token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_LOGIN_EMAIL") --arg secret $(quote "$NPM_LOGIN_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -z "$token" ]]; then
        warn "Could not log in to Nginx Proxy Manager with configured admin credentials; seed hosts manually in the UI."
        return
    fi

    export AUTH_DOMAIN AUTH_IP AUTH_PORT HEADSCALE_DOMAIN HEADSCALE_IP HEADPLANE_DOMAIN OPENPANEL_CLIENT_PANEL_DOMAIN OPENPANEL_IP OPENPANEL_CLIENT_PANEL_PORT OPENPANEL_CLIENT_PANEL_SCHEME
    export DOKPLOY_DOMAIN DOKPLOY_IP DOKPLOY_PORT
    export MAIL_DOMAIN EMAIL_APP_DOMAIN WEBMAIL_DOMAIN LISTMONK_DOMAIN POSTAL_DOMAIN LIBREDESK_DOMAIN MAIL_IP AUTODISCOVER_DOMAIN AUTOCONFIG_DOMAIN MTA_STS_DOMAIN
    python3 "$SERVICES_DIR/proxy/render-npm-hosts.py" --output-dir "$GENERATED_DIR/npm"
    pct push "$ctid" "$SERVICES_DIR/proxy/sync_npm_hosts.py" "$sync_script"
    copy_dir_to_lxc "$ctid" "$GENERATED_DIR/npm" /tmp/homelab-npm-hosts
    pct_exec "$ctid" "chmod +x $sync_script && NPM_URL=http://127.0.0.1:81 NPM_EMAIL=$(quote "$NPM_LOGIN_EMAIL") NPM_PASSWORD=$(quote "$NPM_LOGIN_PASSWORD") HOMELAB_PRUNE_MANAGED_NPM_HOSTS=$(quote "$HOMELAB_PRUNE_MANAGED_NPM_HOSTS") python3 $sync_script --payload-dir /tmp/homelab-npm-hosts" || \
        warn "Could not reconcile Nginx Proxy Manager proxy hosts automatically; review the NPM UI or container logs."
}

install_dokploy_lxc() {
    local ctid="$1"
    local sync_env
    local sync_timer
    local cloudflare_dns_target
    local dokploy_admin_password

    bootstrap_lxc "$ctid"
    install_docker "$ctid"
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get install -y curl python3"

    info "Installing Dokploy in LXC $ctid"
    pct_exec "$ctid" "mkdir -p /etc/homelab && if [[ -f /etc/homelab/dokploy-installed ]] || docker ps -a --format '{{.Names}}' | grep -Eq '(^dokploy$|dokploy)'; then echo 'Dokploy already appears to be installed; skipping installer'; else export ADVERTISE_ADDR=$(quote "$DOKPLOY_IP"); curl -sSL $(quote "$DOKPLOY_INSTALL_URL") | sh && touch /etc/homelab/dokploy-installed; fi"

    dokploy_admin_password="${DOKPLOY_ADMIN_PASSWORD:-$(strong_secret_file "$SECRETS_DIR/dokploy-admin-password" 24)}"
    printf '%s\n' "$DOKPLOY_ADMIN_EMAIL" > "$SECRETS_DIR/dokploy-admin-email"
    printf '%s\n' "$dokploy_admin_password" > "$SECRETS_DIR/dokploy-admin-password"
    chmod 600 "$SECRETS_DIR/dokploy-admin-email"
    chmod 600 "$SECRETS_DIR/dokploy-admin-password"
    if [[ -n "$DOKPLOY_API_TOKEN" ]]; then
        printf '%s\n' "$DOKPLOY_API_TOKEN" > "$SECRETS_DIR/dokploy-api-key"
        chmod 600 "$SECRETS_DIR/dokploy-api-key"
    fi

    if [[ -z "$DOKPLOY_API_TOKEN" ]]; then
        info "Bootstrapping Dokploy admin/API key for domain sync"
        pct push "$ctid" "$SERVICES_DIR/dokploy/bootstrap-api-key.sh" /usr/local/bin/bootstrap-dokploy-api-key
        pct_exec "$ctid" "chmod +x /usr/local/bin/bootstrap-dokploy-api-key && mkdir -p /etc/homelab && DOKPLOY_URL=http://127.0.0.1:$(quote "$DOKPLOY_PORT") DOKPLOY_ADMIN_EMAIL=$(quote "$DOKPLOY_ADMIN_EMAIL") DOKPLOY_ADMIN_PASSWORD=$(quote "$dokploy_admin_password") DOKPLOY_ADMIN_FIRST_NAME=$(quote "$DOKPLOY_ADMIN_FIRST_NAME") DOKPLOY_ADMIN_LAST_NAME=$(quote "$DOKPLOY_ADMIN_LAST_NAME") /usr/local/bin/bootstrap-dokploy-api-key >/dev/null"
        DOKPLOY_API_TOKEN="$(pct_exec "$ctid" "cat /etc/homelab/dokploy-api-key")"
        printf '%s\n' "$DOKPLOY_API_TOKEN" > "$SECRETS_DIR/dokploy-api-key"
        chmod 600 "$SECRETS_DIR/dokploy-api-key"
    fi

    if [[ -n "$DOKPLOY_API_TOKEN" ]]; then
        info "Installing Dokploy to NPM sync timer in LXC $ctid"
        pct push "$ctid" "$SERVICES_DIR/dokploy/sync_npm_domains.py" /usr/local/bin/sync-dokploy-npm-domains
        pct push "$ctid" "$SERVICES_DIR/dokploy/sync-npm-domains.service" /etc/systemd/system/sync-dokploy-npm-domains.service
        pct_exec "$ctid" "chmod +x /usr/local/bin/sync-dokploy-npm-domains && mkdir -p /etc/homelab"

        sync_timer="$(mktemp)"
        cat > "$sync_timer" <<EOF
[Unit]
Description=Periodic Dokploy to Nginx Proxy Manager domain sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=${DOKPLOY_NPM_SYNC_INTERVAL_SECONDS}s
AccuracySec=10s
Unit=sync-dokploy-npm-domains.service

[Install]
WantedBy=timers.target
EOF
        pct push "$ctid" "$sync_timer" /etc/systemd/system/sync-dokploy-npm-domains.timer
        rm -f "$sync_timer"

        cloudflare_dns_target="${DOKPLOY_CLOUDFLARE_DNS_TARGET:-$(get_ip)}"
        sync_env="$(mktemp)"
        cat > "$sync_env" <<EOF
DOKPLOY_URL=http://127.0.0.1:${DOKPLOY_PORT}/api
DOKPLOY_API_TOKEN=$DOKPLOY_API_TOKEN
DOKPLOY_DOMAIN=$DOKPLOY_DOMAIN
DOKPLOY_IP=$DOKPLOY_IP
DOKPLOY_NPM_FORWARD_SCHEME=$DOKPLOY_NPM_FORWARD_SCHEME
DOKPLOY_NPM_FORWARD_PORT=$DOKPLOY_NPM_FORWARD_PORT
DOKPLOY_NPM_AUTO_CERTS=$DOKPLOY_NPM_AUTO_CERTS
NPM_URL=http://$PROXY_IP:81
NPM_EMAIL=$NPM_LOGIN_EMAIL
NPM_PASSWORD=$NPM_LOGIN_PASSWORD
DOKPLOY_SYNC_HTTP_TIMEOUT=180
DOKPLOY_CLOUDFLARE_DNS_API_TOKEN=$DOKPLOY_CLOUDFLARE_DNS_API_TOKEN
DOKPLOY_CLOUDFLARE_DNS_TARGET=$cloudflare_dns_target
DOKPLOY_CLOUDFLARE_DNS_ZONES=$DOKPLOY_CLOUDFLARE_DNS_ZONES
DOKPLOY_CLOUDFLARE_DNS_PROXIED=$DOKPLOY_CLOUDFLARE_DNS_PROXIED
DOKPLOY_CLOUDFLARE_DNS_TTL=$DOKPLOY_CLOUDFLARE_DNS_TTL
NPM_DNS_PROPAGATION_SECONDS=$NPM_DNS_PROPAGATION_SECONDS
EOF
        chmod 600 "$sync_env"
        pct push "$ctid" "$sync_env" /etc/homelab/dokploy-npm-sync.env
        rm -f "$sync_env"
        pct_exec "$ctid" "chmod 600 /etc/homelab/dokploy-npm-sync.env && systemctl daemon-reload && systemctl enable --now sync-dokploy-npm-domains.timer"
    fi

    if [[ "$HOMELAB_NETWORK_DIAGNOSTICS" == "true" ]]; then
        diagnose_lxc_networking "$ctid"
    fi
}

configure_npm_lets_encrypt() {
    local ctid="$PROXY_CTID"

    info "Trying to request and attach Nginx Proxy Manager Let's Encrypt certificate"
    pct_exec "$ctid" "for i in \$(seq 1 60); do curl -fsS http://127.0.0.1:81/api >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || {
        warn "Nginx Proxy Manager API was not ready; request the Let's Encrypt certificate manually in the UI."
        return
    }

    pct push "$ctid" "$SERVICES_DIR/proxy/configure-npm-ssl.sh" /tmp/configure-npm-ssl.sh
    pct_exec "$ctid" "chmod +x /tmp/configure-npm-ssl.sh && NPM_URL=http://127.0.0.1:81 NPM_EMAIL=$(quote "$NPM_LOGIN_EMAIL") NPM_PASSWORD=$(quote "$NPM_LOGIN_PASSWORD") LE_EMAIL=$(quote "$LE_EMAIL") AUTH_DOMAIN=$(quote "$AUTH_DOMAIN") HEADSCALE_DOMAIN=$(quote "$HEADSCALE_DOMAIN") HEADPLANE_DOMAIN=$(quote "$HEADPLANE_DOMAIN") OPENPANEL_CLIENT_PANEL_DOMAIN=$(quote "$OPENPANEL_CLIENT_PANEL_DOMAIN") MAIL_DOMAIN=$(quote "$MAIL_DOMAIN") EMAIL_APP_DOMAIN=$(quote "$EMAIL_APP_DOMAIN") WEBMAIL_DOMAIN=$(quote "$WEBMAIL_DOMAIN") LISTMONK_DOMAIN=$(quote "$LISTMONK_DOMAIN") POSTAL_DOMAIN=$(quote "$POSTAL_DOMAIN") LIBREDESK_DOMAIN=$(quote "$LIBREDESK_DOMAIN") AUTODISCOVER_DOMAIN=$(quote "$AUTODISCOVER_DOMAIN") AUTOCONFIG_DOMAIN=$(quote "$AUTOCONFIG_DOMAIN") MTA_STS_DOMAIN=$(quote "$MTA_STS_DOMAIN") NPM_DNS_CHALLENGE_PROVIDER=$(quote "$NPM_DNS_CHALLENGE_PROVIDER") NPM_DNS_PROPAGATION_SECONDS=$(quote "$NPM_DNS_PROPAGATION_SECONDS") NPM_SKIP_CLOUDFLARE_DNS_TOKEN=$(quote "$NPM_SKIP_CLOUDFLARE_DNS_TOKEN") CLOUDFLARE_DNS_API_TOKEN=$(quote "$NPM_CLOUDFLARE_DNS_API_TOKEN") /tmp/configure-npm-ssl.sh" || {
        warn "Could not automate NPM Let's Encrypt setup. Set NPM_CLOUDFLARE_DNS_API_TOKEN or CLOUDFLARE_DNS_API_TOKEN for Cloudflare DNS-01, or set NPM_SKIP_CLOUDFLARE_DNS_TOKEN=true to force HTTP-01 with DNS-only records and public port 80."
        return
    }
}

install_auth_lxc() {
    local ctid="$1"
    local bootstrap_password bootstrap_token postgres_password secret_key

    bootstrap_lxc "$ctid"
    install_docker "$ctid"

    info "Deploying Authentik in LXC $ctid"
    bootstrap_password="${AUTHENTIK_BOOTSTRAP_PASSWORD:-$(strong_secret_file "$SECRETS_DIR/authentik-bootstrap-password" 24)}"
    bootstrap_token="${AUTHENTIK_BOOTSTRAP_TOKEN:-$(secret_file "$SECRETS_DIR/authentik-bootstrap-token" 48)}"
    postgres_password="${AUTHENTIK_POSTGRES_PASSWORD:-$(secret_file "$SECRETS_DIR/authentik-postgres-password" 32)}"
    secret_key="${AUTHENTIK_SECRET_KEY:-$(secret_file "$SECRETS_DIR/authentik-secret-key" 64)}"
    printf '%s\n' "$AUTHENTIK_BOOTSTRAP_EMAIL" > "$SECRETS_DIR/authentik-bootstrap-email"
    printf '%s\n' "$bootstrap_password" > "$SECRETS_DIR/authentik-bootstrap-password"
    printf '%s\n' "$bootstrap_token" > "$SECRETS_DIR/authentik-bootstrap-token"
    chmod 600 "$SECRETS_DIR/authentik-bootstrap-email" "$SECRETS_DIR/authentik-bootstrap-password" "$SECRETS_DIR/authentik-bootstrap-token"

    export AUTHENTIK_IMAGE AUTHENTIK_TAG AUTHENTIK_BOOTSTRAP_EMAIL
    export AUTHENTIK_BOOTSTRAP_PASSWORD="$bootstrap_password"
    export AUTHENTIK_BOOTSTRAP_TOKEN="$bootstrap_token"
    export AUTHENTIK_POSTGRES_USER AUTHENTIK_POSTGRES_DB
    export AUTHENTIK_POSTGRES_PASSWORD="$postgres_password"
    export AUTHENTIK_SECRET_KEY="$secret_key"
    export AUTHENTIK_EMAIL__HOST AUTHENTIK_EMAIL__PORT AUTHENTIK_EMAIL__USERNAME AUTHENTIK_EMAIL__PASSWORD AUTHENTIK_EMAIL__FROM

    python3 "$SERVICES_DIR/auth/render.py" --output-dir "$GENERATED_DIR/authentik"

    copy_dir_to_lxc "$ctid" "$GENERATED_DIR/authentik" /opt/authentik
    pct_exec "$ctid" "chmod +x /opt/authentik/start.sh && chmod 600 /opt/authentik/.env && /opt/authentik/start.sh"

    if [[ "$HOMELAB_NETWORK_DIAGNOSTICS" == "true" ]]; then
        diagnose_lxc_networking "$ctid"
    fi
}

wait_for_headscale_container() {
    local ctid="$1"

    pct_exec "$ctid" "for i in \$(seq 1 60); do docker exec headscale headscale -c /shared/headscale_config.yaml health >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
}

headscale_nodes_json() {
    local ctid="$1"
    pct_exec "$ctid" "docker exec headscale headscale nodes list -o json-line 2>/dev/null"
}

headscale_proxy_node_id() {
    local ctid="$1"
    headscale_nodes_json "$ctid" | python3 -c 'import json, sys; name=sys.argv[1]; data=json.load(sys.stdin); print(next((str(node.get("id", "")) for node in data if node.get("name") == name or node.get("given_name") == name), ""))' "$PROXY_HOSTNAME"
}

headscale_proxy_tailnet_ip() {
    local ctid="$1"
    headscale_nodes_json "$ctid" | python3 -c 'import ipaddress, json, sys; name=sys.argv[1]; data=json.load(sys.stdin); node=next((item for item in data if item.get("name") == name or item.get("given_name") == name), {}); print(next((ip for ip in node.get("ip_addresses", []) if ipaddress.ip_address(ip).version == 4), ""))' "$PROXY_HOSTNAME"
}

headscale_preauth_key() {
    local ctid="$1"
    local file="$2"
    local expiration="$3"
    local key
    local user_id

    info "Creating reusable Headscale pre-auth key"
    pct_exec "$ctid" "docker exec headscale headscale -c /shared/headscale_config.yaml users create admin >/dev/null 2>&1 || true"
    user_id="$(pct_exec "$ctid" "docker exec headscale headscale -c /shared/headscale_config.yaml users list -o json | jq -r '.[] | select(.name == \"admin\") | .id' | head -n1")"
    [[ -n "$user_id" && "$user_id" != "null" ]] || error "Could not find Headscale user ID for admin"
    key="$(pct_exec "$ctid" "docker exec headscale headscale -c /shared/headscale_config.yaml preauthkeys create --user $(quote "$user_id") --reusable --expiration $(quote "$expiration")")"
    [[ -n "$key" ]] || error "Could not create Headscale pre-auth key"
    echo "$key" > "$file"
    chmod 600 "$file"
}

install_tailscale_proxy_lxc() {
    local key
    local key_file="$SECRETS_DIR/headscale-admin-preauth-key"
    local node_id=""
    local proxy_tailnet_ip=""

    headscale_preauth_key "$HEADSCALE_CTID" "$key_file" "$HEADSCALE_PREAUTH_KEY_EXPIRATION"
    key="$(cat "$key_file")"
    ensure_proxy_tun "$PROXY_CTID"

    info "Installing Tailscale client in proxy LXC $PROXY_CTID"
    pct_exec "$PROXY_CTID" "if ! command -v tailscale >/dev/null 2>&1; then curl -fsSL https://tailscale.com/install.sh | sh; fi"
    pct_exec "$PROXY_CTID" "systemctl enable --now tailscaled"
    pct_exec "$PROXY_CTID" "tailscale up --login-server=$(quote "$HEADSCALE_INTERNAL_URL") --authkey=$(quote "$key") --hostname=$(quote "$PROXY_HOSTNAME") --accept-dns=false --advertise-routes=$(quote "$NETWORK_PREFIX.0/24")"

    info "Waiting for proxy LXC to register and advertise subnet route"
    for _ in $(seq 1 30); do
        node_id="$(headscale_proxy_node_id "$HEADSCALE_CTID" 2>/dev/null || true)"
        proxy_tailnet_ip="$(headscale_proxy_tailnet_ip "$HEADSCALE_CTID" 2>/dev/null || true)"
        if [[ -n "$node_id" && -n "$proxy_tailnet_ip" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -n "$node_id" ]]; then
        info "Approving tailnet route $NETWORK_PREFIX.0/24 for node $PROXY_HOSTNAME (ID: $node_id)"
        pct_exec "$HEADSCALE_CTID" "docker exec headscale headscale nodes approve-routes -i $(quote "$node_id") -r $(quote "$NETWORK_PREFIX.0/24")" >/dev/null 2>&1 || \
            warn "Could not auto-approve tailnet route for node $node_id; approve it manually in Headplane"
    else
        warn "Tailnet route $NETWORK_PREFIX.0/24 was not advertised in time; approve it manually in Headplane"
    fi

    if [[ -n "$proxy_tailnet_ip" ]]; then
        info "Writing tailnet-only DNS records for internal admin services -> $proxy_tailnet_ip"
        python3 - "$OPENPANEL_ADMIN_DOMAIN" "$DOKPLOY_DOMAIN" "$proxy_tailnet_ip" <<'PY' > "$GENERATED_DIR/headscale-tailnet-dns.json"
import json
import sys

records = [
    {"name": domain, "type": "A", "value": sys.argv[3]}
    for domain in sys.argv[1:3]
    if domain
]
print(json.dumps(records, indent=2))
PY
        pct push "$HEADSCALE_CTID" "$GENERATED_DIR/headscale-tailnet-dns.json" /opt/headscale-stack/dns_records.json
        pct_exec "$HEADSCALE_CTID" "cd /opt/headscale-stack && docker compose restart headscale >/dev/null" || \
            warn "Could not update tailnet-only DNS records for internal admin services"
    fi
}

render_headscale_stack() {
    local api_key="${1:-}"

    if [[ -z "$PROXY_TAILNET_IP" ]] && pct status "$HEADSCALE_CTID" >/dev/null 2>&1; then
        PROXY_TAILNET_IP="$(headscale_proxy_tailnet_ip "$HEADSCALE_CTID" 2>/dev/null || true)"
    fi

    export DOMAIN AUTH_DOMAIN HEADSCALE_DOMAIN HEADPLANE_DOMAIN OPENPANEL_ADMIN_DOMAIN DOKPLOY_DOMAIN PROXY_TAILNET_IP
    export HEADSCALE_VERSION="${HEADSCALE_VERSION:-0.28.0}"
    export HEADPLANE_VERSION="${HEADPLANE_VERSION:-latest}"
    export HEADSCALE_URL="http://headscale:8080"
    export HEADSCALE_PUBLIC_URL
    export HEADPLANE_SERVER__BASE_URL="https://$HEADPLANE_DOMAIN"
    export SERVER_URL="$HEADSCALE_PUBLIC_URL"
    export DNS_BASE_DOMAIN="tailnet.$DOMAIN"
    export HEADSCALE_OIDC_CLIENT_ID="${HEADSCALE_OIDC_CLIENT_ID:-headscale}"
    export HEADSCALE_OIDC_CLIENT_SECRET
    export HEADSCALE_OIDC_ISSUER="${HEADSCALE_OIDC_ISSUER:-https://$AUTH_DOMAIN/application/o/headscale/}"
    export HEADSCALE_OIDC_ALLOWED_GROUP="${HEADSCALE_OIDC_ALLOWED_GROUP:-headscale}"
    export HEADPLANE_SERVER__COOKIE_SECRET
    export HEADPLANE_SERVER__INFO_SECRET
    export HEADSCALE_API_KEY="$api_key"
    export HEADPLANE_AGENT_PRE_AUTHKEY="${HEADPLANE_AGENT_PRE_AUTHKEY:-}"

    python3 "$SERVICES_DIR/headscale/render.py" --output-dir "$GENERATED_DIR/headscale"
}

install_headscale_lxc() {
    local ctid="$1"
    local oidc_secret cookie_secret info_secret api_key preauth_key

    bootstrap_lxc "$ctid"
    install_docker "$ctid"

    oidc_secret="$(secret_file "$SECRETS_DIR/oidc-headscale-client-secret" 48)"
    cookie_secret="$(secret_file "$SECRETS_DIR/headplane-cookie-secret" 32)"
    info_secret="$(secret_file "$SECRETS_DIR/headplane-info-secret" 32)"
    api_key=""

    if [[ -s "$SECRETS_DIR/headscale-api-key" ]]; then
        api_key="$(cat "$SECRETS_DIR/headscale-api-key")"
    fi

    export HEADSCALE_OIDC_CLIENT_SECRET="$oidc_secret"
    export HEADSCALE_OIDC_ISSUER="${HEADSCALE_OIDC_ISSUER:-https://$AUTH_DOMAIN/application/o/headscale/}"
    export HEADPLANE_SERVER__COOKIE_SECRET="$cookie_secret"
    export HEADPLANE_SERVER__INFO_SECRET="$info_secret"

    render_headscale_stack "$api_key"
    copy_dir_to_lxc "$ctid" "$GENERATED_DIR/headscale" /opt/headscale-stack
    pct_exec "$ctid" "chmod +x /opt/headscale-stack/start.sh && cd /opt/headscale-stack && docker compose up -d --build config-init headscale"
    wait_for_headscale_container "$ctid"

    if [[ ! -s "$SECRETS_DIR/headscale-api-key" ]]; then
        api_key="$(pct_exec "$ctid" "docker exec headscale headscale -c /shared/headscale_config.yaml apikeys create --expiration 8760h")"
        echo "$api_key" > "$SECRETS_DIR/headscale-api-key"
        chmod 600 "$SECRETS_DIR/headscale-api-key"

        render_headscale_stack "$api_key"
        copy_dir_to_lxc "$ctid" "$GENERATED_DIR/headscale" /opt/headscale-stack
        pct_exec "$ctid" "cd /opt/headscale-stack && docker compose up -d --build --force-recreate config-init"
    fi

    pct_exec "$ctid" "cd /opt/headscale-stack && docker compose up -d --build"
    wait_for_headscale_container "$ctid"

    headscale_preauth_key "$ctid" "$SECRETS_DIR/headscale-admin-preauth-key" "$HEADSCALE_PREAUTH_KEY_EXPIRATION"

    if [[ "$HOMELAB_NETWORK_DIAGNOSTICS" == "true" ]]; then
        diagnose_lxc_networking "$ctid"
    fi
}

configure_host_dnat() {
    local main_interface
    main_interface="$(ip route | awk '/default/ { print $5; exit }')"
    [[ -n "$main_interface" ]] || error "Could not detect the public/default interface for DNAT."

    info "Forwarding public HTTP/HTTPS to Nginx Proxy Manager at $PROXY_IP"
    iptables -t nat -C PREROUTING -i "$main_interface" -p tcp --dport 80 -j DNAT --to-destination "$PROXY_IP:80" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$main_interface" -p tcp --dport 80 -j DNAT --to-destination "$PROXY_IP:80"
    iptables -t nat -C PREROUTING -i "$main_interface" -p tcp --dport 443 -j DNAT --to-destination "$PROXY_IP:443" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$main_interface" -p tcp --dport 443 -j DNAT --to-destination "$PROXY_IP:443"
    iptables -C FORWARD -p tcp -d "$PROXY_IP" --dport 80 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -p tcp -d "$PROXY_IP" --dport 80 -j ACCEPT
    iptables -C FORWARD -p tcp -d "$PROXY_IP" --dport 443 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -p tcp -d "$PROXY_IP" --dport 443 -j ACCEPT

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
}

configure_mail_dnat() {
    local main_interface port
    main_interface="$(ip route | awk '/default/ { print $5; exit }')"
    [[ -n "$main_interface" ]] || error "Could not detect the public/default interface for mail DNAT."

    info "Freeing host mail ports before forwarding them to $MAIL_IP"
    free_mail_ports

    info "Forwarding public mail ports to email-service at $MAIL_IP"
    for port in $MAIL_PORTS; do
        iptables -t nat -C PREROUTING -i "$main_interface" -p tcp --dport "$port" -j DNAT --to-destination "$MAIL_IP:$port" 2>/dev/null || \
            iptables -t nat -A PREROUTING -i "$main_interface" -p tcp --dport "$port" -j DNAT --to-destination "$MAIL_IP:$port"
        iptables -C FORWARD -p tcp -d "$MAIL_IP" --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -p tcp -d "$MAIL_IP" --dport "$port" -j ACCEPT
    done

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
}

configure_internal_dns() {
    local dnsmasq_file="/etc/dnsmasq.d/homelab-services.conf"
    local tmp

    if ! command -v dnsmasq >/dev/null 2>&1; then
        warn "dnsmasq is not installed; internal clients may hairpin through the public IP."
        return
    fi

    info "Writing split-horizon DNS records for homelab service domains"
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# Homelab split-horizon records.
# Internal clients resolve public service names directly to Nginx Proxy Manager.
address=/$PROXY_DOMAIN/$PROXY_IP
address=/$AUTH_DOMAIN/$PROXY_IP
address=/$HEADSCALE_DOMAIN/$PROXY_IP
address=/$HEADPLANE_DOMAIN/$PROXY_IP
address=/$OPENPANEL_CLIENT_PANEL_DOMAIN/$PROXY_IP
address=/$OPENPANEL_ADMIN_DOMAIN/$OPENPANEL_IP
address=/$DOKPLOY_DOMAIN/$DOKPLOY_IP
address=/$MAIL_DOMAIN/$MAIL_IP
address=/$EMAIL_APP_DOMAIN/$MAIL_IP
address=/$WEBMAIL_DOMAIN/$MAIL_IP
address=/$LISTMONK_DOMAIN/$MAIL_IP
address=/$POSTAL_DOMAIN/$MAIL_IP
address=/$LIBREDESK_DOMAIN/$MAIL_IP
address=/$AUTODISCOVER_DOMAIN/$MAIL_IP
address=/$AUTOCONFIG_DOMAIN/$MAIL_IP
address=/$MTA_STS_DOMAIN/$MAIL_IP
EOF
    if [[ -f "$dnsmasq_file" ]] && cmp -s "$tmp" "$dnsmasq_file"; then
        rm -f "$tmp"
        info "$dnsmasq_file is already up to date"
        return
    fi

    cp "$tmp" "$dnsmasq_file"
    rm -f "$tmp"

    dnsmasq --test
    systemctl restart dnsmasq
}

write_summary() {
    local preauth_key=""
    local public_ip
    [[ -s "$SECRETS_DIR/headscale-admin-preauth-key" ]] && preauth_key="$(cat "$SECRETS_DIR/headscale-admin-preauth-key")"
    public_ip="$(get_ip)"

    cat > "$STATE_DIR/access.txt" <<EOF
Homelab service LXCs
====================

Base domain: $DOMAIN

LXC layout:
- Nginx Proxy Manager: $PROXY_CTID $PROXY_IP ($PROXY_HOSTNAME)
- Authentik auth/OIDC: $AUTH_CTID $AUTH_IP ($AUTH_HOSTNAME)
- Headscale + Headplane: $HEADSCALE_CTID $HEADSCALE_IP ($HEADSCALE_HOSTNAME)
- Mail/email-service: $MAIL_CTID $MAIL_IP ($MAIL_HOSTNAME)
- OpenPanel VM: $OPENPANEL_VMID $OPENPANEL_IP ($OPENPANEL_HOSTNAME)
- Dokploy: $DOKPLOY_CTID $DOKPLOY_IP ($DOKPLOY_HOSTNAME)

Public DNS records to create:
- $AUTH_DOMAIN -> $public_ip
- $HEADSCALE_DOMAIN -> $public_ip
- $HEADPLANE_DOMAIN -> $public_ip
- $OPENPANEL_CLIENT_PANEL_DOMAIN -> $public_ip
- $MAIL_DOMAIN -> $public_ip
- $EMAIL_APP_DOMAIN -> $public_ip
- $WEBMAIL_DOMAIN -> $public_ip
- $LISTMONK_DOMAIN -> $public_ip
- $POSTAL_DOMAIN -> $public_ip
- $LIBREDESK_DOMAIN -> $public_ip
- $AUTODISCOVER_DOMAIN -> $public_ip
- $AUTOCONFIG_DOMAIN -> $public_ip
- $MTA_STS_DOMAIN -> $public_ip
- MX for $DOMAIN -> $MAIL_DOMAIN

Nginx Proxy Manager:
- Internal admin URL: http://$PROXY_IP:81
- Admin login verified by automation: $NPM_LOGIN_EMAIL / $NPM_LOGIN_PASSWORD
- Add proxy hosts:
  - $AUTH_DOMAIN -> http://$AUTH_IP:$AUTH_PORT
  - $HEADSCALE_DOMAIN -> http://$HEADSCALE_IP:8080
  - $HEADPLANE_DOMAIN -> http://$HEADSCALE_IP:3000
  - $OPENPANEL_CLIENT_PANEL_DOMAIN -> $OPENPANEL_CLIENT_PANEL_SCHEME://$OPENPANEL_IP:$OPENPANEL_CLIENT_PANEL_PORT
  - $DOKPLOY_DOMAIN -> http://$DOKPLOY_IP:$DOKPLOY_PORT (tailnet/internal only)
  - $MAIL_DOMAIN, $AUTODISCOVER_DOMAIN, $AUTOCONFIG_DOMAIN, $MTA_STS_DOMAIN -> http://$MAIL_IP:8080
  - $EMAIL_APP_DOMAIN -> http://$MAIL_IP:3001
  - $WEBMAIL_DOMAIN -> http://$MAIL_IP:3000
  - $LISTMONK_DOMAIN -> http://$MAIL_IP:9000
  - $POSTAL_DOMAIN -> http://$MAIL_IP:5000
  - $LIBREDESK_DOMAIN -> http://$MAIL_IP:9001
- Request Let's Encrypt certificates for those hosts using $LE_EMAIL.

Authentik:
- URL: https://$AUTH_DOMAIN
- Initial user: $(cat "$SECRETS_DIR/authentik-bootstrap-email" 2>/dev/null || true)
- Initial password: $(cat "$SECRETS_DIR/authentik-bootstrap-password" 2>/dev/null || true)
- Bootstrap token: $(cat "$SECRETS_DIR/authentik-bootstrap-token" 2>/dev/null || true)
- Headscale OIDC issuer: ${HEADSCALE_OIDC_ISSUER:-https://$AUTH_DOMAIN/application/o/headscale/}
- Configure an Authentik OAuth2/OpenID provider with slug/client ID "headscale" and the shared client secret in $SECRETS_DIR/oidc-headscale-client-secret.

Headscale:
- URL: $HEADSCALE_PUBLIC_URL
- Login command: tailscale up --login-server=$HEADSCALE_PUBLIC_URL
- Proxy LXC advertises tailnet route: $NETWORK_PREFIX.0/24 (approve in Headscale/Headplane)
EOF

    if [[ -n "$preauth_key" ]]; then
        cat >> "$STATE_DIR/access.txt" <<EOF
- Reusable pre-auth command for your PC:
  tailscale up --login-server=$HEADSCALE_PUBLIC_URL --authkey=$preauth_key
- Proxy admin over tailnet after your PC joins:
  http://$PROXY_HOSTNAME.tailnet.$DOMAIN:81
EOF
    fi

    cat >> "$STATE_DIR/access.txt" <<EOF

Headplane:
- URL: https://$HEADPLANE_DOMAIN

OpenPanel:
- Client panel URL: https://$OPENPANEL_CLIENT_PANEL_DOMAIN
- Internal admin URL: http://$OPENPANEL_ADMIN_DOMAIN
- VM: $OPENPANEL_VMID $OPENPANEL_IP ($OPENPANEL_HOSTNAME)
- OpenAdmin user: $(cat "$SECRETS_DIR/openadmin-user" 2>/dev/null || true)
- OpenAdmin password: $(cat "$SECRETS_DIR/openadmin-password" 2>/dev/null || true)
- NPM domain sync timer: sync-npm-domains.timer in the OpenPanel VM

Dokploy:
- Tailnet/internal URL: http://$DOKPLOY_DOMAIN
- LXC: $DOKPLOY_CTID $DOKPLOY_IP ($DOKPLOY_HOSTNAME)
- NPM route: http://$DOKPLOY_IP:$DOKPLOY_PORT
- Admin user: $(cat "$SECRETS_DIR/dokploy-admin-email" 2>/dev/null || true)
- Admin password: $(cat "$SECRETS_DIR/dokploy-admin-password" 2>/dev/null || true)
- API key: $(cat "$SECRETS_DIR/dokploy-api-key" 2>/dev/null || true)
- NPM domain sync timer: sync-dokploy-npm-domains.timer in the Dokploy LXC

Mail/email-service:
- Repo: $EMAIL_SERVICE_REPO
- Ref: $EMAIL_SERVICE_REF
- Path in LXC: /opt/email-service
- Started with: docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d
- Stalwart HTTP is routed through Nginx Proxy Manager to http://$MAIL_IP:8080
- Email app dashboard is routed through Nginx Proxy Manager to http://$MAIL_IP:3001
- Webmail is routed through Nginx Proxy Manager to http://$MAIL_IP:3000
- Public mail ports forwarded to $MAIL_IP: $MAIL_PORTS
- Stalwart admin user: ${STALWART_ADMIN_USER:-admin}
- Stalwart admin password: ${STALWART_ADMIN_PASSWORD:-$(cat "$SECRETS_DIR/stalwart-admin-password" 2>/dev/null || true)}
- Listmonk admin user: ${LISTMONK_ADMIN_USER:-admin}
- Listmonk admin password: ${LISTMONK_ADMIN_PASSWORD:-$(cat "$SECRETS_DIR/listmonk-admin-password" 2>/dev/null || true)}
- LibreDesk system user password: ${LIBREDESK_SYSTEM_USER_PASSWORD:-$(cat "$SECRETS_DIR/libredesk-system-user-password" 2>/dev/null || true)}

Secrets are stored under:
- $SECRETS_DIR
EOF

    chmod 600 "$STATE_DIR/access.txt"
    info "Wrote access summary to $STATE_DIR/access.txt"
}

main() {
    local template
    local openpanel_memory
    local openpanel_cores
    local dokploy_memory
    local dokploy_cores
    require_proxmox
    validate_homelab_network_mode
    template="$(ensure_template)"
    validate_template_ref "$template"
    openpanel_memory="$(resolve_openpanel_memory_mb)"
    openpanel_cores="$(resolve_openpanel_cores)"
    dokploy_memory="$(resolve_dokploy_memory_mb)"
    dokploy_cores="$(resolve_dokploy_cores)"

    ensure_lxc "$PROXY_CTID" "$PROXY_HOSTNAME" "$PROXY_IP" 768 1 8 "$template"
    ensure_lxc "$AUTH_CTID" "$AUTH_HOSTNAME" "$AUTH_IP" "$AUTHENTIK_MEMORY_MB" 1 6 "$template"
    ensure_lxc "$HEADSCALE_CTID" "$HEADSCALE_HOSTNAME" "$HEADSCALE_IP" 768 1 6 "$template"
    ensure_lxc "$MAIL_CTID" "$MAIL_HOSTNAME" "$MAIL_IP" 5120 2 40 "$template"
    ensure_lxc "$DOKPLOY_CTID" "$DOKPLOY_HOSTNAME" "$DOKPLOY_IP" "$dokploy_memory" "$dokploy_cores" "$DOKPLOY_DISK_GB" "$template"
    ensure_lxc_resources "$DOKPLOY_CTID" "$dokploy_memory" "$dokploy_cores"

    install_proxy_lxc "$PROXY_CTID"
    harden_npm_admin
    ensure_openpanel_vm "$openpanel_memory" "$openpanel_cores"
    install_dokploy_lxc "$DOKPLOY_CTID"
    install_auth_lxc "$AUTH_CTID"
    install_headscale_lxc "$HEADSCALE_CTID"
    install_mail_lxc "$MAIL_CTID"
    install_tailscale_proxy_lxc
    seed_npm_proxy_hosts
    configure_host_dnat
    configure_mail_dnat
    configure_npm_lets_encrypt
    configure_internal_dns
    write_summary
}

main "$@"
