#!/usr/bin/env python3
import argparse
import csv
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


MANAGED_MARKER = "# homelab-managed"
INVENTORY_HEADERS = ("kind", "domain", "resource_id")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def truthy(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "y", "on"}


def inventory_path() -> Path:
    return Path(env("HOMELAB_MANAGED_RESOURCES_CSV", "/opt/nginx-proxy-manager/data/homelab-managed-resources.csv"))


def load_inventory() -> dict[tuple[str, str], dict[str, str]]:
    path = inventory_path()
    if not path.exists():
        return {}
    with path.open(newline="") as handle:
        rows = csv.DictReader(handle)
        return {
            (row.get("kind", ""), row.get("domain", "")): {
                "kind": row.get("kind", ""),
                "domain": row.get("domain", ""),
                "resource_id": row.get("resource_id", ""),
            }
            for row in rows
            if row.get("kind") and row.get("domain")
        }


def save_inventory(inventory: dict[tuple[str, str], dict[str, str]]) -> None:
    path = inventory_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=INVENTORY_HEADERS)
        writer.writeheader()
        for key in sorted(inventory):
            writer.writerow(inventory[key])


def upsert_inventory_row(inventory: dict[tuple[str, str], dict[str, str]], kind: str, domain: str, resource_id: int | str) -> None:
    inventory[(kind, domain)] = {"kind": kind, "domain": domain, "resource_id": str(resource_id)}


def remove_inventory_row(inventory: dict[tuple[str, str], dict[str, str]], kind: str, domain: str) -> None:
    inventory.pop((kind, domain), None)


def api(method: str, path: str, token: str = "", payload: dict | None = None):
    base_url = env("NPM_URL", "http://127.0.0.1:81").rstrip("/")
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None:
        data = json.dumps(payload).encode()

    request = urllib.request.Request(f"{base_url}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"NPM API {method} {path} failed with HTTP {exc.code}: {body}") from exc


def npm_token() -> str:
    response = api(
        "POST",
        "/api/tokens",
        payload={"identity": env("NPM_EMAIL"), "secret": env("NPM_PASSWORD")},
    )
    token = (response or {}).get("token", "")
    if not token:
        raise RuntimeError("NPM login returned no token")
    return token


def desired_payloads(directory: Path) -> dict[str, dict]:
    payloads: dict[str, dict] = {}
    for path in sorted(directory.glob("*.json")):
        payload = json.loads(path.read_text())
        domains = payload.get("domain_names") or []
        if domains:
            payloads[domains[0]] = payload
    return payloads


def host_by_primary_domain(hosts: list[dict], domain: str) -> dict | None:
    return next((host for host in hosts if domain in (host.get("domain_names") or [])), None)


def is_managed_host(host: dict) -> bool:
    return MANAGED_MARKER in (host.get("advanced_config") or "")


def merge_advanced_config(existing: str, desired: str) -> str:
    lines: list[str] = []
    for block in (existing, desired, MANAGED_MARKER):
        for line in block.splitlines():
            stripped = line.strip()
            if stripped and stripped not in lines:
                lines.append(stripped)
    return "\n".join(lines)


def build_update_payload(existing: dict, desired: dict) -> dict:
    return {
        "domain_names": desired.get("domain_names") or existing.get("domain_names") or [],
        "forward_scheme": desired.get("forward_scheme") or existing.get("forward_scheme") or "http",
        "forward_host": desired.get("forward_host") or existing.get("forward_host") or "",
        "forward_port": desired.get("forward_port") or existing.get("forward_port") or 80,
        "access_list_id": existing.get("access_list_id") or desired.get("access_list_id") or 0,
        "certificate_id": existing.get("certificate_id") or 0,
        "ssl_forced": bool(existing.get("ssl_forced", False)),
        "caching_enabled": bool(desired.get("caching_enabled", existing.get("caching_enabled", False))),
        "block_exploits": bool(desired.get("block_exploits", existing.get("block_exploits", True))),
        "allow_websocket_upgrade": bool(desired.get("allow_websocket_upgrade", existing.get("allow_websocket_upgrade", True))),
        "http2_support": bool(desired.get("http2_support", existing.get("http2_support", True))),
        "hsts_enabled": bool(desired.get("hsts_enabled", existing.get("hsts_enabled", False))),
        "hsts_subdomains": bool(desired.get("hsts_subdomains", existing.get("hsts_subdomains", False))),
        "meta": {**(existing.get("meta") or {}), **(desired.get("meta") or {})},
        "advanced_config": merge_advanced_config(existing.get("advanced_config") or "", desired.get("advanced_config") or ""),
        "locations": existing.get("locations") or [],
    }


def sync_hosts(token: str, desired: dict[str, dict], prune_managed: bool) -> None:
    inventory = load_inventory()
    hosts = api("GET", "/api/nginx/proxy-hosts", token) or []
    desired_domains = set(desired)

    for domain, desired_payload in desired.items():
        existing = host_by_primary_domain(hosts, domain)
        if existing is None:
            created = api("POST", "/api/nginx/proxy-hosts", token, build_update_payload({}, desired_payload)) or {}
            upsert_inventory_row(inventory, "npm_proxy_host", domain, created.get("id", ""))
            print(f"Created NPM proxy host for {domain}")
            continue

        if is_managed_host(existing):
            upsert_inventory_row(inventory, "npm_proxy_host", domain, existing.get("id", ""))

        current_payload = {
            key: existing.get(key)
            for key in (
                "domain_names",
                "forward_scheme",
                "forward_host",
                "forward_port",
                "access_list_id",
                "certificate_id",
                "ssl_forced",
                "caching_enabled",
                "block_exploits",
                "allow_websocket_upgrade",
                "http2_support",
                "hsts_enabled",
                "hsts_subdomains",
                "meta",
                "advanced_config",
                "locations",
            )
        }
        update_payload = build_update_payload(existing, desired_payload)
        if current_payload != update_payload:
            api("PUT", f"/api/nginx/proxy-hosts/{existing['id']}", token, update_payload)
            action = "Updated" if is_managed_host(existing) else "Adopted"
            print(f"{action} NPM proxy host for {domain}")
        if MANAGED_MARKER in update_payload["advanced_config"]:
            upsert_inventory_row(inventory, "npm_proxy_host", domain, existing.get("id", ""))

    if not prune_managed:
        save_inventory(inventory)
        return

    hosts = api("GET", "/api/nginx/proxy-hosts", token) or []
    for host in hosts:
        domains = host.get("domain_names") or []
        primary_domain = domains[0] if domains else ""
        if not primary_domain or not is_managed_host(host) or primary_domain in desired_domains:
            continue
        api("DELETE", f"/api/nginx/proxy-hosts/{host['id']}", token)
        remove_inventory_row(inventory, "npm_proxy_host", primary_domain)
        print(f"Removed stale managed NPM proxy host for {primary_domain}")

    save_inventory(inventory)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload-dir", required=True, type=Path)
    args = parser.parse_args()

    try:
        sync_hosts(
            npm_token(),
            desired_payloads(args.payload_dir),
            truthy(env("HOMELAB_PRUNE_MANAGED_NPM_HOSTS", "false")),
        )
    except Exception as exc:  # noqa: BLE001
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
