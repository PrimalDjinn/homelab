#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/.env"
fi

HOSTS_FILE='/etc/hosts'

host_ip() {
    local ip

    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
    if [[ -z "$ip" ]]; then
        ip="$(get_ip)"
    fi

    echo "$ip"
}

ensure_proxmox_hostname_mapping() {
    local ip node legacy_alias tmp

    ip="$(host_ip)"
    node="$(hostname)"
    legacy_alias="$node-server"
    tmp="$(mktemp)"

    cp "$HOSTS_FILE" "$HOSTS_FILE.bak"
    awk -v node="$node" -v legacy_alias="$legacy_alias" '
        {
            out = $1
            fields = 1
            for (i = 2; i <= NF; i++) {
                if ($i != node && $i != legacy_alias) {
                    out = out " " $i
                    fields++
                }
            }
            if (fields > 1 || $1 ~ /^127\.|^::1$|^ff02::/) {
                print out
            }
        }
    ' "$HOSTS_FILE" > "$tmp"
    printf '%s %s %s\n' "$ip" "$node" "$legacy_alias" >> "$tmp"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp"
}

proxmox_hostname_resolves() {
    local node ip

    node="$(hostname)"
    ip="$(getent hosts "$node" | awk '{ print $1; exit }')"
    [[ -n "$ip" && "$ip" != 127.* && "$ip" != "::1" ]]
}

prepare() {
    ensure_proxmox_hostname_mapping
    proxmox_hostname_resolves || error "Hostname $(hostname) does not resolve to a non-loopback IP after updating $HOSTS_FILE"
}

refresh_proxmox_runtime() {
    if ! proxmox_installed; then
        return
    fi

    systemctl restart pve-cluster || warn "Could not restart pve-cluster"
    if [[ -d /etc/pve/nodes ]]; then
        if command -v pvecm >/dev/null 2>&1; then
            pvecm updatecerts --force || warn "Could not refresh Proxmox certificates"
        fi
        systemctl restart pvedaemon pveproxy pvestatd || warn "Could not restart all Proxmox API/UI services"
    else
        warn "/etc/pve/nodes is still unavailable after restarting pve-cluster"
    fi
}

restore_host() {
    if [[ ! -f "$HOSTS_FILE.bak" ]]; then
        warn "No $HOSTS_FILE.bak found; skipping hosts restore"
        return 0
    fi
    cp "$HOSTS_FILE.bak" "$HOSTS_FILE"
}


fix_proxmox_repos() {
    # Disables Proxmox enterprise repos and enables community (no-subscription) repos.
    # Handles both .list and .sources (DEB822) formats.

    set -e
    
    [[ $EUID -ne 0 ]] && error "Run as root or with sudo."

    SOURCES_DIR="/etc/apt/sources.list.d"
    BACKUP_DIR="/root/apt-sources-backup-$(date +%Y%m%d%H%M%S)"

    info "Backing up current sources to $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -v "$SOURCES_DIR"/*.list "$SOURCES_DIR"/*.sources "$BACKUP_DIR/" 2>/dev/null || true

    for f in "$SOURCES_DIR/pve-enterprise.list" "$SOURCES_DIR/ceph.list"; do
        if [[ -f "$f" ]]; then
            sed -i 's|^deb https://enterprise.proxmox.com|# deb https://enterprise.proxmox.com|g' "$f"
            info "Commented out enterprise entries in $f"
        fi
    done

    for f in "$SOURCES_DIR/pve-enterprise.sources" "$SOURCES_DIR/ceph.sources"; do
        if [[ -f "$f" ]]; then
            mv "$f" "${f}.disabled"
            info "Disabled $f -> ${f}.disabled"
        fi
    done

    if [[ ! -f "$SOURCES_DIR/pve-no-subscription.list" ]]; then
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
            > "$SOURCES_DIR/pve-no-subscription.list"
        info "Created pve-no-subscription.list"
    else
        info "pve-no-subscription.list already exists, skipping."
    fi

    if [[ ! -f "$SOURCES_DIR/ceph-no-subscription.list" ]]; then
        echo "deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription" \
            > "$SOURCES_DIR/ceph-no-subscription.list"
        info "Created ceph-no-subscription.list"
    else
        info "ceph-no-subscription.list already exists, skipping."
    fi

    info "Checking for any remaining active enterprise entries..."
    REMAINING=$(grep -r "^deb https://enterprise.proxmox.com" /etc/apt/ 2>/dev/null || true)
    if [[ -n "$REMAINING" ]]; then
        warn "Still found active enterprise entries:\n$REMAINING"
    else
        info "All enterprise entries are disabled."
    fi

    info "Running apt update..."
    apt update

    info "Done. Backup saved to $BACKUP_DIR"
}

STATE_DIR="/var/lib/homelab"
PENDING_FILE="$STATE_DIR/setup-proxmox.pending"
DONE_FILE="$STATE_DIR/setup-proxmox.done"

proxmox_installed() {
    command -v pveversion >/dev/null 2>&1 || dpkg -s proxmox-ve >/dev/null 2>&1
}

install() {
    # Add the Proxmox VE repository:
    echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
    wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
    # verify
    echo "7da6fe34168adc6e479327ba517796d4702fa2f8b4f0a9833f5ea6e6b48f6507a6da403a274fe201595edc86a84463d50383d07f64bdde2e3658108db7d6dc87  /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg" | sha512sum -c -
    apt update && apt -y full-upgrade
    apt install -y proxmox-default-kernel

    mkdir -p "$STATE_DIR"
    touch "$PENDING_FILE"

    info "Rebooting, rerun the script to complete installation"
    sleep 10
    systemctl reboot
}

complete_install() {
    prepare
    DEBIAN_FRONTEND=noninteractive apt install -y proxmox-ve postfix open-iscsi chrony
    apt remove -y linux-image-amd64 'linux-image-6.1*'
    update-grub
    apt remove -y os-prober
    free_mail_ports
    rm -f /etc/apt/sources.list.d/pve-install-repo.list
    fix_proxmox_repos
    refresh_proxmox_runtime
    rm -f "$PENDING_FILE"
    touch "$DONE_FILE"
}


if [[ "${1:-}" == "--reset" ]]; then
    require_root
    restore_host
    rm -f "$PENDING_FILE" "$DONE_FILE"
elif [[ -f "$PENDING_FILE" ]]; then
    require_root
    complete_install
elif proxmox_installed; then
    require_root
    prepare
    info "Proxmox is already installed; skipping Debian-to-Proxmox install."
    refresh_proxmox_runtime
    mkdir -p "$STATE_DIR"
    touch "$DONE_FILE"
elif [[ -f "$DONE_FILE" ]]; then
    info "Proxmox setup is already marked complete."
else
    require_root
    prepare
    install
fi
