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

VM_BRIDGE="${HOMELAB_BRIDGE:-vmbr10}"
NETWORK_PREFIX="${HOMELAB_NETWORK_PREFIX:-10.10.10}"
GATEWAY_IP="${HOMELAB_GATEWAY_IP:-$NETWORK_PREFIX.1}"
PROXY_CTID="${PROXY_CTID:-110}"
AUTH_CTID="${AUTH_CTID:-111}"
HEADSCALE_CTID="${HEADSCALE_CTID:-112}"
PROXY_IP="${PROXY_IP:-$NETWORK_PREFIX.10}"
AUTH_IP="${AUTH_IP:-$NETWORK_PREFIX.20}"
HEADSCALE_IP="${HEADSCALE_IP:-$NETWORK_PREFIX.30}"
PROXY_HOSTNAME="${PROXY_HOSTNAME:-homelab-proxy}"
AUTH_HOSTNAME="${AUTH_HOSTNAME:-homelab-auth}"
HEADSCALE_HOSTNAME="${HEADSCALE_HOSTNAME:-homelab-headscale}"
PROXY_DOMAIN="${PROXY_DOMAIN:-proxy.$DOMAIN}"
AUTH_DOMAIN="${AUTH_DOMAIN:-auth.$DOMAIN}"
HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN:-headscale.$DOMAIN}"
HEADPLANE_DOMAIN="${HEADPLANE_DOMAIN:-headplane.$DOMAIN}"
LE_EMAIL="${LE_EMAIL:-admin@$DOMAIN}"
AUTH_ADMIN_USER="${AUTH_ADMIN_USER:-admin}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-admin@example.com}"
NPM_DEFAULT_PASSWORD="${NPM_DEFAULT_PASSWORD:-changeme}"
STATE_DIR="${STATE_DIR:-/root/homelab}"
SECRETS_DIR="$STATE_DIR/secrets"
GENERATED_DIR="$STATE_DIR/generated"
SERVICES_DIR="$SCRIPT_DIR/services"

mkdir -p "$SECRETS_DIR" "$GENERATED_DIR"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Required command missing: $1"
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

random_token() {
    openssl rand -hex "$(((${1:-32} + 1) / 2))" | cut -c "1-${1:-32}"
}

secret_file() {
    local file="$1"
    local length="${2:-32}"
    if [[ ! -s "$file" ]]; then
        random_token "$length" > "$file"
        chmod 600 "$file"
    fi
    cat "$file"
}

quote() {
    printf "%q" "$1"
}

pct_exec() {
    local ctid="$1"
    shift
    pct exec "$ctid" -- bash -lc "$*"
}

copy_dir_to_lxc() {
    local ctid="$1" src="$2" dest="$3"

    pct_exec "$ctid" "rm -rf $(quote "$dest") && mkdir -p $(quote "$dest")"
    tar -C "$src" -cf - . | pct exec "$ctid" -- tar -C "$dest" -xf -
}

require_proxmox() {
    need_cmd pct
    need_cmd pveam
    need_cmd pvesm
    need_cmd openssl
    ensure_host_python
}

template_storage() {
    pvesm status --content vztmpl | awk 'NR > 1 { print $1; exit }'
}

rootfs_storage() {
    pvesm status --content rootdir | awk 'NR > 1 { print $1; exit }'
}

ensure_template() {
    local storage template
    storage="$(template_storage)"
    [[ -n "$storage" ]] || error "No Proxmox storage with vztmpl content found."

    pveam update
    template="$(pveam available --section system | awk '/debian-12-standard/ { print $2 }' | sort -V | tail -n1)"
    [[ -n "$template" ]] || error "Could not find a Debian 12 LXC template."

    if ! pveam list "$storage" | awk '{ print $1 }' | grep -q "/$template$"; then
        info "Downloading LXC template $template to $storage"
        pveam download "$storage" "$template"
    fi

    echo "$storage:vztmpl/$template"
}

ensure_lxc() {
    local ctid="$1" hostname="$2" ip="$3" memory="$4" cores="$5" disk="$6" template="$7"
    local root_storage root_password

    if pct status "$ctid" >/dev/null 2>&1; then
        info "LXC $ctid ($hostname) already exists; ensuring it is running"
        pct start "$ctid" >/dev/null 2>&1 || true
        return
    fi

    root_storage="$(rootfs_storage)"
    [[ -n "$root_storage" ]] || error "No Proxmox storage with rootdir content found."
    root_password="$(secret_file "$SECRETS_DIR/lxc-root-password" 32)"

    info "Creating LXC $ctid ($hostname) at $ip"
    pct create "$ctid" "$template" \
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
        --start 1
}

bootstrap_lxc() {
    local ctid="$1"
    info "Bootstrapping base packages in LXC $ctid"
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ca-certificates curl file gnupg jq openssl sqlite3 tar ufw"
}

install_docker() {
    local ctid="$1"
    if pct_exec "$ctid" "command -v docker >/dev/null 2>&1"; then
        return
    fi

    info "Installing Docker in LXC $ctid"
    pct_exec "$ctid" "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh"
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get install -y docker-compose-plugin"
    pct_exec "$ctid" "systemctl enable --now docker"
}

install_proxy_lxc() {
    local ctid="$1"
    bootstrap_lxc "$ctid"
    install_docker "$ctid"

    info "Installing Nginx Proxy Manager in LXC $ctid"
    export NPM_VERSION="${NPM_VERSION:-latest}"
    python3 "$SERVICES_DIR/proxy/render.py" --output-dir "$GENERATED_DIR/proxy"
    copy_dir_to_lxc "$ctid" "$GENERATED_DIR/proxy" /opt/nginx-proxy-manager
    pct_exec "$ctid" "chmod +x /opt/nginx-proxy-manager/start.sh && /opt/nginx-proxy-manager/start.sh"
}

seed_npm_proxy_hosts() {
    local token payload name existing
    local ctid="$PROXY_CTID"

    info "Trying to seed Nginx Proxy Manager proxy hosts"
    pct_exec "$ctid" "for i in \$(seq 1 60); do curl -fsS http://127.0.0.1:81/api >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || {
        warn "Nginx Proxy Manager API was not ready; proxy hosts are listed in $STATE_DIR/access.txt"
        return
    }

    token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_ADMIN_EMAIL") --arg secret $(quote "$NPM_DEFAULT_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -z "$token" ]]; then
        warn "Could not log in to Nginx Proxy Manager with default first-run credentials; seed hosts manually in the UI."
        return
    fi

    export AUTH_DOMAIN AUTH_IP HEADSCALE_DOMAIN HEADSCALE_IP HEADPLANE_DOMAIN
    python3 "$SERVICES_DIR/proxy/render-npm-hosts.py" --output-dir "$GENERATED_DIR/npm"
    for payload in "$GENERATED_DIR"/npm/*.json; do
        name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain_names"][0])' "$payload")"
        existing="$(pct_exec "$ctid" "curl -fsS http://127.0.0.1:81/api/nginx/proxy-hosts -H 'Authorization: Bearer $(quote "$token")' | jq -r '.[] | select(.domain_names[]? == $(quote "$name")) | .id' | head -n1" 2>/dev/null || true)"
        if [[ -n "$existing" ]]; then
            info "Nginx Proxy Manager proxy host $name already exists; skipping seed"
            continue
        fi
        pct push "$ctid" "$payload" "/tmp/$(basename "$payload")"
        pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/nginx/proxy-hosts -H 'Authorization: Bearer $(quote "$token")' -H 'Content-Type: application/json' --data @/tmp/$(basename "$payload") >/dev/null" || \
            warn "Could not seed proxy host $name; it may already exist or NPM may have changed its API."
    done
}

install_auth_lxc() {
    local ctid="$1"
    local admin_password oidc_secret jwt_secret session_secret storage_key hmac_secret
    local headscale_client_hash admin_hash jwks_file jwks_indented

    bootstrap_lxc "$ctid"
    install_docker "$ctid"

    admin_password="$(secret_file "$SECRETS_DIR/authelia-admin-password" 24)"
    oidc_secret="$(secret_file "$SECRETS_DIR/oidc-headscale-client-secret" 48)"
    jwt_secret="$(secret_file "$SECRETS_DIR/authelia-jwt-secret" 64)"
    session_secret="$(secret_file "$SECRETS_DIR/authelia-session-secret" 64)"
    storage_key="$(secret_file "$SECRETS_DIR/authelia-storage-key" 64)"
    hmac_secret="$(secret_file "$SECRETS_DIR/authelia-oidc-hmac-secret" 64)"
    jwks_file="$SECRETS_DIR/authelia-oidc-private-key.pem"

    if [[ ! -s "$jwks_file" ]]; then
        openssl genrsa -out "$jwks_file" 2048
        chmod 600 "$jwks_file"
    fi
    jwks_indented="$(sed 's/^/          /' "$jwks_file")"

    info "Generating Authelia password and OIDC client hashes"
    admin_hash="$(pct_exec "$ctid" "docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password $(quote "$admin_password") | awk -F'Digest: ' '/Digest/ { print \$2 }'")"
    headscale_client_hash="$(pct_exec "$ctid" "docker run --rm authelia/authelia:latest authelia crypto hash generate pbkdf2 --password $(quote "$oidc_secret") | awk -F'Digest: ' '/Digest/ { print \$2 }'")"

    export AUTHELIA_VERSION="${AUTHELIA_VERSION:-latest}"
    export DOMAIN AUTH_DOMAIN HEADSCALE_DOMAIN HEADPLANE_DOMAIN AUTH_ADMIN_USER
    export AUTHELIA_JWT_SECRET="$jwt_secret"
    export AUTHELIA_SESSION_SECRET="$session_secret"
    export AUTHELIA_STORAGE_KEY="$storage_key"
    export AUTHELIA_OIDC_HMAC_SECRET="$hmac_secret"
    export AUTHELIA_OIDC_PRIVATE_KEY_INDENTED="$jwks_indented"
    export HEADSCALE_OIDC_CLIENT_SECRET_HASH="$headscale_client_hash"
    export AUTH_ADMIN_PASSWORD_HASH="$admin_hash"
    export AUTH_ADMIN_EMAIL="$LE_EMAIL"

    python3 "$SERVICES_DIR/auth/render.py" --output-dir "$GENERATED_DIR/authelia"

    copy_dir_to_lxc "$ctid" "$GENERATED_DIR/authelia" /opt/authelia
    pct_exec "$ctid" "chmod +x /opt/authelia/start.sh && chmod 600 /opt/authelia/config/*.yml && /opt/authelia/start.sh"
}

wait_for_headscale_container() {
    local ctid="$1"

    pct_exec "$ctid" "for i in \$(seq 1 60); do docker exec headscale headscale -c /shared/headscale_config.yaml health >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
}

render_headscale_stack() {
    local api_key="${1:-}"

    export DOMAIN AUTH_DOMAIN HEADSCALE_DOMAIN HEADPLANE_DOMAIN
    export HEADSCALE_VERSION="${HEADSCALE_VERSION:-0.28.0}"
    export HEADPLANE_VERSION="${HEADPLANE_VERSION:-latest}"
    export HEADSCALE_URL="http://headscale:8080"
    export HEADSCALE_PUBLIC_URL="https://$HEADSCALE_DOMAIN"
    export HEADPLANE_SERVER__BASE_URL="https://$HEADPLANE_DOMAIN"
    export SERVER_URL="https://$HEADSCALE_DOMAIN"
    export DNS_BASE_DOMAIN="tailnet.$DOMAIN"
    export HEADSCALE_OIDC_CLIENT_SECRET
    export HEADPLANE_SERVER__COOKIE_SECRET
    export HEADPLANE_SERVER__INFO_SECRET
    export HEADSCALE_API_KEY="$api_key"

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

    if [[ ! -s "$SECRETS_DIR/headscale-admin-preauth-key" ]]; then
        pct_exec "$ctid" "docker exec headscale headscale -c /shared/headscale_config.yaml users create admin >/dev/null 2>&1 || true"
        preauth_key="$(pct_exec "$ctid" "docker exec headscale headscale -c /shared/headscale_config.yaml preauthkeys create --user admin --reusable --expiration 24h 2>/dev/null || true")"
        if [[ -n "$preauth_key" ]]; then
            echo "$preauth_key" > "$SECRETS_DIR/headscale-admin-preauth-key"
            chmod 600 "$SECRETS_DIR/headscale-admin-preauth-key"
        fi
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

configure_internal_dns() {
    local dnsmasq_file="/etc/dnsmasq.d/homelab-services.conf"

    if ! command -v dnsmasq >/dev/null 2>&1; then
        warn "dnsmasq is not installed; internal clients may hairpin through the public IP."
        return
    fi

    info "Writing split-horizon DNS records for homelab service domains"
    cat > "$dnsmasq_file" <<EOF
# Homelab split-horizon records.
# Internal clients resolve public service names directly to Nginx Proxy Manager.
address=/$PROXY_DOMAIN/$PROXY_IP
address=/$AUTH_DOMAIN/$PROXY_IP
address=/$HEADSCALE_DOMAIN/$PROXY_IP
address=/$HEADPLANE_DOMAIN/$PROXY_IP
EOF

    dnsmasq --test
    systemctl restart dnsmasq
}

write_summary() {
    local preauth_key=""
    [[ -s "$SECRETS_DIR/headscale-admin-preauth-key" ]] && preauth_key="$(cat "$SECRETS_DIR/headscale-admin-preauth-key")"

    cat > "$STATE_DIR/access.txt" <<EOF
Homelab service LXCs
====================

Base domain: $DOMAIN

LXC layout:
- Nginx Proxy Manager: $PROXY_CTID $PROXY_IP ($PROXY_HOSTNAME)
- Authelia auth/OIDC: $AUTH_CTID $AUTH_IP ($AUTH_HOSTNAME)
- Headscale + Headplane: $HEADSCALE_CTID $HEADSCALE_IP ($HEADSCALE_HOSTNAME)

Public DNS records to create:
- $PROXY_DOMAIN -> $(get_ip)
- $AUTH_DOMAIN -> $(get_ip)
- $HEADSCALE_DOMAIN -> $(get_ip)
- $HEADPLANE_DOMAIN -> $(get_ip)

Nginx Proxy Manager:
- Internal admin URL: http://$PROXY_IP:81
- NPM bootstrap login used for seeding: $NPM_ADMIN_EMAIL / $NPM_DEFAULT_PASSWORD
- Change the NPM admin account immediately after first login.
- Add proxy hosts:
  - $AUTH_DOMAIN -> http://$AUTH_IP:9091
  - $HEADSCALE_DOMAIN -> http://$HEADSCALE_IP:8080
  - $HEADPLANE_DOMAIN -> http://$HEADSCALE_IP:3000
- Request Let's Encrypt certificates for those hosts using $LE_EMAIL.

Authelia:
- URL: https://$AUTH_DOMAIN
- Initial user: $AUTH_ADMIN_USER
- Initial password: $(cat "$SECRETS_DIR/authelia-admin-password")

Headscale:
- URL: https://$HEADSCALE_DOMAIN
- Login command: tailscale up --login-server=https://$HEADSCALE_DOMAIN
EOF

    if [[ -n "$preauth_key" ]]; then
        cat >> "$STATE_DIR/access.txt" <<EOF
- Optional reusable 24h pre-auth command:
  tailscale up --login-server=https://$HEADSCALE_DOMAIN --authkey=$preauth_key
EOF
    fi

    cat >> "$STATE_DIR/access.txt" <<EOF

Headplane:
- URL: https://$HEADPLANE_DOMAIN

Secrets are stored under:
- $SECRETS_DIR
EOF

    chmod 600 "$STATE_DIR/access.txt"
    info "Wrote access summary to $STATE_DIR/access.txt"
}

main() {
    local template
    require_proxmox
    template="$(ensure_template)"

    ensure_lxc "$PROXY_CTID" "$PROXY_HOSTNAME" "$PROXY_IP" 768 1 8 "$template"
    ensure_lxc "$AUTH_CTID" "$AUTH_HOSTNAME" "$AUTH_IP" 768 1 6 "$template"
    ensure_lxc "$HEADSCALE_CTID" "$HEADSCALE_HOSTNAME" "$HEADSCALE_IP" 768 1 6 "$template"

    install_proxy_lxc "$PROXY_CTID"
    install_auth_lxc "$AUTH_CTID"
    install_headscale_lxc "$HEADSCALE_CTID"
    seed_npm_proxy_hosts
    configure_host_dnat
    configure_internal_dns
    write_summary
}

main "$@"
