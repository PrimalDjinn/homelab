#!/usr/bin/env bash
# lockdown-proxmox-8006.sh
# Restrict Proxmox web UI (port 8006) to Headscale/Tailscale network only.
# Run this after testing and confirming Headscale access works.
#
# Usage:
#   sudo ./scripts/lockdown-proxmox-8006.sh
#
# This script is idempotent: running it again will refresh the rules.

set -euo pipefail

TAILSCALE_IF="tailscale0"
PROXMOX_PORT="8006"
CHAIN="PROXMOX_8006_LOCKDOWN"

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

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
    error "Tailscale interface '$TAILSCALE_IF' not found. Is Tailscale/Headscale connected?"
fi

info "Tailscale interface detected: $TAILSCALE_IF"

# Get Tailscale subnet (CIDR) from interface
TAILSCALE_SUBNET=$(ip -4 addr show "$TAILSCALE_IF" | awk '/inet / {print $2}')
if [[ -z "$TAILSCALE_SUBNET" ]]; then
    error "Could not detect Tailscale subnet on $TAILSCALE_IF"
fi

info "Tailscale subnet: $TAILSCALE_SUBNET"

# --- nftables implementation ---
setup_nftables() {
    local table="inet filter"
    local chain="input"
    
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
    
    # Allow from Tailscale subnet (in case traffic comes routed)
    nft add rule $table $CHAIN ip saddr "$TAILSCALE_SUBNET" tcp dport $PROXMOX_PORT accept
    
    # Drop everything else to port 8006
    nft add rule $table $CHAIN tcp dport $PROXMOX_PORT drop
    
    info "nftables rules applied for port $PROXMOX_PORT"
}

# --- iptables implementation ---
setup_iptables() {
    # Remove old rules if they exist (by comment marker)
    while iptables -C INPUT -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j DROP 2>/dev/null; do
        iptables -D INPUT -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j DROP
    done
    while iptables -C INPUT -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j ACCEPT
    done
    
    # Insert rules at top of INPUT chain
    # 1. Accept from Tailscale interface
    iptables -I INPUT 1 -i "$TAILSCALE_IF" -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j ACCEPT
    
    # 2. Accept from Tailscale subnet
    iptables -I INPUT 2 -p tcp --dport $PROXMOX_PORT -s "$TAILSCALE_SUBNET" -m comment --comment "$CHAIN" -j ACCEPT
    
    # 3. Drop everything else to 8006
    iptables -I INPUT 3 -p tcp --dport $PROXMOX_PORT -m comment --comment "$CHAIN" -j DROP
    
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
