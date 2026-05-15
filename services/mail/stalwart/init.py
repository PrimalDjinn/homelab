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
    value = {"name": name, "bind": [bind], "protocol": protocol}
    trusted = csv("STALWART_PROXY_TRUSTED_NETWORKS")
    if trusted and name in {"smtp", "submissions", "imaptls", "https"}:
        value["overrideProxyTrustedNetworks"] = trusted
    if implicit_tls:
        value["useImplicitTls"] = True
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
                "Access-Control-Allow-Headers": "Content-Type, Authorization, Accept",
                "Access-Control-Allow-Credentials": "true",
            }
        )

    listeners = {
        "smtp": listener("smtp", "[::]:25", "smtp"),
        "submission": listener("submission", "[::]:587", "smtp"),
        "submissions": listener("submissions", "[::]:465", "smtp", True),
        "imap": listener("imap", "[::]:143", "imap"),
        "imaptls": listener("imaptls", "[::]:993", "imap", True),
        "pop3": listener("pop3", "[::]:110", "pop3"),
        "pop3s": listener("pop3s", "[::]:995", "pop3", True),
        "sieve": listener("sieve", "[::]:4190", "managesieve"),
        "http": listener("http", "[::]:8080", "http"),
        "https": listener("https", "[::]:443", "http", True),
    }

    plan = [
        {"@type": "update", "object": "Bootstrap", "value": bootstrap()},
        {"@type": "destroy", "object": "NetworkListener"},
        {"@type": "create", "object": "NetworkListener", "value": listeners},
        {
            "@type": "update",
            "object": "Http",
            "value": {
                "usePermissiveCors": True,
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
