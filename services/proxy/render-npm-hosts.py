#!/usr/bin/env python3
import argparse
import json
import os
import shutil
from pathlib import Path


def env(name: str) -> str:
    return os.environ.get(name, "")


def proxy_payload(domain: str, host: str, port: int) -> dict:
    return {
        "domain_names": [domain],
        "forward_scheme": "http",
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
    }
    for name, payload in hosts.items():
        (dest / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")


if __name__ == "__main__":
    main()
