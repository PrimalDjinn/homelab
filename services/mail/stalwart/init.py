#!/usr/bin/env python3
import json
import os
from pathlib import Path


CONFIG_DIR = Path(os.environ.get("STALWART_CONFIG_DIR", "/etc/stalwart"))


def env(name, default=""):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def env_bool(name, default=False):
    value = env(name, "true" if default else "false").lower()
    return value in {"1", "true", "yes", "on"}


def csv(name):
    return [item.strip() for item in env(name).split(",") if item.strip()]


def secret_env(name):
    return {"@type": "EnvironmentVariable", "variableName": name}


def datastore():
    return {
        "@type": "PostgreSql",
        "host": "stalwart-db",
        "port": 5432,
        "database": env("STALWART_DB_NAME", "stalwart"),
        "authUsername": env("STALWART_DB_USER", "stalwart"),
        "authSecret": secret_env("STALWART_DB_PASSWORD"),
        "poolMaxConnections": 10,
    }


def dns_resolver():
    provider = env("STALWART_DNS_RESOLVER", "cloudflare").lower()
    resolver_type = {
        "system": "System",
        "cloudflare": "Cloudflare",
        "quad9": "Quad9",
        "google": "Google",
    }.get(provider, "Cloudflare")
    value = {
        "@type": resolver_type,
        "attempts": int(env("STALWART_DNS_ATTEMPTS", "2")),
        "concurrency": int(env("STALWART_DNS_CONCURRENCY", "2")),
        "enableEdns": env_bool("STALWART_DNS_ENABLE_EDNS", True),
        "preserveIntermediates": env_bool("STALWART_DNS_PRESERVE_INTERMEDIATES", True),
        "tcpOnError": env_bool("STALWART_DNS_TCP_ON_ERROR", True),
    }
    if resolver_type in {"Cloudflare", "Quad9"}:
        value["useTls"] = env_bool("STALWART_DNS_USE_TLS", False)
    return value


def apply_plan():
    hostname = env("STALWART_HOSTNAME", "mail.example.com")
    http_headers = {}
    origins = csv("STALWART_HTTP_CORS_ALLOWED_ORIGINS")
    if origins:
        http_headers.update(
            {
                "Access-Control-Allow-Origin": origins[0],
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS, DELETE, PUT",
                "Access-Control-Allow-Headers": "Content-Type, Authorization, Accept, X-Requested-With",
                "Access-Control-Allow-Credentials": "true",
            }
        )

    plan = [
        {"@type": "update", "object": "DnsResolver", "value": dns_resolver()},
        {
            "@type": "update",
            "object": "Http",
            "value": {
                "usePermissiveCors": env_bool("STALWART_HTTP_PERMISSIVE_CORS", False),
                "responseHeaders": http_headers,
            },
        },
        {
            "@type": "update",
            "object": "SystemSettings",
            "value": {"defaultHostname": hostname},
        },
    ]

    return plan


def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    (CONFIG_DIR / "bootstrap.json").unlink(missing_ok=True)
    (CONFIG_DIR / "config.json").write_text(json.dumps(datastore(), indent=2) + "\n")
    (CONFIG_DIR / "apply-plan.ndjson").write_text(
        "\n".join(json.dumps(item, separators=(",", ":")) for item in apply_plan()) + "\n"
    )
    print(f"Wrote Stalwart config and apply plan to {CONFIG_DIR}")


if __name__ == "__main__":
    main()
