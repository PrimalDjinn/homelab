#!/usr/bin/env bash
# Host-side helper: wire mail API SMTP after a Stalwart sending account exists.
# Run on the Proxmox host once a mailbox has been created in Stalwart admin/webmail.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/utils.sh"

if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT_DIR/.env"
fi

STATE_DIR="${STATE_DIR:-/root/homelab}"
SECRETS_DIR="${SECRETS_DIR:-$STATE_DIR/secrets}"
MAIL_CTID="${MAIL_CTID:-113}"
MAIL_IP="${MAIL_IP:-10.10.10.40}"
MAIL_DOMAIN="${MAIL_DOMAIN:-mail.${SERVER_HOST:-example.com}}"
email_domain="${STALWART_DEFAULT_DOMAIN:-}"
if [[ -z "$email_domain" ]]; then
    if [[ "$MAIL_DOMAIN" == mail.* ]]; then
        email_domain="${MAIL_DOMAIN#mail.}"
    else
        email_domain="$MAIL_DOMAIN"
    fi
fi

quote() {
    printf '%q' "$1"
}

pct_exec() {
    local ctid="$1"
    shift
    pct exec "$ctid" -- bash -lc "$*"
}

random_secret() {
    local length="${1:-32}"
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
}

usage() {
    cat <<EOF
Usage:
  sudo ./configure-mail-smtp.sh --user EMAIL --pass PASSWORD [--from EMAIL] [--host HOST] [--port PORT]
  sudo ./configure-mail-smtp.sh --user EMAIL --generate-pass [--from EMAIL]

After a developer creates a Stalwart sending mailbox (same address + password),
this updates the mail API app SMTP settings inside LXC ${MAIL_CTID} and
recreates only the app container.

Defaults derived from MAIL_DOMAIN / STALWART_DEFAULT_DOMAIN:
  address domain: ${email_domain}
  suggested user: noreply@${email_domain}

Examples:
  # Account already created in Stalwart with a known password:
  sudo ./configure-mail-smtp.sh \\
    --user noreply@${email_domain} \\
    --pass 'your-stalwart-mailbox-password' \\
    --from noreply@${email_domain}

  # Generate a password, print it, then create the Stalwart account to match:
  sudo ./configure-mail-smtp.sh --user noreply@${email_domain} --generate-pass
EOF
}

smtp_user=""
smtp_pass=""
smtp_host=""
smtp_port="465"
default_from=""
generate_pass="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            smtp_user="${2:-}"; shift 2 ;;
        --pass)
            smtp_pass="${2:-}"; shift 2 ;;
        --host)
            smtp_host="${2:-}"; shift 2 ;;
        --port)
            smtp_port="${2:-}"; shift 2 ;;
        --from)
            default_from="${2:-}"; shift 2 ;;
        --generate-pass)
            generate_pass="true"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

[[ -n "$smtp_user" ]] || {
    usage >&2
    exit 1
}

require_root

if [[ "$smtp_user" != *@* ]]; then
    error "--user must be a full email address (e.g. noreply@${email_domain})"
fi

if [[ "$generate_pass" == "true" ]]; then
    [[ -z "$smtp_pass" ]] || error "Use either --pass or --generate-pass, not both."
    mkdir -p "$SECRETS_DIR"
    if [[ ! -f "$SECRETS_DIR/email-smtp-password" ]]; then
        umask 077
        random_secret 32 > "$SECRETS_DIR/email-smtp-password"
        chmod 600 "$SECRETS_DIR/email-smtp-password"
    fi
    smtp_pass="$(cat "$SECRETS_DIR/email-smtp-password")"
    info "SMTP password stored at $SECRETS_DIR/email-smtp-password"
elif [[ -z "$smtp_pass" && -f "$SECRETS_DIR/email-smtp-password" ]]; then
    smtp_pass="$(cat "$SECRETS_DIR/email-smtp-password")"
    info "Using existing password from $SECRETS_DIR/email-smtp-password"
fi

[[ -n "$smtp_pass" ]] || {
    error "Provide --pass PASSWORD or --generate-pass (or create $SECRETS_DIR/email-smtp-password)."
}

default_from="${default_from:-$smtp_user}"
smtp_host="${smtp_host:-${STALWART_HOSTNAME:-$MAIL_DOMAIN}}"

if ! command -v pct >/dev/null 2>&1; then
    error "pct not found. Run this on the Proxmox host."
fi

if ! pct status "$MAIL_CTID" &>/dev/null; then
    error "Mail LXC $MAIL_CTID is not present. Run the mail installer first."
fi

info "Pushing update-smtp-credentials.sh into LXC $MAIL_CTID"
pct push "$MAIL_CTID" "$ROOT_DIR/services/mail/update-smtp-credentials.sh" /opt/email-service/update-smtp-credentials.sh
pct_exec "$MAIL_CTID" "chmod +x /opt/email-service/update-smtp-credentials.sh"

info "Configuring mail API SMTP for $smtp_user (from=$default_from host=$smtp_host port=$smtp_port)"
pct_exec "$MAIL_CTID" \
    "/opt/email-service/update-smtp-credentials.sh --user $(quote "$smtp_user") --pass $(quote "$smtp_pass") --host $(quote "$smtp_host") --port $(quote "$smtp_port") --from $(quote "$default_from")"

if [[ "$generate_pass" == "true" ]]; then
    cat <<EOF

Create (or update) the Stalwart mailbox to match:
  email:    $smtp_user
  password: (see $SECRETS_DIR/email-smtp-password)

Stalwart admin: https://${MAIL_DOMAIN}/admin/  (or http://${MAIL_IP}:8080/admin/)
EOF
else
    info "Done. Ensure Stalwart has a mailbox for $smtp_user with the same password."
fi
