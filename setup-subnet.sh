#!/usr/bin/env bash
# Run as root on the Proxmox host

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/.env"
fi

VM_BRIDGE="${HOMELAB_BRIDGE:-vmbr10}"
NETWORK_PREFIX="${HOMELAB_NETWORK_PREFIX:-10.10.10}"
GATEWAY_IP="${HOMELAB_GATEWAY_IP:-$NETWORK_PREFIX.1}"
DHCP_START="${HOMELAB_DHCP_START:-$NETWORK_PREFIX.100}"
DHCP_END="${HOMELAB_DHCP_END:-$NETWORK_PREFIX.200}"
NETWORK_CIDR="${HOMELAB_NETWORK_CIDR:-$NETWORK_PREFIX.0/24}"
ENABLE_PVE_FIREWALL="${HOMELAB_ENABLE_PVE_FIREWALL:-false}"
WIREGUARD_PORT="${WIREGUARD_PORT:-51820}"
TAILSCALE_WIREGUARD_PORT="${TAILSCALE_WIREGUARD_PORT:-41641}"

configure_pve_firewall() {
    local node
    local firewall_file
    local cluster_firewall_file
    local rules_file

    if ! command -v pvenode >/dev/null 2>&1 || ! command -v pve-firewall >/dev/null 2>&1; then
        echo "[!] Proxmox firewall commands not found; skipping Proxmox host firewall rule configuration"
        return
    fi

    node="$(pvenode status | awk -F': ' '/^Node/ { print $2; exit }')"
    if [[ -z "$node" ]]; then
        node="$(hostname)"
    fi

    firewall_file="/etc/pve/nodes/$node/host.fw"
    if [[ ! -d "$(dirname "$firewall_file")" ]]; then
        echo "[!] Proxmox firewall path $(dirname "$firewall_file") not found; skipping host firewall rules"
        return
    fi

    cluster_firewall_file="/etc/pve/firewall/cluster.fw"
    mkdir -p "$(dirname "$cluster_firewall_file")"

    ensure_pve_firewall_option "$cluster_firewall_file"
    ensure_pve_firewall_option "$firewall_file"

    echo "[+] Ensuring Proxmox host firewall rules in $firewall_file"
    rules_file="$(mktemp)"
    cat > "$rules_file" <<EOF
IN ACCEPT -p tcp -dport 22 -log nolog # HOMELAB SSH
IN ACCEPT -p tcp -dport 8006 -log nolog # HOMELAB Proxmox Web UI
IN ACCEPT -p tcp -dport 80 -log nolog # HOMELAB HTTP reverse proxy
IN ACCEPT -p tcp -dport 443 -log nolog # HOMELAB HTTPS reverse proxy
IN ACCEPT -p tcp -dport 5900:5999 -log nolog # HOMELAB Proxmox VNC
IN ACCEPT -p tcp -dport 3128 -log nolog # HOMELAB Proxmox SPICE proxy
IN ACCEPT -p udp -dport $WIREGUARD_PORT -log nolog # HOMELAB WireGuard
IN ACCEPT -p udp -dport $TAILSCALE_WIREGUARD_PORT -log nolog # HOMELAB Tailscale/Headscale WireGuard direct
IN ACCEPT -p tcp -dport 53 -log nolog # HOMELAB internal DNS
IN ACCEPT -p udp -dport 53 -log nolog # HOMELAB internal DNS
IN ACCEPT -p udp -dport 67 -log nolog # HOMELAB internal DHCP
EOF

    install_pve_firewall_rules "$firewall_file" "$rules_file"
    rm -f "$rules_file"
}

ensure_pve_firewall_option() {
    local firewall_file="$1"
    local tmp

    touch "$firewall_file"
    tmp="$(mktemp)"
    awk '
        BEGIN {
            in_options = 0
            saw_options = 0
            saw_enable = 0
        }
        /^\[OPTIONS\]$/ {
            in_options = 1
            saw_options = 1
            print
            next
        }
        /^\[/ {
            if (in_options && !saw_enable) {
                print "enable: 1"
                saw_enable = 1
            }
            in_options = 0
            print
            next
        }
        in_options && /^enable:/ {
            print "enable: 1"
            saw_enable = 1
            next
        }
        { print }
        END {
            if (!saw_options) {
                print ""
                print "[OPTIONS]"
                print "enable: 1"
            } else if (in_options && !saw_enable) {
                print "enable: 1"
            }
        }
    ' "$firewall_file" > "$tmp"
    cp "$tmp" "$firewall_file"
    rm -f "$tmp"
}

install_pve_firewall_rules() {
    local firewall_file="$1"
    local rules_file="$2"
    local tmp

    tmp="$(mktemp)"
    awk -v rules_file="$rules_file" '
        function print_rules(   line) {
            while ((getline line < rules_file) > 0) {
                print line
            }
            close(rules_file)
            inserted = 1
        }
        $0 == "# BEGIN HOMELAB RULES" { skip = 1; next }
        $0 == "# END HOMELAB RULES" { skip = 0; next }
        skip { next }
        /# HOMELAB/ { next }
        /^\[RULES\]$/ {
            in_rules = 1
            saw_rules = 1
            print
            next
        }
        /^\[/ {
            if (in_rules && !inserted) {
                print_rules()
            }
            in_rules = 0
            print
            next
        }
        { print }
        END {
            if (saw_rules && in_rules && !inserted) {
                print_rules()
            } else if (!saw_rules) {
                print ""
                print "[RULES]"
                print_rules()
            }
        }
    ' "$firewall_file" > "$tmp"
    cp "$tmp" "$firewall_file"
    rm -f "$tmp"
}

### 1️⃣ CREATE NETWORK BRIDGES ###

echo "[+] Backing up /etc/network/interfaces"
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%F-%H-%M)

if grep -qE "^iface[[:space:]]+$VM_BRIDGE[[:space:]]+" /etc/network/interfaces; then
    echo "[+] $VM_BRIDGE already exists in /etc/network/interfaces; skipping bridge append"
else
    echo "[+] Adding $VM_BRIDGE (Network)"
    cat <<EOF >>/etc/network/interfaces

# === Internal Network ===
auto $VM_BRIDGE
iface $VM_BRIDGE inet static
    address $GATEWAY_IP/24
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
fi

echo "[+] Reloading network..."
ifdown "$VM_BRIDGE" 2>/dev/null || true
ifup "$VM_BRIDGE"

### 2️⃣ ENABLE IP FORWARDING ###

echo "[+] Enabling IP forwarding"
sed -i 's/^#*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

### 3️⃣ FIREWALL RULES ###

echo "[+] Setting up firewall rules"

# Get the main network interface (usually vmbr0 or similar)
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
echo "[+] Detected main interface: $MAIN_INTERFACE"

if [ -z "$MAIN_INTERFACE" ]; then
    echo "Could not detect the default network interface" >&2
    exit 1
fi

# === NAT RULES FOR INTERNET ACCESS ===
# Enable NAT for Network (vmbr10) to access internet
iptables -t nat -C POSTROUTING -s "$NETWORK_CIDR" -o "$MAIN_INTERFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$NETWORK_CIDR" -o "$MAIN_INTERFACE" -j MASQUERADE

# === FORWARD RULES ===
# Allow internet access from both networks
iptables -C FORWARD -i "$VM_BRIDGE" -o "$MAIN_INTERFACE" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$VM_BRIDGE" -o "$MAIN_INTERFACE" -j ACCEPT

# Allow return traffic for established connections
iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Save iptables rules
echo "[+] Saving iptables rules"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
netfilter-persistent save

### 4️⃣ DNS CONFIGURATION ###

echo "[+] Setting up DNS forwarding"
# Install dnsmasq for DNS forwarding (optional but recommended)
apt-get install -y dnsmasq

# Configure dnsmasq for the custom networks
cat <<EOF >/etc/dnsmasq.d/proxmox-networks.conf
# DNS and DHCP for Homelab Network
interface=$VM_BRIDGE
bind-interfaces
dhcp-range=$VM_BRIDGE,$DHCP_START,$DHCP_END,24h
dhcp-option=$VM_BRIDGE,3,$GATEWAY_IP
dhcp-option=$VM_BRIDGE,6,$GATEWAY_IP
server=1.1.1.1
server=1.0.0.1
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

### 5️⃣ STATIC IP HINTS ###

echo "[+] Network configuration complete!"
echo ""
echo "=== NETWORK DETAILS ==="
echo "Network ($VM_BRIDGE):"
echo "  - Network: $NETWORK_CIDR"
echo "  - Gateway: $GATEWAY_IP"
echo "  - DNS: $GATEWAY_IP"
echo "  - DHCP Range: $DHCP_START-$DHCP_END (optional)"
echo "  - Static IPs: Use $NETWORK_PREFIX.2-99 for manual assignment"
echo ""
echo "=== LXC CONFIGURATION ==="
echo "For static IP configuration in LXCs, edit /etc/network/interfaces:"
echo ""
echo "# Example for Dev LXC (10.10.10.50):"
echo "auto eth0"
echo "iface eth0 inet static"
echo "    address $NETWORK_PREFIX.50/24"
echo "    gateway $GATEWAY_IP"
echo "    dns-nameservers $GATEWAY_IP"

### 6️⃣ ISOLATION BEST PRACTICES ###
echo ""
if [[ "$ENABLE_PVE_FIREWALL" == "true" ]]; then
    configure_pve_firewall
    if command -v pve-firewall >/dev/null 2>&1; then
        echo "[+] Enabling Proxmox firewall globally"
        pve-firewall start
        systemctl enable pve-firewall --now
    else
        echo "[!] pve-firewall not found; leaving Proxmox firewall service unchanged"
    fi
else
    echo "[+] Proxmox firewall left unchanged. Set HOMELAB_ENABLE_PVE_FIREWALL=true to enable it."
fi

echo ""
echo "[+] Done! Proxmox is now configured with:"
echo "    ✅ $VM_BRIDGE (Network: $NETWORK_CIDR) with internet access"
echo "    ✅ NAT rules for internet connectivity"
echo "    ✅ Optional DHCP service via dnsmasq"
echo ""
echo "🔍 To test internet connectivity from an LXC:"
echo "    ping 8.8.8.8"
echo "    curl -I https://google.com"
