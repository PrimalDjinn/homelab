#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
	# shellcheck disable=SC1090
	source "$SCRIPT_DIR/.env"
fi

issue_warning() {
	info "Proxmox setup complete; rerun with --all to setup the server"
	warn "Make sure you have an SSH key and have it set up, that setup step will disable ssh password access"
}

bash "$SCRIPT_DIR/setup-proxmox.sh"

if [[ "${1:-}" == "--all" ]]; then
	issue_warning
	info "Press Ctrl+C now to cancel it"
	sleep 10
	bash "$SCRIPT_DIR/setup-server.sh"
	bash "$SCRIPT_DIR/setup-subnet.sh"
	bash "$SCRIPT_DIR/setup-lxcs.sh"
else
	issue_warning
fi
