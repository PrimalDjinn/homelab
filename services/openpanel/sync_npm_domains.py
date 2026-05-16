#!/usr/bin/env python3
import json
import ipaddress
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


DOMAIN_RE = re.compile(r"\b(?=.{1,253}\b)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b", re.I)
MANAGED_MARKER = "# homelab-openpanel-managed"


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def truthy(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "y", "on"}


def dns_record_type(value: str) -> str:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return "CNAME"
    return "AAAA" if ip.version == 6 else "A"


def run_opencli_domains() -> set[str]:
    commands = [
        ["opencli", "domains-all", "--json"],
        ["opencli", "domains-all"],
    ]
    output = ""
    for command in commands:
        try:
            output = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)
            break
        except (FileNotFoundError, subprocess.CalledProcessError) as exc:
            output = getattr(exc, "output", "") or str(exc)
    else:
        raise RuntimeError(f"Could not read OpenPanel domains: {output}")

    domains: set[str] = set()
    try:
        parsed = json.loads(output)
        stack = [parsed]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                stack.extend(item.values())
            elif isinstance(item, list):
                stack.extend(item)
            elif isinstance(item, str):
                domains.update(match.lower() for match in DOMAIN_RE.findall(item))
    except json.JSONDecodeError:
        domains.update(match.lower() for match in DOMAIN_RE.findall(output))

    ignored = {env("OPENPANEL_CLIENT_PANEL_DOMAIN").lower(), env("OPENPANEL_ADMIN_DOMAIN").lower(), "localhost"}
    return {domain for domain in domains if domain and domain not in ignored}


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
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"NPM API {method} {path} failed with HTTP {exc.code}: {body}") from exc


def cloudflare_api(method: str, path: str, payload: dict | None = None):
    token = env("OPENPANEL_CLOUDFLARE_DNS_API_TOKEN") or env("CLOUDFLARE_DNS_API_TOKEN")
    if not token:
        raise RuntimeError("Cloudflare DNS token is not configured")

    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    if payload is not None:
        data = json.dumps(payload).encode()

    request = urllib.request.Request(f"https://api.cloudflare.com/client/v4{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"Cloudflare API {method} {path} failed with HTTP {exc.code}: {body}") from exc

    parsed = json.loads(body) if body else {}
    if not parsed.get("success", False):
        raise RuntimeError(f"Cloudflare API {method} {path} failed: {body}")
    return parsed


def domain_zone_candidates(domain: str) -> list[str]:
    parts = domain.rstrip(".").split(".")
    return [".".join(parts[index:]) for index in range(max(len(parts) - 1, 0))]


def cloudflare_zone_for_domain(domain: str) -> dict | None:
    for zone_name in domain_zone_candidates(domain):
        query = urllib.parse.urlencode({"name": zone_name, "status": "active", "per_page": "1"})
        response = cloudflare_api("GET", f"/zones?{query}")
        results = response.get("result") or []
        if results:
            return results[0]
    return None


def ensure_cloudflare_record(domain: str) -> None:
    target = env("OPENPANEL_CLOUDFLARE_DNS_TARGET")
    if not target:
        return

    zone = cloudflare_zone_for_domain(domain)
    if not zone:
        print(f"No controlled Cloudflare zone found for {domain}; skipping DNS")
        return

    record_type = dns_record_type(target)
    proxied = truthy(env("OPENPANEL_CLOUDFLARE_DNS_PROXIED", "false"))
    ttl = int(env("OPENPANEL_CLOUDFLARE_DNS_TTL", "1"))
    zone_id = zone["id"]
    query = urllib.parse.urlencode({"name": domain, "per_page": "1"})
    existing = (cloudflare_api("GET", f"/zones/{zone_id}/dns_records?{query}").get("result") or [])
    payload = {
        "type": record_type,
        "name": domain,
        "content": target,
        "ttl": ttl,
        "proxied": proxied,
    }

    if existing:
        record = existing[0]
        if (
            record.get("type") == record_type
            and record.get("content") == target
            and bool(record.get("proxied", False)) == proxied
            and int(record.get("ttl", ttl)) == ttl
        ):
            return
        cloudflare_api("PUT", f"/zones/{zone_id}/dns_records/{record['id']}", payload)
        print(f"Updated Cloudflare {record_type} record for {domain} -> {target}")
        return

    cloudflare_api("POST", f"/zones/{zone_id}/dns_records", payload)
    print(f"Created Cloudflare {record_type} record for {domain} -> {target}")


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


def proxy_payload(domain: str, port: int | None = None, scheme: str = "http") -> dict:
    return {
        "domain_names": [domain],
        "forward_scheme": scheme,
        "forward_host": env("OPENPANEL_IP"),
        "forward_port": port if port is not None else int(env("OPENPANEL_PUBLIC_BACKEND_PORT", "80")),
        "access_list_id": 0,
        "certificate_id": 0,
        "ssl_forced": False,
        "caching_enabled": False,
        "block_exploits": True,
        "allow_websocket_upgrade": True,
        "http2_support": True,
        "hsts_enabled": False,
        "hsts_subdomains": False,
        "meta": {"letsencrypt_agree": False, "dns_challenge": False},
        "advanced_config": MANAGED_MARKER,
    }


def ensure_client_panel_host(token: str) -> None:
    domain = env("OPENPANEL_CLIENT_PANEL_DOMAIN").lower()
    if not domain:
        return

    payload = proxy_payload(
        domain,
        int(env("OPENPANEL_CLIENT_PANEL_PORT", "2083")),
        env("OPENPANEL_CLIENT_PANEL_SCHEME", "http"),
    )
    ensure_proxy_host(token, domain, payload)


def ensure_proxy_host(token: str, domain: str, payload: dict | None = None) -> None:
    hosts = api("GET", "/api/nginx/proxy-hosts", token) or []
    existing = next((host for host in hosts if domain in (host.get("domain_names") or [])), None)
    if existing:
        return

    api("POST", "/api/nginx/proxy-hosts", token, payload or proxy_payload(domain))
    print(f"Created NPM proxy host for {domain}")


def main() -> int:
    required = ["NPM_EMAIL", "NPM_PASSWORD", "OPENPANEL_IP"]
    missing = [name for name in required if not env(name)]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")

    token = npm_token()
    ensure_client_panel_host(token)
    for domain in sorted(run_opencli_domains()):
        ensure_proxy_host(token, domain)
        if env("OPENPANEL_CLOUDFLARE_DNS_API_TOKEN") or env("CLOUDFLARE_DNS_API_TOKEN"):
            ensure_cloudflare_record(domain)

    if truthy(env("OPENPANEL_NPM_AUTO_CERTS", "false")):
        print("OPENPANEL_NPM_AUTO_CERTS is reserved for a later verified certificate workflow", file=sys.stderr)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"sync-openpanel-npm-domains: {exc}", file=sys.stderr)
        raise SystemExit(1)
