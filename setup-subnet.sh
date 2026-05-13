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
# Enable NAT for Dev network (vmbr10) to access internet
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
echo "[+] Enabling Proxmox firewall globally"
pve-firewall start
systemctl enable pve-firewall --now

echo ""
echo "[+] Done! Proxmox is now configured with:"
echo "    ✅ $VM_BRIDGE (Network: $NETWORK_CIDR) with internet access"
echo "    ✅ NAT rules for internet connectivity"
echo "    ✅ Optional DHCP service via dnsmasq"
echo ""
echo "🔍 To test internet connectivity from an LXC:"
echo "    ping 8.8.8.8"
echo "    curl -I https://google.com"
