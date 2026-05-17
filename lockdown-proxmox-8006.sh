#!/usr/bin/env bash
# lockdown-proxmox-8006.sh
# Restrict Proxmox web UI (port 8006) to Headscale/Tailscale network only.
# Run this after testing and confirming Headscale access works.
#
# Usage:
#   sudo ./lockdown-proxmox-8006.sh
#
# This script is idempotent: running it again will refresh the rules.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

require_root

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/.env"
fi

TAILSCALE_IF="${TAILSCALE_IF:-tailscale0}"
TAILNET_CIDR="${TAILNET_CIDR:-}"
PROXMOX_PORT="${PROXMOX_PORT:-8006}"
CHAIN="PROXMOX_8006_LOCKDOWN"

# Detect firewall backend
if command -v nft >/dev/null 2>&1; then
    BACKEND="nftables"
elif command -v iptables >/dev/null 2>&1; then
    BACKEND="iptables"
else
    error "Neither nftables nor iptables found. Install one to proceed."
fi

info "Using firewall backend: $BACKEND"

# Verify tailscale interface exists
if ! ip link show "$TAILSCALE_IF" >/dev/null 2>&1; then
    error "Tailscale interface '$TAILSCALE_IF' not found. Run setup-proxmox-tailnet.sh and confirm tailnet access before locking down 8006."
fi

info "Tailscale interface detected: $TAILSCALE_IF"

# Get Tailscale address from interface for operator visibility.
TAILSCALE_ADDR=$(ip -4 addr show "$TAILSCALE_IF" | awk '/inet / {print $2; exit}')
if [[ -z "$TAILSCALE_ADDR" ]]; then
    error "Could not detect a Tailscale IPv4 address on $TAILSCALE_IF"
fi

info "Tailscale address: $TAILSCALE_ADDR"
if [[ -n "$TAILNET_CIDR" ]]; then
    info "Additional allowed tailnet CIDR: $TAILNET_CIDR"
fi

# --- nftables implementation ---
setup_nftables() {
    local table="inet filter"

    if ! nft list table inet filter >/dev/null 2>&1; then
        nft add table inet filter
        info "Created nftables table: inet filter"
    fi
    
    # Create chain if it doesn't exist
    if ! nft list chain $table $CHAIN >/dev/null 2>&1; then
        nft add chain $table $CHAIN { type filter hook input priority 0 \; policy accept \; }
        info "Created nftables chain: $CHAIN"
    else
        # Flush existing rules in our chain
        nft flush chain $table $CHAIN
        info "Flushed existing rules in nftables chain: $CHAIN"
    fi
    
    # Allow from Tailscale interface
    nft add rule $table $CHAIN iifname "$TAILSCALE_IF" tcp dport $PROXMOX_PORT accept

    if [[ -n "$TAILNET_CIDR" ]]; then
        nft add rule $table $CHAIN ip saddr "$TAILNET_CIDR" tcp dport $PROXMOX_PORT accept
    fi
    
    # Drop everything else to port 8006
    nft add rule $table $CHAIN tcp dport $PROXMOX_PORT drop
    
    info "nftables rules applied for port $PROXMOX_PORT"
}

# --- iptables implementation ---
setup_iptables() {
    local line

    # Remove old managed rules by comment marker, regardless of interface/source match.
    while line=$(iptables -L INPUT --line-numbers -n | awk -v marker="$CHAIN" '$0 ~ marker {print $1; exit}') && [[ -n "$line" ]]; do
        iptables -D INPUT "$line"
    done
    
    # Insert rules at top of INPUT chain
    # 1. Accept from Tailscale interface
    iptables -I INPUT 1 -i "$TAILSCALE_IF" -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j ACCEPT
    
    # 2. Accept from an optional tailnet CIDR for routed traffic.
    if [[ -n "$TAILNET_CIDR" ]]; then
        iptables -I INPUT 2 -p tcp --dport $PROXMOX_PORT -s "$TAILNET_CIDR" -m comment --comment "$CHAIN" -j ACCEPT
        iptables -I INPUT 3 -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j DROP
    else
        iptables -I INPUT 2 -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j DROP
    fi
    
    info "iptables rules applied for port $PROXMOX_PORT"
}

# --- persistence ---
persist_rules() {
    info "Ensuring rules persist after reboot..."
    
    if [[ "$BACKEND" == "nftables" ]]; then
        # Try common nftables persistence methods
        if command -v nft-save >/dev/null 2>&1; then
            nft-save > /etc/nftables.conf 2>/dev/null || true
        fi
        
        # Debian/Ubuntu systemd service
        if systemctl is-active nftables >/dev/null 2>&1; then
            nft list ruleset > /etc/nftables.conf
            systemctl enable nftables
            info "Saved nftables ruleset to /etc/nftables.conf"
        fi
    else
        # iptables persistence via iptables-persistent or netfilter-persistent
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
            info "Saved iptables rules via netfilter-persistent"
        elif command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
            warn "Could not persist iptables rules automatically. Install iptables-persistent."
        fi
    fi
}

# --- main ---
case "$BACKEND" in
    nftables) setup_nftables ;;
    iptables) setup_iptables ;;
esac

persist_rules

info "Lockdown complete. Proxmox port $PROXMOX_PORT is now restricted to Headscale/Tailscale network only."
info "Test access via Tailscale before disconnecting your current session."

# Show current rules
info "Current firewall rules for port $PROXMOX_PORT:"
if [[ "$BACKEND" == "nftables" ]]; then
    nft list chain inet filter $CHAIN 2>/dev/null || true
else
    iptables -L INPUT -n --line-numbers | grep -E "($PROXMOX_PORT|$CHAIN)" || true
fi
