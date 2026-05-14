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
MAIL_CTID="${MAIL_CTID:-113}"
PROXY_IP="${PROXY_IP:-$NETWORK_PREFIX.10}"
AUTH_IP="${AUTH_IP:-$NETWORK_PREFIX.20}"
HEADSCALE_IP="${HEADSCALE_IP:-$NETWORK_PREFIX.30}"
MAIL_IP="${MAIL_IP:-$NETWORK_PREFIX.40}"
PROXY_HOSTNAME="${PROXY_HOSTNAME:-homelab-proxy}"
AUTH_HOSTNAME="${AUTH_HOSTNAME:-homelab-auth}"
HEADSCALE_HOSTNAME="${HEADSCALE_HOSTNAME:-homelab-headscale}"
MAIL_HOSTNAME="${MAIL_HOSTNAME:-homelab-mail}"
PROXY_DOMAIN="${PROXY_DOMAIN:-proxy.$DOMAIN}"
AUTH_DOMAIN="${AUTH_DOMAIN:-auth.$DOMAIN}"
HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN:-headscale.$DOMAIN}"
HEADPLANE_DOMAIN="${HEADPLANE_DOMAIN:-headplane.$DOMAIN}"
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
AUTH_ADMIN_USER="${AUTH_ADMIN_USER:-admin}"
NPM_BOOTSTRAP_EMAIL="${NPM_BOOTSTRAP_EMAIL:-admin@example.com}"
NPM_BOOTSTRAP_PASSWORD="${NPM_BOOTSTRAP_PASSWORD:-changeme}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-$LE_EMAIL}"
NPM_PASSWORD="${NPM_PASSWORD:-${NPM_DEFAULT_PASSWORD:-}}"
NPM_DNS_CHALLENGE_PROVIDER="${NPM_DNS_CHALLENGE_PROVIDER:-cloudflare}"
NPM_DNS_PROPAGATION_SECONDS="${NPM_DNS_PROPAGATION_SECONDS:-60}"
NPM_SKIP_CLOUDFLARE_DNS_TOKEN="${NPM_SKIP_CLOUDFLARE_DNS_TOKEN:-false}"
CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-}"
STALWART_ACME_ENABLED="${STALWART_ACME_ENABLED:-true}"
STALWART_ACME_DNS_PROVIDER="${STALWART_ACME_DNS_PROVIDER:-cloudflare}"
STALWART_ACME_DNS_CF_SECRET="${STALWART_ACME_DNS_CF_SECRET:-}"
EMAIL_SERVICE_REPO="${EMAIL_SERVICE_REPO:-https://github.com/ChibaLLC/email-service}"
EMAIL_SERVICE_REF="${EMAIL_SERVICE_REF:-main}"
MAIL_PORTS="${MAIL_PORTS:-25 110 143 465 587 993 995 4190}"
HEADSCALE_PREAUTH_KEY_EXPIRATION="${HEADSCALE_PREAUTH_KEY_EXPIRATION:-720h}"
HEADSCALE_PUBLIC_URL="https://$HEADSCALE_DOMAIN"
HEADSCALE_INTERNAL_URL="http://$HEADSCALE_IP:8080"
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
    need_cmd pveam
    need_cmd pvesm
    need_cmd openssl
    ensure_host_python
    ensure_host_jq
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
    template="$(pveam available --section system | awk '/debian-12-standard/ { print $2 }' | sort -V | tail -n1)"
    [[ -n "$template" ]] || error "Could not find a Debian 12 LXC template."

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
    pct_exec "$ctid" "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ca-certificates curl file gnupg jq openssl sqlite3 tar"
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

export_mail_env() {
    export DOMAIN MAIL_DOMAIN EMAIL_APP_DOMAIN WEBMAIL_DOMAIN LISTMONK_DOMAIN POSTAL_DOMAIN
    export LIBREDESK_DOMAIN AUTODISCOVER_DOMAIN AUTOCONFIG_DOMAIN MTA_STS_DOMAIN LE_EMAIL
    export CLOUDFLARE_DNS_API_TOKEN STALWART_ACME_ENABLED STALWART_ACME_DNS_PROVIDER STALWART_ACME_DNS_CF_SECRET

    export EMAIL_POSTGRES_USER="${EMAIL_POSTGRES_USER:-email_service}"
    export EMAIL_POSTGRES_PASSWORD="${EMAIL_POSTGRES_PASSWORD:-$(secret_file "$SECRETS_DIR/email-postgres-password" 32)}"
    export EMAIL_POSTGRES_DB="${EMAIL_POSTGRES_DB:-email_service}"
    export EMAIL_JWT_SECRET="${EMAIL_JWT_SECRET:-$(secret_file "$SECRETS_DIR/email-jwt-secret" 64)}"
    export POSTAL_SERVER_API_KEY="${POSTAL_SERVER_API_KEY:-$(secret_file "$SECRETS_DIR/postal-server-api-key" 48)}"
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
    export LIBREDESK_SYSTEM_USER_PASSWORD="${LIBREDESK_SYSTEM_USER_PASSWORD:-$(secret_file "$SECRETS_DIR/libredesk-system-user-password" 32)}"
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
    pct_exec "$ctid" "chmod 600 /opt/email-service/.env"

    info "Starting email-service production stack in LXC $ctid"
    pct_exec "$ctid" "cd /opt/email-service && docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d"
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

harden_npm_admin() {
    local token
    local verified_token
    local ctid="$PROXY_CTID"

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

    token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_BOOTSTRAP_EMAIL") --arg secret $(quote "$NPM_BOOTSTRAP_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -z "$token" ]]; then
        warn "Could not log in to Nginx Proxy Manager with desired or bootstrap credentials; change the admin credentials manually."
        return
    fi

    pct_exec "$ctid" "curl -fsS -X PUT http://127.0.0.1:81/api/users/1/auth -H 'Authorization: Bearer $(quote "$token")' -H 'Content-Type: application/json' --data \"\$(jq -nc --arg current $(quote "$NPM_BOOTSTRAP_PASSWORD") --arg secret $(quote "$NPM_PASSWORD") '{type:\"password\",current:\$current,secret:\$secret}')\" >/dev/null" || {
        warn "Could not update the Nginx Proxy Manager admin password automatically."
    }

    verified_token="$(pct_exec "$ctid" "curl -fsS -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' --data \"\$(jq -nc --arg identity $(quote "$NPM_BOOTSTRAP_EMAIL") --arg secret $(quote "$NPM_PASSWORD") '{identity:\$identity,secret:\$secret}')\" | jq -r '.token // empty'" 2>/dev/null || true)"
    if [[ -n "$verified_token" ]]; then
        token="$verified_token"
        NPM_LOGIN_EMAIL="$NPM_BOOTSTRAP_EMAIL"
        NPM_LOGIN_PASSWORD="$NPM_PASSWORD"
    else
        NPM_LOGIN_EMAIL="$NPM_BOOTSTRAP_EMAIL"
        NPM_LOGIN_PASSWORD="$NPM_BOOTSTRAP_PASSWORD"
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

    export AUTH_DOMAIN AUTH_IP HEADSCALE_DOMAIN HEADSCALE_IP HEADPLANE_DOMAIN
    export MAIL_DOMAIN MAIL_IP AUTODISCOVER_DOMAIN AUTOCONFIG_DOMAIN MTA_STS_DOMAIN
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

configure_npm_lets_encrypt() {
    local ctid="$PROXY_CTID"

    info "Trying to request and attach Nginx Proxy Manager Let's Encrypt certificate"
    pct_exec "$ctid" "for i in \$(seq 1 60); do curl -fsS http://127.0.0.1:81/api >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || {
        warn "Nginx Proxy Manager API was not ready; request the Let's Encrypt certificate manually in the UI."
        return
    }

    pct push "$ctid" "$SERVICES_DIR/proxy/configure-npm-ssl.sh" /tmp/configure-npm-ssl.sh
    pct_exec "$ctid" "chmod +x /tmp/configure-npm-ssl.sh && NPM_URL=http://127.0.0.1:81 NPM_EMAIL=$(quote "$NPM_LOGIN_EMAIL") NPM_PASSWORD=$(quote "$NPM_LOGIN_PASSWORD") LE_EMAIL=$(quote "$LE_EMAIL") AUTH_DOMAIN=$(quote "$AUTH_DOMAIN") HEADSCALE_DOMAIN=$(quote "$HEADSCALE_DOMAIN") HEADPLANE_DOMAIN=$(quote "$HEADPLANE_DOMAIN") MAIL_DOMAIN=$(quote "$MAIL_DOMAIN") AUTODISCOVER_DOMAIN=$(quote "$AUTODISCOVER_DOMAIN") AUTOCONFIG_DOMAIN=$(quote "$AUTOCONFIG_DOMAIN") MTA_STS_DOMAIN=$(quote "$MTA_STS_DOMAIN") NPM_DNS_CHALLENGE_PROVIDER=$(quote "$NPM_DNS_CHALLENGE_PROVIDER") NPM_DNS_PROPAGATION_SECONDS=$(quote "$NPM_DNS_PROPAGATION_SECONDS") NPM_SKIP_CLOUDFLARE_DNS_TOKEN=$(quote "$NPM_SKIP_CLOUDFLARE_DNS_TOKEN") CLOUDFLARE_DNS_API_TOKEN=$(quote "$CLOUDFLARE_DNS_API_TOKEN") /tmp/configure-npm-ssl.sh" || {
        warn "Could not automate NPM Let's Encrypt setup. Set CLOUDFLARE_DNS_API_TOKEN for Cloudflare DNS-01, or set NPM_SKIP_CLOUDFLARE_DNS_TOKEN=true to force HTTP-01 with DNS-only records and public port 80."
        return
    }
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

    headscale_preauth_key "$HEADSCALE_CTID" "$key_file" "$HEADSCALE_PREAUTH_KEY_EXPIRATION"
    key="$(cat "$key_file")"
    ensure_proxy_tun "$PROXY_CTID"

    info "Installing Tailscale client in proxy LXC $PROXY_CTID"
    pct_exec "$PROXY_CTID" "if ! command -v tailscale >/dev/null 2>&1; then curl -fsSL https://tailscale.com/install.sh | sh; fi"
    pct_exec "$PROXY_CTID" "systemctl enable --now tailscaled"
    pct_exec "$PROXY_CTID" "tailscale up --login-server=$(quote "$HEADSCALE_INTERNAL_URL") --authkey=$(quote "$key") --hostname=$(quote "$PROXY_HOSTNAME") --accept-dns=false"
}

render_headscale_stack() {
    local api_key="${1:-}"

    export DOMAIN AUTH_DOMAIN HEADSCALE_DOMAIN HEADPLANE_DOMAIN
    export HEADSCALE_VERSION="${HEADSCALE_VERSION:-0.28.0}"
    export HEADPLANE_VERSION="${HEADPLANE_VERSION:-latest}"
    export HEADSCALE_URL="http://headscale:8080"
    export HEADSCALE_PUBLIC_URL
    export HEADPLANE_SERVER__BASE_URL="https://$HEADPLANE_DOMAIN"
    export SERVER_URL="$HEADSCALE_PUBLIC_URL"
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

    headscale_preauth_key "$ctid" "$SECRETS_DIR/headscale-admin-preauth-key" "$HEADSCALE_PREAUTH_KEY_EXPIRATION"
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
address=/$MAIL_DOMAIN/$MAIL_IP
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
- Authelia auth/OIDC: $AUTH_CTID $AUTH_IP ($AUTH_HOSTNAME)
- Headscale + Headplane: $HEADSCALE_CTID $HEADSCALE_IP ($HEADSCALE_HOSTNAME)
- Mail/email-service: $MAIL_CTID $MAIL_IP ($MAIL_HOSTNAME)

Public DNS records to create:
- $AUTH_DOMAIN -> $public_ip
- $HEADSCALE_DOMAIN -> $public_ip
- $HEADPLANE_DOMAIN -> $public_ip
- $MAIL_DOMAIN -> $public_ip
- $AUTODISCOVER_DOMAIN -> $public_ip
- $AUTOCONFIG_DOMAIN -> $public_ip
- $MTA_STS_DOMAIN -> $public_ip
- MX for $DOMAIN -> $MAIL_DOMAIN

Nginx Proxy Manager:
- Internal admin URL: http://$PROXY_IP:81
- Admin login verified by automation: $NPM_LOGIN_EMAIL / $NPM_LOGIN_PASSWORD
- Add proxy hosts:
  - $AUTH_DOMAIN -> http://$AUTH_IP:9091
  - $HEADSCALE_DOMAIN -> http://$HEADSCALE_IP:8080
  - $HEADPLANE_DOMAIN -> http://$HEADSCALE_IP:3000
  - $MAIL_DOMAIN, $AUTODISCOVER_DOMAIN, $AUTOCONFIG_DOMAIN, $MTA_STS_DOMAIN -> http://$MAIL_IP:8080
- Request Let's Encrypt certificates for those hosts using $LE_EMAIL.

Authelia:
- URL: https://$AUTH_DOMAIN
- Initial user: $AUTH_ADMIN_USER
- Initial password: $(cat "$SECRETS_DIR/authelia-admin-password")

Headscale:
- URL: $HEADSCALE_PUBLIC_URL
- Login command: tailscale up --login-server=$HEADSCALE_PUBLIC_URL
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

Mail/email-service:
- Repo: $EMAIL_SERVICE_REPO
- Ref: $EMAIL_SERVICE_REF
- Path in LXC: /opt/email-service
- Started with: docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d
- Stalwart HTTP is routed through Nginx Proxy Manager to http://$MAIL_IP:8080
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
    require_proxmox
    template="$(ensure_template)"
    validate_template_ref "$template"

    ensure_lxc "$PROXY_CTID" "$PROXY_HOSTNAME" "$PROXY_IP" 768 1 8 "$template"
    ensure_lxc "$AUTH_CTID" "$AUTH_HOSTNAME" "$AUTH_IP" 768 1 6 "$template"
    ensure_lxc "$HEADSCALE_CTID" "$HEADSCALE_HOSTNAME" "$HEADSCALE_IP" 768 1 6 "$template"
    ensure_lxc "$MAIL_CTID" "$MAIL_HOSTNAME" "$MAIL_IP" 4096 2 40 "$template"

    install_proxy_lxc "$PROXY_CTID"
    harden_npm_admin
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
