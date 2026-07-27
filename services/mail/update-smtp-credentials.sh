#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  update-smtp-credentials.sh --user USER --pass PASSWORD [--host HOST] [--port PORT] [--from EMAIL]

Updates /opt/email-service/.env with real SMTP credentials and recreates the
email-service app container. Run this inside the mail LXC after creating the
Stalwart SMTP mailbox/account.

Prefer the host wrapper from the Proxmox host:
  sudo ./configure-mail-smtp.sh --user noreply@example.com --pass 'secret'
EOF
}

smtp_user=""
smtp_pass=""
smtp_host="stalwart"
smtp_port="465"
default_from=""

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
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

[[ -n "$smtp_user" && -n "$smtp_pass" ]] || {
    usage >&2
    exit 1
}

if [[ "$smtp_user" != *@* ]]; then
    echo "error: --user must be a full email address (e.g. noreply@example.com)" >&2
    exit 1
fi

default_from="${default_from:-$smtp_user}"

cd /opt/email-service

set_env() {
    local key="$1" value="$2"
    local escaped
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" .env
    else
        printf '%s="%s"\n' "$key" "$escaped" >> .env
    fi
}

set_env EMAIL_PROVIDER nodemailer
set_env SMTP_HOST "$smtp_host"
set_env SMTP_PORT "$smtp_port"
set_env SMTP_USER "$smtp_user"
set_env SMTP_PASS "$smtp_pass"
set_env DEFAULT_FROM "$default_from"

echo "Updated SMTP settings:"
echo "  EMAIL_PROVIDER=nodemailer"
echo "  SMTP_HOST=$smtp_host"
echo "  SMTP_PORT=$smtp_port"
echo "  SMTP_USER=$smtp_user"
echo "  DEFAULT_FROM=$default_from"
echo "  SMTP_PASS=(hidden)"

docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d --force-recreate app
echo "email-service app recreated with new SMTP credentials."
