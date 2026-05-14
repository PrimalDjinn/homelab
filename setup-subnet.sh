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
ENABLE_PVE_FIREWALL="${HOMELAB_ENABLE_PVE_FIREWALL:-true}"
WIREGUARD_PORT="${WIREGUARD_PORT:-51820}"
TAILSCALE_WIREGUARD_PORT="${TAILSCALE_WIREGUARD_PORT:-41641}"
MAIL_PORTS="${MAIL_PORTS:-25 110 143 465 587 993 995 4190}"
NETWORK_RELOAD_TIMEOUT="${HOMELAB_NETWORK_RELOAD_TIMEOUT:-60}"
NETWORK_RELOAD_RETRY_INTERVAL="${HOMELAB_NETWORK_RELOAD_RETRY_INTERVAL:-3}"
DNSMASQ_CONFIG="/etc/dnsmasq.d/proxmox-networks.conf"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run as root or with sudo." >&2
        exit 1
    fi
}

is_network_lock_error() {
    local output="${1,,}"

    [[ "$output" == *"another instance"* ]] || \
        [[ "$output" == *"lock"* ]] || \
        [[ "$output" == *"locked"* ]]
}

show_network_processes() {
    if command -v ps >/dev/null 2>&1; then
        ps -eo pid,ppid,stat,etime,cmd | awk '
            /[i]fup|[i]fdown|[i]freload|[i]fquery|[n]etworking/ { print }
        ' || true
    fi
}

run_network_command_with_retry() {
    local output
    local status
    local attempt=1
    local started=$SECONDS

    while true; do
        if output="$("$@" 2>&1)"; then
            [[ -n "$output" ]] && printf '%s\n' "$output"
            return 0
        fi

        status=$?
        if ! is_network_lock_error "$output"; then
            [[ -n "$output" ]] && printf '%s\n' "$output" >&2
            return "$status"
        fi

        if (( SECONDS - started >= NETWORK_RELOAD_TIMEOUT )); then
            echo "[!] Network command is still locked after ${NETWORK_RELOAD_TIMEOUT}s: $*" >&2
            [[ -n "$output" ]] && printf '%s\n' "$output" >&2
            echo "[!] Matching network processes:" >&2
            show_network_processes >&2
            return "$status"
        fi

        echo "[!] Network command is locked; retrying in ${NETWORK_RELOAD_RETRY_INTERVAL}s (attempt $attempt): $*"
        [[ -n "$output" ]] && printf '%s\n' "$output"
        sleep "$NETWORK_RELOAD_RETRY_INTERVAL"
        attempt=$((attempt + 1))
    done
}

reload_network_bridge() {
    if command -v ifreload >/dev/null 2>&1; then
        echo "[+] Applying network config with ifreload -a"
        if run_network_command_with_retry ifreload -a; then
            return 0
        fi

        echo "[!] ifreload failed; trying direct bridge recovery for $VM_BRIDGE"
    fi

    if command -v ifup >/dev/null 2>&1; then
        echo "[+] Applying network config with ifup/ifdown"
        if command -v ifdown >/dev/null 2>&1; then
            run_network_command_with_retry ifdown "$VM_BRIDGE" || true
        fi
        run_network_command_with_retry ifup "$VM_BRIDGE" && return 0

        echo "[!] ifup failed; trying direct bridge recovery for $VM_BRIDGE"
    fi

    ensure_runtime_bridge
}

ensure_runtime_bridge() {
    if ! command -v ip >/dev/null 2>&1; then
        echo "Required command missing: ip" >&2
        return 1
    fi

    if ! ip link show "$VM_BRIDGE" >/dev/null 2>&1; then
        echo "[+] Creating runtime bridge $VM_BRIDGE"
        ip link add name "$VM_BRIDGE" type bridge
    fi

    if ! ip -4 addr show dev "$VM_BRIDGE" | grep -qF " $GATEWAY_IP/24"; then
        echo "[+] Ensuring $VM_BRIDGE has $GATEWAY_IP/24"
        ip addr flush dev "$VM_BRIDGE" scope global || true
        ip addr add "$GATEWAY_IP/24" dev "$VM_BRIDGE"
    fi

    ip link set "$VM_BRIDGE" up
}

assert_bridge_ready() {
    if ! ip link show "$VM_BRIDGE" >/dev/null 2>&1; then
        echo "[!] $VM_BRIDGE does not exist after network reload; recovering directly"
        ensure_runtime_bridge
    fi

    if ! ip -4 addr show dev "$VM_BRIDGE" | grep -qF " $GATEWAY_IP/24"; then
        echo "[!] $VM_BRIDGE is missing $GATEWAY_IP/24 after network reload; recovering directly"
        ensure_runtime_bridge
    fi
}

write_if_changed() {
    local destination="$1"
    local source="$2"

    if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then
        rm -f "$source"
        return 1
    fi

    cp "$source" "$destination"
    rm -f "$source"
    return 0
}

configure_dnsmasq() {
    local tmp

    echo "[+] Setting up DNS forwarding"
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq

    tmp="$(mktemp)"
    cat <<EOF >"$tmp"
# DNS and DHCP for Homelab Network
interface=$VM_BRIDGE
bind-dynamic
dhcp-range=$VM_BRIDGE,$DHCP_START,$DHCP_END,24h
dhcp-option=$VM_BRIDGE,3,$GATEWAY_IP
dhcp-option=$VM_BRIDGE,6,$GATEWAY_IP
server=1.1.1.1
server=1.0.0.1
EOF

    if write_if_changed "$DNSMASQ_CONFIG" "$tmp"; then
        echo "[+] Wrote $DNSMASQ_CONFIG"
    else
        echo "[+] $DNSMASQ_CONFIG is already up to date"
    fi

    assert_bridge_ready

    if command -v dnsmasq >/dev/null 2>&1; then
        dnsmasq --test
    fi

    systemctl restart dnsmasq
    systemctl enable dnsmasq
}

configure_pve_firewall() {
    local node_dir
    local firewall_file
    local cluster_firewall_file
    local rules_file

    if [[ ! -d /etc/pve/nodes ]]; then
        echo "[!] /etc/pve/nodes is not available; skipping Proxmox host firewall rule configuration"
        return
    fi

    node_dir="/etc/pve/nodes/$(hostname)"
    if [[ ! -d "$node_dir" ]]; then
        node_dir="$(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d | head -n1)"
    fi

    if [[ -z "$node_dir" || ! -d "$node_dir" ]]; then
        echo "[!] No Proxmox node firewall directory found; skipping host firewall rules"
        return
    fi

    if [[ ! -d /etc/pve/firewall ]]; then
        echo "[!] /etc/pve/firewall is not available; skipping Proxmox firewall rules"
        return
    fi

    firewall_file="$node_dir/host.fw"
    cluster_firewall_file="/etc/pve/firewall/cluster.fw"
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
IN ACCEPT -p tcp -i $VM_BRIDGE -dport 53 -log nolog # HOMELAB internal DNS
IN ACCEPT -p udp -i $VM_BRIDGE -dport 53 -log nolog # HOMELAB internal DNS
IN ACCEPT -p udp -i $VM_BRIDGE -dport 67 -log nolog # HOMELAB internal DHCP
EOF
    for port in $MAIL_PORTS; do
        echo "IN ACCEPT -p tcp -dport $port -log nolog # HOMELAB mail port $port" >> "$rules_file"
    done

    install_pve_firewall_rules "$firewall_file" "$rules_file"
    rm -f "$rules_file"
}

enable_pve_firewall() {
    if ! command -v pve-firewall >/dev/null 2>&1; then
        echo "[!] pve-firewall not found; leaving Proxmox firewall service unchanged"
        return
    fi

    echo "[+] Enabling Proxmox firewall globally"
    pve-firewall start >/dev/null 2>&1 || echo "[!] pve-firewall start failed; Proxmox IPC may be unavailable"
    systemctl enable pve-firewall >/dev/null 2>&1 || echo "[!] Could not enable pve-firewall service"
    systemctl start pve-firewall >/dev/null 2>&1 || echo "[!] Could not start pve-firewall service"
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
            print "# BEGIN HOMELAB RULES"
            while ((getline line < rules_file) > 0) {
                print line
            }
            print "# END HOMELAB RULES"
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

require_root

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
reload_network_bridge
assert_bridge_ready

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

configure_dnsmasq

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

### 6️⃣ HOST FIREWALL ###
echo ""
if [[ "$ENABLE_PVE_FIREWALL" == "true" ]]; then
    configure_pve_firewall
    enable_pve_firewall
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
