#!/usr/bin/env python3
import argparse
import json
import os
import shutil
from pathlib import Path


def env(name: str) -> str:
    return os.environ.get(name, "")


def proxy_payload(domain: str | list[str], host: str, port: int, scheme: str = "http") -> dict:
    domains = [domain] if isinstance(domain, str) else domain
    domains = [item for item in domains if item]
    return {
        "domain_names": domains,
        "forward_scheme": scheme,
        "forward_host": host,
        "forward_port": port,
        "access_list_id": 0,
        "certificate_id": 0,
        "ssl_forced": False,
        "caching_enabled": False,
        "block_exploits": True,
        "allow_websocket_upgrade": True,
        "http2_support": True,
        "hsts_enabled": False,
        "hsts_subdomains": False,
        "meta": {
            "letsencrypt_agree": False,
            "dns_challenge": False,
        },
        "advanced_config": "",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    dest = args.output_dir
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    hosts = {
        "auth": proxy_payload(env("AUTH_DOMAIN"), env("AUTH_IP"), 9091),
        "headscale": proxy_payload(env("HEADSCALE_DOMAIN"), env("HEADSCALE_IP"), 8080),
        "headplane": proxy_payload(env("HEADPLANE_DOMAIN"), env("HEADSCALE_IP"), 3000),
        "openpanel": proxy_payload(
            env("OPENPANEL_CLIENT_PANEL_DOMAIN"),
            env("OPENPANEL_IP"),
            int(env("OPENPANEL_CLIENT_PANEL_PORT") or 2083),
            env("OPENPANEL_CLIENT_PANEL_SCHEME") or "http",
        ),
        "openadmin": proxy_payload(env("OPENPANEL_ADMIN_DOMAIN"), env("OPENPANEL_IP"), 80),
        "email": proxy_payload(env("EMAIL_APP_DOMAIN"), env("MAIL_IP"), 3001),
        "webmail": proxy_payload(env("WEBMAIL_DOMAIN"), env("MAIL_IP"), 3000),
        "listmonk": proxy_payload(env("LISTMONK_DOMAIN"), env("MAIL_IP"), 9000),
        "postal": proxy_payload(env("POSTAL_DOMAIN"), env("MAIL_IP"), 5000),
        "libredesk": proxy_payload(env("LIBREDESK_DOMAIN"), env("MAIL_IP"), 9001),
        "mail": proxy_payload(
            [
                env("MAIL_DOMAIN"),
                env("AUTODISCOVER_DOMAIN"),
                env("AUTOCONFIG_DOMAIN"),
                env("MTA_STS_DOMAIN"),
            ],
            env("MAIL_IP"),
            8080,
        ),
    }
    for name, payload in hosts.items():
        (dest / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")


if __name__ == "__main__":
    main()
