#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  update-smtp-credentials.sh --user USER --pass PASSWORD [--host HOST] [--port PORT] [--from EMAIL]

Updates /opt/email-service/.env with real SMTP credentials and recreates the
email-service app container. Run this inside the mail LXC after creating the
Stalwart SMTP mailbox/account.
EOF
}

smtp_user=""
smtp_pass=""
smtp_host=""
smtp_port=""
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
set_env SMTP_USER "$smtp_user"
set_env SMTP_PASS "$smtp_pass"
[[ -n "$smtp_host" ]] && set_env SMTP_HOST "$smtp_host"
[[ -n "$smtp_port" ]] && set_env SMTP_PORT "$smtp_port"
[[ -n "$default_from" ]] && set_env DEFAULT_FROM "$default_from"

docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d --force-recreate app
