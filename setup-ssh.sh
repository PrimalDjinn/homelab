#!/usr/bin/env bash
# setup-ssh.sh — Add a public key to ~/.ssh/authorized_keys with correct permissions.
#
# USAGE:
#   ./setup-ssh.sh --key "ssh-ed25519 AAAA..."        # inline argument
#   ./setup-ssh.sh --key-file /path/to/id_rsa.pub     # read from a file
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." ./setup-ssh.sh  # environment variable
#   ./setup-ssh.sh                                     # interactive stdin prompt
#   ./setup-ssh.sh --help                              # show this help

set -euo pipefail

# ─────────────────────────────────────────────
# Colours
# ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────
show_help() {
  cat <<EOF

${BOLD}setup-ssh.sh${RESET} — Install an SSH public key for the current user.

${BOLD}SYNOPSIS${RESET}
  ./setup-ssh.sh [OPTIONS]

${BOLD}OPTIONS${RESET}
  -k, --key   <pubkey>     Public key string passed directly as an argument.
  -f, --key-file <path>    Path to a .pub file to read the key from.
  -u, --user  <username>   Target user account  (default: \$USER / current user).
                           Requires root when specifying another user.
  -h, --help               Show this help message and exit.

${BOLD}INPUT METHODS${RESET}  (checked in this order)

  1. ${BOLD}CLI argument${RESET}  --key / -k
       ./setup-ssh.sh --key "ssh-ed25519 AAAA..."

  2. ${BOLD}Key file${RESET}  --key-file / -f
       ./setup-ssh.sh --key-file ~/.ssh/id_ed25519.pub

  3. ${BOLD}Environment variable${RESET}  SSH_PUBLIC_KEY
       export SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."
       ./setup-ssh.sh

  4. ${BOLD}Pipe / stdin${RESET}  (non-interactive)
       cat ~/.ssh/id_ed25519.pub | ./setup-ssh.sh

  5. ${BOLD}Interactive prompt${RESET}  (fallback when no other source detected)
       ./setup-ssh.sh
       # You will be asked to paste the key.

${BOLD}WHAT IT DOES${RESET}
  • Checks that required programs are installed (ssh-keygen, awk, chmod, etc.)
  • Validates the public key format with ssh-keygen
  • Creates ~/.ssh with mode 700 if it does not exist
  • Appends the key to ~/.ssh/authorized_keys (skips if already present)
  • Sets mode 600 on authorized_keys
  • Verifies the final permissions

${BOLD}EXAMPLES${RESET}
  # Add key for the current user
  ./setup-ssh.sh --key "ssh-rsa AAAAB3Nza..."

  # Add key for another user (run as root)
  sudo ./setup-ssh.sh --user deploy --key-file /tmp/deploy.pub

  # Pipe from local machine to remote via SSH
  cat ~/.ssh/id_ed25519.pub | ssh user@host "bash -s" < setup-ssh.sh

EOF
}

# ─────────────────────────────────────────────
# Prerequisite check
# ─────────────────────────────────────────────
REQUIRED_CMDS=(ssh-keygen awk chmod mkdir grep install id)

check_prerequisites() {
  info "Checking required programs…"
  local missing=()
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required programs: ${missing[*]}\n       Install openssh-client (or openssh) and coreutils and try again."
  fi
  success "All required programs found."
}

# ─────────────────────────────────────────────
# Key validation
# ─────────────────────────────────────────────
validate_key() {
  local key="$1"

  # Basic structure check — must start with a known key type
  if ! echo "$key" | grep -qE \
    '^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) '; then
    die "Key does not start with a recognised SSH key type.\n       Supported: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp*, etc."
  fi

  # Use ssh-keygen for a deep validation via a temp file
  local tmpfile
  tmpfile=$(mktemp /tmp/ssh-pubkey-check.XXXXXX)
  echo "$key" > "$tmpfile"
  if ! ssh-keygen -l -f "$tmpfile" &>/dev/null; then
    rm -f "$tmpfile"
    die "ssh-keygen rejected the key as invalid. Check for copy-paste truncation."
  fi

  local fingerprint
  fingerprint=$(ssh-keygen -l -f "$tmpfile" 2>/dev/null)
  rm -f "$tmpfile"
  success "Key validated: ${fingerprint}"
}

# ─────────────────────────────────────────────
# Install the key
# ─────────────────────────────────────────────
install_key() {
  local pubkey="$1"
  local target_user="$2"
  local home_dir

  # Resolve home directory for target user
  if [[ "$target_user" == "$USER" ]]; then
    home_dir="$HOME"
  else
    home_dir=$(getent passwd "$target_user" 2>/dev/null | awk -F: '{print $6}') \
      || die "Cannot find home directory for user '$target_user'."
    [[ -n "$home_dir" ]] || die "Home directory for '$target_user' is empty."
  fi

  local ssh_dir="${home_dir}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  # ── .ssh directory ──────────────────────────
  if [[ ! -d "$ssh_dir" ]]; then
    info "Creating ${ssh_dir} …"
    install -d -m 700 -o "$target_user" "$ssh_dir"
    success "Created ${ssh_dir} (mode 700)."
  else
    info "${ssh_dir} already exists — checking permissions…"
    chmod 700 "$ssh_dir"
    chown "$target_user" "$ssh_dir"
    success "Permissions on ${ssh_dir} set to 700."
  fi

  # ── authorized_keys file ────────────────────
  if [[ ! -f "$auth_keys" ]]; then
    info "Creating ${auth_keys} …"
    install -m 600 -o "$target_user" /dev/null "$auth_keys"
    success "Created ${auth_keys} (mode 600)."
  fi

  # ── Duplicate check ─────────────────────────
  # Compare only the key material (field 2) to avoid comment mismatches
  local new_keydata
  new_keydata=$(echo "$pubkey" | awk '{print $2}')

  if grep -qF "$new_keydata" "$auth_keys" 2>/dev/null; then
    warn "Key is already present in ${auth_keys} — skipping append."
  else
    echo "$pubkey" >> "$auth_keys"
    success "Key appended to ${auth_keys}."
  fi

  # ── Final permission enforcement ─────────────
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_keys"
  chown "$target_user" "$ssh_dir" "$auth_keys"

  # ── Verify ──────────────────────────────────
  local dir_perms file_perms
  dir_perms=$(stat -c "%a" "$ssh_dir")
  file_perms=$(stat -c "%a" "$auth_keys")

  if [[ "$dir_perms" != "700" ]]; then
    die "Unexpected permissions on ${ssh_dir}: ${dir_perms} (expected 700)."
  fi
  if [[ "$file_perms" != "600" ]]; then
    die "Unexpected permissions on ${auth_keys}: ${file_perms} (expected 600)."
  fi

  success "Permissions verified: ${ssh_dir}=700  ${auth_keys}=600"
  echo
  echo -e "${GREEN}${BOLD}✔  SSH public key installed successfully for user '${target_user}'.${RESET}"
}

# ─────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────
PUBLIC_KEY=""
KEY_FILE=""
TARGET_USER="${SUDO_USER:-$USER}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          show_help; exit 0 ;;
    -k|--key)           shift; PUBLIC_KEY="${1:-}"; shift ;;
    -f|--key-file)      shift; KEY_FILE="${1:-}";    shift ;;
    -u|--user)          shift; TARGET_USER="${1:-}"; shift ;;
    *)                  die "Unknown option: $1\nRun with --help for usage." ;;
  esac
done

# ─────────────────────────────────────────────
# Resolve target user / root guard
# ─────────────────────────────────────────────
CURRENT_USER="${SUDO_USER:-$USER}"
if [[ "$TARGET_USER" != "$CURRENT_USER" ]] && [[ "$(id -u)" -ne 0 ]]; then
  die "You must run as root (or with sudo) to install a key for another user."
fi

# ─────────────────────────────────────────────
# Resolve public key — priority order
# ─────────────────────────────────────────────
check_prerequisites

if [[ -n "$PUBLIC_KEY" ]]; then
  info "Using key from --key argument."

elif [[ -n "$KEY_FILE" ]]; then
  info "Reading key from file: ${KEY_FILE}"
  [[ -f "$KEY_FILE" ]] || die "File not found: ${KEY_FILE}"
  PUBLIC_KEY=$(< "$KEY_FILE")

elif [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  info "Using key from SSH_PUBLIC_KEY environment variable."
  PUBLIC_KEY="$SSH_PUBLIC_KEY"

elif [[ ! -t 0 ]]; then
  # stdin is a pipe / redirect
  info "Reading key from stdin (pipe)…"
  PUBLIC_KEY=$(cat)

else
  # Interactive fallback
  echo -e "${YELLOW}No key source detected.${RESET}"
  echo    "Paste your SSH public key below, then press Enter:"
  read -r PUBLIC_KEY
fi

# Strip surrounding whitespace / newlines
PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

[[ -n "$PUBLIC_KEY" ]] || die "No public key provided. Run with --help for usage."

# ─────────────────────────────────────────────
# Validate then install
# ─────────────────────────────────────────────
validate_key  "$PUBLIC_KEY"
install_key   "$PUBLIC_KEY" "$TARGET_USER"