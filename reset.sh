#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

require_root

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/.env"
fi

NETWORK_PREFIX="${HOMELAB_NETWORK_PREFIX:-10.10.10}"
NETWORK_CIDR="${HOMELAB_NETWORK_CIDR:-$NETWORK_PREFIX.0/24}"
PROXY_CTID="${PROXY_CTID:-110}"
AUTH_CTID="${AUTH_CTID:-111}"
HEADSCALE_CTID="${HEADSCALE_CTID:-112}"
MAIL_CTID="${MAIL_CTID:-113}"
PROXY_IP="${PROXY_IP:-$NETWORK_PREFIX.10}"
MAIL_IP="${MAIL_IP:-$NETWORK_PREFIX.40}"
MAIL_PORTS="${MAIL_PORTS:-25 110 143 465 587 993 995 4190}"
VM_BRIDGE="${HOMELAB_BRIDGE:-vmbr10}"
STATE_DIR="${STATE_DIR:-/root/homelab}"
PROXMOX_STATE_DIR="/var/lib/homelab"
HOSTS_FILE="/etc/hosts"

ASSUME_YES=false
RESET_PROXMOX=false
RESET_NETWORK=false

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            ASSUME_YES=true
            ;;
        --proxmox)
            RESET_PROXMOX=true
            ;;
        --network)
            RESET_NETWORK=true
            ;;
        -h|--help)
            cat <<EOF
Usage:
  sudo ./reset.sh [--yes] [--network] [--proxmox]

Default reset removes homelab service LXCs, generated state, secrets, and
public proxy/mail DNAT rules to the managed LXCs.

Reset does not repair an incomplete or unhealthy Proxmox installation. If
/etc/pve/nodes is missing, recover pve-cluster first; see README.

Options:
  --network   Also remove vmbr10 from /etc/network/interfaces and internal NAT rules.
  --proxmox   Also clear Proxmox setup markers and restore /etc/hosts backup if present.
  --yes       Do not prompt for confirmation.
EOF
            exit 0
            ;;
        *)
            error "Unknown option: $arg"
            ;;
    esac
done

confirm() {
    if [[ "$ASSUME_YES" == true ]]; then
        return
    fi

    cat <<EOF
This will remove homelab-managed test resources:

- LXCs: $PROXY_CTID, $AUTH_CTID, $HEADSCALE_CTID, $MAIL_CTID
- State/secrets: $STATE_DIR
- DNAT/FORWARD rules forwarding public 80/443 to $PROXY_IP
- DNAT/FORWARD rules forwarding public mail ports to $MAIL_IP

Optional:
- Reset network bridge/rules: $RESET_NETWORK
- Reset Proxmox markers/hosts backup: $RESET_PROXMOX

EOF
    read -r -p "Continue? Type 'reset' to proceed: " answer
    [[ "$answer" == "reset" ]] || error "Reset cancelled."
}

remove_lxc() {
    local ctid="$1"

    if ! command -v pct >/dev/null 2>&1; then
        warn "pct not found; skipping LXC $ctid"
        return
    fi

    if pct status "$ctid" >/dev/null 2>&1; then
        info "Stopping and destroying LXC $ctid"
        pct stop "$ctid" >/dev/null 2>&1 || true
        pct destroy "$ctid" --purge 1
    else
        info "LXC $ctid does not exist; skipping"
    fi
}

delete_iptables_rule() {
    local table="$1"
    shift

    while iptables -t "$table" -C "$@" 2>/dev/null; do
        iptables -t "$table" -D "$@"
    done
}

cleanup_public_proxy_rules() {
    local main_interface

    if ! command -v iptables >/dev/null 2>&1; then
        warn "iptables not found; skipping firewall reset"
        return
    fi

    main_interface="$(ip route | awk '/default/ { print $5; exit }')"

    info "Removing public proxy DNAT/FORWARD rules for $PROXY_IP"
    if [[ -n "$main_interface" ]]; then
        delete_iptables_rule nat PREROUTING -i "$main_interface" -p tcp --dport 80 -j DNAT --to-destination "$PROXY_IP:80"
        delete_iptables_rule nat PREROUTING -i "$main_interface" -p tcp --dport 443 -j DNAT --to-destination "$PROXY_IP:443"
    fi

    # Also remove legacy rules from earlier test versions that did not include -i.
    delete_iptables_rule nat PREROUTING -p tcp --dport 80 -j DNAT --to-destination "$PROXY_IP:80"
    delete_iptables_rule nat PREROUTING -p tcp --dport 443 -j DNAT --to-destination "$PROXY_IP:443"
    delete_iptables_rule filter FORWARD -p tcp -d "$PROXY_IP" --dport 80 -j ACCEPT
    delete_iptables_rule filter FORWARD -p tcp -d "$PROXY_IP" --dport 443 -j ACCEPT
}

cleanup_public_mail_rules() {
    local main_interface port

    if ! command -v iptables >/dev/null 2>&1; then
        warn "iptables not found; skipping mail firewall reset"
        return
    fi

    main_interface="$(ip route | awk '/default/ { print $5; exit }')"

    info "Removing public mail DNAT/FORWARD rules for $MAIL_IP"
    for port in $MAIL_PORTS; do
        if [[ -n "$main_interface" ]]; then
            delete_iptables_rule nat PREROUTING -i "$main_interface" -p tcp --dport "$port" -j DNAT --to-destination "$MAIL_IP:$port"
        fi
        delete_iptables_rule nat PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "$MAIL_IP:$port"
        delete_iptables_rule filter FORWARD -p tcp -d "$MAIL_IP" --dport "$port" -j ACCEPT
    done
}

cleanup_network_rules() {
    local main_interface

    if ! command -v iptables >/dev/null 2>&1; then
        warn "iptables not found; skipping internal network firewall reset"
        return
    fi

    main_interface="$(ip route | awk '/default/ { print $5; exit }')"
    if [[ -z "$main_interface" ]]; then
        warn "Could not detect default interface; skipping internal network firewall reset"
        return
    fi

    info "Removing internal NAT/FORWARD rules for $NETWORK_CIDR"
    delete_iptables_rule nat POSTROUTING -s "$NETWORK_CIDR" -o "$main_interface" -j MASQUERADE
    delete_iptables_rule filter FORWARD -i "$VM_BRIDGE" -o "$main_interface" -j ACCEPT
}

cleanup_bridge() {
    if [[ -f /etc/network/interfaces ]] && grep -qE "^iface[[:space:]]+$VM_BRIDGE[[:space:]]+" /etc/network/interfaces; then
        info "Removing $VM_BRIDGE from /etc/network/interfaces"
        cp /etc/network/interfaces "/etc/network/interfaces.reset.bak.$(date +%F-%H-%M)"
        awk -v bridge="$VM_BRIDGE" '
            $0 == "# === Internal Network ===" { skip = 1; next }
            skip && $1 == "auto" && $2 == bridge { next }
            skip && $1 == "iface" && $2 == bridge { next }
            skip && /^    / { next }
            skip { skip = 0 }
            { print }
        ' /etc/network/interfaces > /tmp/homelab-interfaces
        cp /tmp/homelab-interfaces /etc/network/interfaces
        rm -f /tmp/homelab-interfaces
    else
        info "$VM_BRIDGE is not configured in /etc/network/interfaces; skipping config cleanup"
    fi

    if command -v ifdown >/dev/null 2>&1; then
        ifdown "$VM_BRIDGE" >/dev/null 2>&1 || true
    fi

    if command -v ip >/dev/null 2>&1 && ip link show "$VM_BRIDGE" >/dev/null 2>&1; then
        info "Deleting runtime bridge $VM_BRIDGE"
        ip link set "$VM_BRIDGE" down >/dev/null 2>&1 || true
        ip link delete "$VM_BRIDGE" type bridge >/dev/null 2>&1 || true
    fi
}

cleanup_service_dns() {
    if [[ -f /etc/dnsmasq.d/homelab-services.conf ]]; then
        info "Removing dnsmasq homelab service DNS records"
        rm -f /etc/dnsmasq.d/homelab-services.conf
        systemctl restart dnsmasq >/dev/null 2>&1 || true
    fi
}

cleanup_network_dns() {
    if [[ -f /etc/dnsmasq.d/proxmox-networks.conf ]]; then
        info "Removing dnsmasq homelab network config"
        rm -f /etc/dnsmasq.d/proxmox-networks.conf
        systemctl restart dnsmasq >/dev/null 2>&1 || true
    fi
}

persist_firewall() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
}

cleanup_state() {
    if [[ -z "$STATE_DIR" || "$STATE_DIR" == "/" || "$STATE_DIR" == "/root" || "$STATE_DIR" == "/var" || "$STATE_DIR" == "/var/lib" ]]; then
        error "Refusing to remove unsafe STATE_DIR: $STATE_DIR"
    fi

    info "Removing generated homelab state at $STATE_DIR"
    rm -rf "$STATE_DIR"
}

cleanup_proxmox_markers() {
    info "Removing Proxmox setup markers from $PROXMOX_STATE_DIR"
    rm -f "$PROXMOX_STATE_DIR/setup-proxmox.pending" "$PROXMOX_STATE_DIR/setup-proxmox.done"

    if [[ -f "$HOSTS_FILE.bak" ]]; then
        info "Restoring $HOSTS_FILE from $HOSTS_FILE.bak"
        cp "$HOSTS_FILE.bak" "$HOSTS_FILE"
    else
        warn "No $HOSTS_FILE.bak found; skipping hosts restore"
    fi
}

cleanup_pve_firewall_rules() {
    local firewall_files=()
    local firewall_file
    local tmp

    if [[ ! -d /etc/pve/nodes ]]; then
        warn "/etc/pve/nodes is not available; skipping Proxmox firewall cleanup"
        return
    fi

    shopt -s nullglob
    firewall_files=(/etc/pve/nodes/*/host.fw)
    shopt -u nullglob
    if ((${#firewall_files[@]} == 0)); then
        return
    fi

    for firewall_file in "${firewall_files[@]}"; do
        info "Removing homelab Proxmox host firewall rules from $firewall_file"
        tmp="$(mktemp)"
        awk '
            $0 == "# BEGIN HOMELAB RULES" { skip = 1; next }
            $0 == "# END HOMELAB RULES" { skip = 0; next }
            /# HOMELAB/ { next }
            !skip { print }
        ' "$firewall_file" > "$tmp"
        cp "$tmp" "$firewall_file"
        rm -f "$tmp"
    done

    if [[ "${HOMELAB_ENABLE_PVE_FIREWALL:-true}" == "true" ]] && command -v pve-firewall >/dev/null 2>&1; then
        info "Stopping Proxmox firewall because HOMELAB_ENABLE_PVE_FIREWALL=true for this reset"
        pve-firewall stop >/dev/null 2>&1 || true
        systemctl disable --now pve-firewall >/dev/null 2>&1 || true
    fi
}

confirm
remove_lxc "$PROXY_CTID"
remove_lxc "$AUTH_CTID"
remove_lxc "$HEADSCALE_CTID"
remove_lxc "$MAIL_CTID"
cleanup_public_proxy_rules
cleanup_public_mail_rules
cleanup_pve_firewall_rules
cleanup_service_dns

if [[ "$RESET_NETWORK" == true ]]; then
    cleanup_network_rules
    cleanup_bridge
    cleanup_network_dns
fi

persist_firewall
cleanup_state

if [[ "$RESET_PROXMOX" == true ]]; then
    cleanup_proxmox_markers
fi

bash "$SCRIPT_DIR/setup-proxmox.sh" --reset || warn "An error occurred when trying to reset proxmox"

info "Reset complete."
