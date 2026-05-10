#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

HOSTS_FILE='/etc/hosts'

check_hosts() {
    grep -q "$(get_ip)" "$HOSTS_FILE"
}

remove_host() {
    local name="$1"
    local tmp
    
    if [[ -z "$name" ]]; then
        echo "remove_host requires a hostname" >&2
        return 1
    fi
    
    tmp="$(mktemp)"
    
    awk -v name="$name" '
    {
        keep = 1

        for (i = 2; i <= NF; i++) {
            if ($i == name) {
                keep = 0
            }
        }

        if (keep) {
            print
        }
    }' "$HOSTS_FILE" > "$tmp"
    
    cp "$HOSTS_FILE" "$HOSTS_FILE.bak"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp"
}

add_host() {
    local ip
    local name
    
    ip="$(get_ip)"
    name="$(hostname)"
    
    echo "$ip $name" >> "$HOSTS_FILE"
}

prepare() {
    # It's recommended to remove the hostname from that record if unsure
    # as this avoids any ambiguity.
    remove_host "$(hostname)"
    
    if ! check_hosts; then
        add_host
    fi
}

restore_host() {
    cp $HOSTS_FILE.bak $HOSTS_FILE
}


if [[ "$1" == "--reset" ]]; then
    restore_host
else
    require_root
    prepare
fi
