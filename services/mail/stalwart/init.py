#!/usr/bin/env python3
import json
import os
from pathlib import Path
from urllib.parse import quote


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
        "maxConcurrentRequests": int(env("STALWART_DNS_CONCURRENCY", "2")),
        "enableEdns": env_bool("STALWART_DNS_ENABLE_EDNS", True),
        "preserveIntermediates": env_bool("STALWART_DNS_PRESERVE_INTERMEDIATES", True),
        "tcpOnError": env_bool("STALWART_DNS_TCP_ON_ERROR", True),
    }
    if resolver_type in {"Cloudflare", "Quad9"}:
        value["useTls"] = env_bool("STALWART_DNS_USE_TLS", False)
    return value


def apply_plan():
    hostname = env("STALWART_HOSTNAME", "mail.example.com")
    domain = env("STALWART_DEFAULT_DOMAIN", default_domain(hostname))
    http_headers = {}
    origins = csv("STALWART_HTTP_CORS_ALLOWED_ORIGINS")
    if len(origins) > 1 or "*" in origins:
        raise ValueError("Configure one explicit CORS origin, or use STALWART_HTTP_PERMISSIVE_CORS")
    if origins:
        http_headers.update(
            {
                "Access-Control-Allow-Origin": origins[0],
                "Access-Control-Allow-Methods": "POST, GET, PATCH, PUT, DELETE, HEAD, OPTIONS",
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
                "clientIpSource": "xForwardedFor" if env_bool("STALWART_HTTP_USE_X_FORWARDED", True) else "peer",
                "forwardedHops": 1,
                "usePermissiveCors": env_bool("STALWART_HTTP_PERMISSIVE_CORS", False),
                "responseHeaders": http_headers,
            },
        },
        {
            "@type": "update",
            "object": "SystemSettings",
            "value": {
                "defaultHostname": hostname,
                "defaultDomainId": f"name:{domain}",
            },
        },
        {
            "@type": "update",
            "object": "MtaStageConnect",
            # Expression language: string literals must be single-quoted.
            "value": {
                "hostname": {"match": {}, "else": f"'{hostname}'"},
                "smtpGreeting": {
                    "match": {},
                    "else": f"'{hostname}' + ' Stalwart ESMTP at your service'",
                },
            },
        },
    ]

    return plan


def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    # This is an explicit first-install input; never apply it over a populated store.
    hostname = env("STALWART_HOSTNAME", "mail.example.com")
    bootstrap = {
        "defaultHostname": hostname,
        "defaultDomain": env("STALWART_DEFAULT_DOMAIN", default_domain(hostname)),
        "requestTlsCertificate": env_bool("STALWART_ACME_ENABLED", False),
        "generateDkimKeys": True,
        "dataStore": datastore(),
        "blobStore": {
            "@type": "S3",
            "bucket": env("STALWART_S3_BUCKET", "stalwart"),
            "region": {"@type": "Custom", "region": env("STALWART_S3_REGION", "garage"), "url": env("STALWART_S3_ENDPOINT", "http://stalwart-garage:3900")},
            "accessKeyId": {"@type": "Value", "value": Path(env("STALWART_S3_ACCESS_KEY_FILE", "/etc/stalwart-s3/access-key")).read_text().strip()},
            "secretKey": {"@type": "File", "filePath": env("STALWART_S3_SECRET_KEY_FILE", "/etc/stalwart-s3/secret-key")},
            "keyPrefix": "stalwart/",
        },
        "searchStore": {"@type": "Default"},
        "inMemoryStore": {"@type": "Redis", "url": f"redis://:{quote(env('STALWART_REDIS_PASSWORD', 'stalwart'), safe='')}@stalwart-redis:6379/0"},
        "directory": {"@type": "Internal"},
        "dnsServer": {"@type": "Manual"},
    }
    (CONFIG_DIR / "bootstrap.json").write_text(json.dumps(bootstrap, indent=2) + "\n")
    (CONFIG_DIR / "bootstrap.json").chmod(0o600)
    (CONFIG_DIR / "datastore.json").write_text(json.dumps(datastore(), indent=2) + "\n")
    (CONFIG_DIR / "apply-plan.ndjson").write_text(
        "\n".join(json.dumps(item, separators=(",", ":")) for item in apply_plan()) + "\n"
    )
    # Keep an existing live datastore pointer; a fresh install must enter bootstrap.
    os.chown(CONFIG_DIR, int(env("STALWART_UID", "2000")), int(env("STALWART_UID", "2000")))
    print(f"Wrote Stalwart datastore template, bootstrap input and apply plan to {CONFIG_DIR}")


if __name__ == "__main__":
    main()
