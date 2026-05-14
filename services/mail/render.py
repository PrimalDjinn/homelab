#!/usr/bin/env python3
import argparse
import os
import shutil
from pathlib import Path


def env(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def env_line(name: str, value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'{name}="{escaped}"'


def write_env(path: Path) -> None:
    domain = env("DOMAIN", env("SERVER_HOST", "example.com"))
    mail_domain = env("MAIL_DOMAIN", f"mail.{domain}")
    _ = env("EMAIL_APP_DOMAIN", f"email.{domain}")
    webmail_domain = env("WEBMAIL_DOMAIN", f"webmail.{domain}")
    _ = env("LISTMONK_DOMAIN", f"listmonk.{domain}")
    postal_domain = env("POSTAL_DOMAIN", f"postal.{domain}")
    _ = env("LIBREDESK_DOMAIN", f"libredesk.{domain}")
    autodiscover_domain = env("AUTODISCOVER_DOMAIN", f"autodiscover.{domain}")
    autoconfig_domain = env("AUTOCONFIG_DOMAIN", f"autoconfig.{domain}")
    mta_sts_domain = env("MTA_STS_DOMAIN", f"mta-sts.{domain}")
    le_email = env("LE_EMAIL", f"postmaster@{domain}")
    stalwart_cf_secret = env("STALWART_ACME_DNS_CF_SECRET", env("CLOUDFLARE_DNS_API_TOKEN"))

    values = {
        "COMPOSE_PROJECT_NAME": "email-service",
        "POSTGRES_USER": env("EMAIL_POSTGRES_USER", "email_service"),
        "POSTGRES_PASSWORD": env("EMAIL_POSTGRES_PASSWORD"),
        "POSTGRES_DB": env("EMAIL_POSTGRES_DB", "email_service"),
        "DATABASE_URL": (
            f"postgresql://{env('EMAIL_POSTGRES_USER', 'email_service')}:"
            f"{env('EMAIL_POSTGRES_PASSWORD')}@postgres:5432/{env('EMAIL_POSTGRES_DB', 'email_service')}"
        ),
        "REDIS_URL": "redis://redis:6379",
        "EMAIL_PROVIDER": env("EMAIL_PROVIDER", "nodemailer"),
        "RESEND_API_KEY": env("RESEND_API_KEY"),
        "SENDGRID_API_KEY": env("SENDGRID_API_KEY"),
        "MAILCHIMP_TRANSACTIONAL_API_KEY": env("MAILCHIMP_TRANSACTIONAL_API_KEY"),
        "POSTAL_API_URL": "http://postal-web:5000",
        "POSTAL_SERVER_API_KEY": env("POSTAL_SERVER_API_KEY"),
        "LISTMONK_API_URL": "http://listmonk-app:9000",
        "LISTMONK_USERNAME": env("LISTMONK_USERNAME", "admin"),
        "LISTMONK_PASSWORD": env("LISTMONK_PASSWORD"),
        "SMTP_HOST": env("SMTP_HOST", "stalwart"),
        "SMTP_PORT": env("SMTP_PORT", "587"),
        "SMTP_USER": env("SMTP_USER", f"noreply@{domain}"),
        "SMTP_PASS": env("SMTP_PASS"),
        "DEFAULT_FROM": env("DEFAULT_FROM", f"noreply@{domain}"),
        "JWT_SECRET": env("EMAIL_JWT_SECRET"),
        "ALLOWED_DOMAINS": env("ALLOWED_DOMAINS", domain),
        "POSTAL_IMAGE": env("POSTAL_IMAGE", "ghcr.io/postalserver/postal:latest"),
        "POSTAL_DB_NAME": env("POSTAL_DB_NAME", "postal"),
        "POSTAL_DB_ROOT_PASSWORD": env("POSTAL_DB_ROOT_PASSWORD"),
        "POSTAL_WEB_PROTOCOL": "https",
        "POSTAL_WEB_HOSTNAME": postal_domain,
        "POSTAL_SMTP_HOSTNAME": postal_domain,
        "POSTAL_MESSAGE_DB_PREFIX": env("POSTAL_MESSAGE_DB_PREFIX", "postal"),
        "POSTAL_RAILS_SECRET_KEY": env("POSTAL_RAILS_SECRET_KEY"),
        "POSTAL_ALLOWED_HOSTS": f"{postal_domain},postal-web,postal-web:5000",
        "POSTAL_DNS_MX_RECORDS": env("POSTAL_DNS_MX_RECORDS"),
        "POSTAL_DNS_SPF_INCLUDE": env("POSTAL_DNS_SPF_INCLUDE"),
        "POSTAL_DNS_RETURN_PATH_DOMAIN": env("POSTAL_DNS_RETURN_PATH_DOMAIN"),
        "POSTAL_DNS_ROUTE_DOMAIN": env("POSTAL_DNS_ROUTE_DOMAIN"),
        "POSTAL_DNS_TRACK_DOMAIN": env("POSTAL_DNS_TRACK_DOMAIN"),
        "LISTMONK_IMAGE": env("LISTMONK_IMAGE", "listmonk/listmonk:latest"),
        "LISTMONK_DB_USER": env("LISTMONK_DB_USER", "listmonk"),
        "LISTMONK_DB_PASSWORD": env("LISTMONK_DB_PASSWORD"),
        "LISTMONK_DB_NAME": env("LISTMONK_DB_NAME", "listmonk"),
        "LISTMONK_ADMIN_USER": env("LISTMONK_ADMIN_USER", "admin"),
        "LISTMONK_ADMIN_PASSWORD": env("LISTMONK_ADMIN_PASSWORD"),
        "LISTMONK_TIMEZONE": env("LISTMONK_TIMEZONE", "Etc/UTC"),
        "STALWART_IMAGE": env("STALWART_IMAGE", "stalwartlabs/stalwart:latest"),
        "STALWART_HOSTNAME": mail_domain,
        "STALWART_AUTODISCOVER_HOSTNAME": autodiscover_domain,
        "STALWART_AUTOCONFIG_HOSTNAME": autoconfig_domain,
        "STALWART_MTA_STS_HOSTNAME": mta_sts_domain,
        "STALWART_ADMIN_USER": env("STALWART_ADMIN_USER", "admin"),
        "STALWART_ADMIN_PASSWORD": env("STALWART_ADMIN_PASSWORD"),
        "STALWART_ACME_ENABLED": env("STALWART_ACME_ENABLED", "true"),
        "STALWART_ACME_DIRECTORY": env("STALWART_ACME_DIRECTORY", "https://acme-v02.api.letsencrypt.org/directory"),
        "STALWART_ACME_CHALLENGE": env("STALWART_ACME_CHALLENGE", "dns-01"),
        "STALWART_ACME_CONTACT": env("STALWART_ACME_CONTACT", le_email),
        "STALWART_ACME_DOMAINS": env("STALWART_ACME_DOMAINS", mail_domain),
        "STALWART_ACME_CACHE": env("STALWART_ACME_CACHE", "%{BASE_PATH}%/etc/acme"),
        "STALWART_ACME_RENEW_BEFORE": env("STALWART_ACME_RENEW_BEFORE", "30d"),
        "STALWART_ACME_DEFAULT": env("STALWART_ACME_DEFAULT", "true"),
        "STALWART_ACME_DNS_PROVIDER": env("STALWART_ACME_DNS_PROVIDER", "cloudflare"),
        "STALWART_ACME_DNS_POLLING_INTERVAL": env("STALWART_ACME_DNS_POLLING_INTERVAL", "15s"),
        "STALWART_ACME_DNS_PROPAGATION_TIMEOUT": env("STALWART_ACME_DNS_PROPAGATION_TIMEOUT", "1m"),
        "STALWART_ACME_DNS_TTL": env("STALWART_ACME_DNS_TTL", "5m"),
        "STALWART_ACME_DNS_ORIGIN": env("STALWART_ACME_DNS_ORIGIN"),
        "STALWART_ACME_DNS_CF_SECRET": stalwart_cf_secret,
        "STALWART_ACME_DNS_CF_EMAIL": env("STALWART_ACME_DNS_CF_EMAIL"),
        "STALWART_ACME_DNS_CF_TIMEOUT": env("STALWART_ACME_DNS_CF_TIMEOUT", "30s"),
        "STALWART_PROXY_TRUSTED_NETWORKS": env("STALWART_PROXY_TRUSTED_NETWORKS"),
        "STALWART_PROXY_AUTODETECT": "false",
        "STALWART_HTTP_USE_X_FORWARDED": "true",
        "STALWART_HTTP_CORS_ALLOWED_ORIGINS": f"https://{webmail_domain}",
        "STALWART_WEBMAIL_HOSTNAME": webmail_domain,
        "STALWART_HTTP_PROTOCOL": "https",
        "STALWART_TRAEFIK_ENABLED": "false",
        "STALWART_DB_USER": env("STALWART_DB_USER", "stalwart"),
        "STALWART_DB_PASSWORD": env("STALWART_DB_PASSWORD"),
        "STALWART_DB_NAME": env("STALWART_DB_NAME", "stalwart"),
        "STALWART_REDIS_PASSWORD": env("STALWART_REDIS_PASSWORD"),
        "STALWART_MINIO_ROOT_USER": env("STALWART_MINIO_ROOT_USER", "stalwart"),
        "STALWART_MINIO_ROOT_PASSWORD": env("STALWART_MINIO_ROOT_PASSWORD"),
        "STALWART_MINIO_BUCKET": env("STALWART_MINIO_BUCKET", "stalwart"),
        "STALWART_MINIO_REGION": env("STALWART_MINIO_REGION", "us-east-1"),
        "BULWARK_IMAGE": env("BULWARK_IMAGE", "ghcr.io/bulwarkmail/webmail:latest"),
        "BULWARK_HOSTNAME": "0.0.0.0",
        "BULWARK_PORT": "3000",
        "BULWARK_JMAP_SERVER_URL": "http://stalwart:8080",
        "BULWARK_SESSION_SECRET": env("BULWARK_SESSION_SECRET"),
        "BULWARK_WEBMAIL_HOSTNAME": webmail_domain,
        "BULWARK_OAUTH_ENABLED": env("BULWARK_OAUTH_ENABLED", "false"),
        "BULWARK_OAUTH_CLIENT_ID": env("BULWARK_OAUTH_CLIENT_ID", "webmail"),
        "BULWARK_OAUTH_CLIENT_SECRET": env("BULWARK_OAUTH_CLIENT_SECRET"),
        "BULWARK_OAUTH_ISSUER_URL": env("BULWARK_OAUTH_ISSUER_URL"),
        "BULWARK_APP_NAME": env("BULWARK_APP_NAME", "Webmail"),
        "BULWARK_LOGIN_COMPANY_NAME": env("BULWARK_LOGIN_COMPANY_NAME", domain),
        "BULWARK_TRAEFIK_ENABLED": "false",
        "LIBREDESK_SYSTEM_USER_PASSWORD": env("LIBREDESK_SYSTEM_USER_PASSWORD"),
        "LIBREDESK_POSTGRES_USER": env("LIBREDESK_POSTGRES_USER", "master"),
        "LIBREDESK_DB__PASSWORD": env("LIBREDESK_DB__PASSWORD"),
        "LIBREDESK_POSTGRES_DB": env("LIBREDESK_POSTGRES_DB", "libredesk"),
        "LIBREDESK_APP__ENCRYPTION_KEY": env("LIBREDESK_APP__ENCRYPTION_KEY"),
        "LIBREDESK_DB__HOST": "libredesk-db",
        "LIBREDESK_DB__PORT": "5432",
        "LIBREDESK_REDIS__ADDRESS": "libredesk-redis:6379",
    }

    path.write_text("\n".join(env_line(key, value) for key, value in values.items()) + "\n")


def write_compose_override(path: Path) -> None:
    path.write_text(
        """services:
  stalwart:
    ports:
      - "8080:8080"
""",
        encoding="utf8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    dest = args.output_dir
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    write_env(dest / ".env")
    write_compose_override(dest / "docker-compose.homelab.yml")


if __name__ == "__main__":
    main()
