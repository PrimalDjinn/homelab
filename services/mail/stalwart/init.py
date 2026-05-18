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


def default_domain(hostname):
    parts = hostname.split(".", 1)
    return parts[1] if len(parts) == 2 else hostname


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


def bootstrap():
    hostname = env("STALWART_HOSTNAME", "mail.example.com")
    return {
        "serverHostname": hostname,
        "defaultDomain": env("STALWART_DEFAULT_DOMAIN", default_domain(hostname)),
        "requestTlsCertificate": env_bool("STALWART_ACME_ENABLED", False),
        "generateDkimKeys": True,
        "dataStore": datastore(),
        "blobStore": {
            "@type": "S3Compatible",
            "bucket": env("STALWART_MINIO_BUCKET", "stalwart"),
            "region": env("STALWART_MINIO_REGION", "us-east-1"),
            "accessKey": env("STALWART_MINIO_ROOT_USER", "stalwart"),
            "secretKey": secret_env("STALWART_MINIO_ROOT_PASSWORD"),
            "endpoint": env("STALWART_MINIO_ENDPOINT", "http://stalwart-minio:9000"),
            "keyPrefix": "stalwart/",
        },
        "searchStore": {"@type": "Default"},
        "inMemoryStore": {
            "@type": "Redis",
            "urls": [f"redis://:{env('STALWART_REDIS_PASSWORD', 'stalwart')}@stalwart-redis:6379/0"],
        },
        "directory": {"@type": "Internal"},
        "dnsServer": {"@type": "Manual"},
    }


def listener(name, bind, protocol, implicit_tls=False):
    value = {"name": name, "bind": {bind: True}, "protocol": protocol}
    trusted = csv("STALWART_PROXY_TRUSTED_NETWORKS")
    if trusted and name in {"smtp", "submissions", "imaptls", "https"}:
        value["overrideProxyTrustedNetworks"] = trusted
    if implicit_tls:
        value["tlsImplicit"] = True
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

    listeners = {
        "smtp": listener("smtp", "0.0.0.0:25", "smtp"),
        "submission": listener("submission", "0.0.0.0:587", "smtp"),
        "submissions": listener("submissions", "0.0.0.0:465", "smtp", True),
        "imap": listener("imap", "0.0.0.0:143", "imap"),
        "imaptls": listener("imaptls", "0.0.0.0:993", "imap", True),
        "pop3": listener("pop3", "0.0.0.0:110", "pop3"),
        "pop3s": listener("pop3s", "0.0.0.0:995", "pop3", True),
        "sieve": listener("sieve", "0.0.0.0:4190", "manageSieve"),
        "http": listener("http", "0.0.0.0:8080", "http"),
    }

    plan = [
        {"@type": "update", "object": "Bootstrap", "value": bootstrap()},
        {"@type": "update", "object": "DnsResolver", "value": dns_resolver()},
        {"@type": "destroy", "object": "NetworkListener"},
        {"@type": "create", "object": "NetworkListener", "value": listeners},
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

    if env_bool("STALWART_ACME_ENABLED", False):
        challenge = env("STALWART_ACME_CHALLENGE", "tls-alpn-01")
        challenge_map = {"tls-alpn-01": "TlsAlpn01", "http-01": "Http01", "dns-01": "Dns01"}
        acme = {
            "challengeType": challenge_map.get(challenge, challenge),
            "contact": csv("STALWART_ACME_CONTACT") or [f"postmaster@{default_domain(hostname)}"],
            "domains": csv("STALWART_ACME_DOMAINS") or [hostname],
            "renewBefore": env("STALWART_ACME_RENEW_BEFORE", "30d"),
            "default": env_bool("STALWART_ACME_DEFAULT", True),
        }
        plan.extend(
            [
                {"@type": "destroy", "object": "AcmeProvider"},
                {"@type": "create", "object": "AcmeProvider", "value": {"letsencrypt": acme}},
            ]
        )

    return plan


def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    (CONFIG_DIR / "config.json").write_text(json.dumps(datastore(), indent=2) + "\n")
    (CONFIG_DIR / "bootstrap.json").write_text(json.dumps(bootstrap(), indent=2) + "\n")
    (CONFIG_DIR / "apply-plan.ndjson").write_text(
        "\n".join(json.dumps(item, separators=(",", ":")) for item in apply_plan()) + "\n"
    )
    print(f"Wrote Stalwart config, bootstrap, and apply plan to {CONFIG_DIR}")


if __name__ == "__main__":
    main()
