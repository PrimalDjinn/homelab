#!/usr/bin/env python3
import json
import ipaddress
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


DOMAIN_RE = re.compile(r"\b(?=.{1,253}\b)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b", re.I)
MANAGED_MARKER = "# homelab-dokploy-managed"
DNS_MANAGED_COMMENT = "homelab-dokploy-managed"
CLOUDFLARE_ZONES_CACHE: list[dict] | None = None


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def truthy(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "y", "on"}


def http_timeout() -> int:
    return int(env("DOKPLOY_SYNC_HTTP_TIMEOUT", "180"))


def csv_env(name: str) -> list[str]:
    return [item.strip().lower().rstrip(".") for item in env(name).split(",") if item.strip()]


def is_domain(value: str) -> bool:
    return bool(DOMAIN_RE.fullmatch(value.strip().lower().rstrip(".")))


def dns_record_type(value: str) -> str:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return "CNAME"
    return "AAAA" if ip.version == 6 else "A"


def request_json(method: str, url: str, headers: dict[str, str], payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=http_timeout()) as response:
            body = response.read().decode()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"{method} {url} failed with HTTP {exc.code}: {body}") from exc
    return json.loads(body) if body else None


def dokploy_api(method: str, path: str, payload: dict | None = None):
    base_url = env("DOKPLOY_URL", "http://127.0.0.1:3000").rstrip("/")
    token = env("DOKPLOY_API_TOKEN")
    if not token:
        raise RuntimeError("DOKPLOY_API_TOKEN is not configured")
    return request_json(
        method,
        f"{base_url}{path}",
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        payload,
    )


def npm_api(method: str, path: str, token: str = "", payload: dict | None = None):
    base_url = env("NPM_URL", "http://127.0.0.1:81").rstrip("/")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return request_json(method, f"{base_url}{path}", headers, payload)


def cloudflare_api(method: str, path: str, payload: dict | None = None):
    token = env("DOKPLOY_CLOUDFLARE_DNS_API_TOKEN") or env("CLOUDFLARE_DNS_API_TOKEN")
    if not token:
        raise RuntimeError("Cloudflare DNS token is not configured")
    parsed = request_json(
        method,
        f"https://api.cloudflare.com/client/v4{path}",
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        payload,
    ) or {}
    if not parsed.get("success", False):
        raise RuntimeError(f"Cloudflare API {method} {path} failed: {json.dumps(parsed)}")
    return parsed


def items_from_response(value) -> list[dict]:
    found: list[dict] = []
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            if item.get("applicationId") or item.get("composeId") or item.get("domainId"):
                found.append(item)
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
    return found


def paged_search(path: str, id_key: str) -> list[dict]:
    results: dict[str, dict] = {}
    limit = 100
    offset = 0
    while True:
        query = urllib.parse.urlencode({"limit": str(limit), "offset": str(offset)})
        response = dokploy_api("GET", f"{path}?{query}")
        items = [item for item in items_from_response(response) if item.get(id_key)]
        for item in items:
            results[str(item[id_key])] = item
        if len(items) < limit:
            break
        offset += limit
    return list(results.values())


def dokploy_domains() -> set[str]:
    domains: set[str] = set()
    ignored = {env("DOKPLOY_DOMAIN").lower().rstrip(".")}

    for app in paged_search("/application.search", "applicationId"):
        query = urllib.parse.urlencode({"applicationId": app["applicationId"]})
        for domain in items_from_response(dokploy_api("GET", f"/domain.byApplicationId?{query}")):
            host = str(domain.get("host") or "").lower().rstrip(".")
            if is_domain(host) and host not in ignored:
                domains.add(host)

    for compose in paged_search("/compose.search", "composeId"):
        query = urllib.parse.urlencode({"composeId": compose["composeId"]})
        for domain in items_from_response(dokploy_api("GET", f"/domain.byComposeId?{query}")):
            host = str(domain.get("host") or "").lower().rstrip(".")
            if is_domain(host) and host not in ignored:
                domains.add(host)

    return domains


def npm_token() -> str:
    response = npm_api(
        "POST",
        "/api/tokens",
        payload={"identity": env("NPM_EMAIL"), "secret": env("NPM_PASSWORD")},
    )
    token = (response or {}).get("token", "")
    if not token:
        raise RuntimeError("NPM login returned no token")
    return token


def proxy_payload(domain: str) -> dict:
    return {
        "domain_names": [domain],
        "forward_scheme": env("DOKPLOY_NPM_FORWARD_SCHEME", "http"),
        "forward_host": env("DOKPLOY_IP"),
        "forward_port": int(env("DOKPLOY_NPM_FORWARD_PORT", "80")),
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


def build_update_payload(existing: dict, desired: dict) -> dict:
    advanced = existing.get("advanced_config") or ""
    if MANAGED_MARKER not in advanced:
        advanced = "\n".join(item for item in (advanced, MANAGED_MARKER) if item)
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
        "advanced_config": advanced,
        "locations": existing.get("locations") or [],
    }


def ensure_npm_hosts(token: str, desired_domains: set[str]) -> None:
    hosts = npm_api("GET", "/api/nginx/proxy-hosts", token) or []
    for domain in sorted(desired_domains):
        desired = proxy_payload(domain)
        existing = next((host for host in hosts if domain in (host.get("domain_names") or [])), None)
        if existing is None:
            npm_api("POST", "/api/nginx/proxy-hosts", token, desired)
            print(f"Created NPM proxy host for {domain}")
            continue
        update_payload = build_update_payload(existing, desired)
        current_payload = {key: existing.get(key) for key in update_payload}
        if current_payload != update_payload:
            npm_api("PUT", f"/api/nginx/proxy-hosts/{existing['id']}", token, update_payload)
            print(f"Updated NPM proxy host for {domain}")

    hosts = npm_api("GET", "/api/nginx/proxy-hosts", token) or []
    for host in hosts:
        domains = host.get("domain_names") or []
        primary_domain = domains[0] if domains else ""
        if not primary_domain or primary_domain in desired_domains:
            continue
        if MANAGED_MARKER not in (host.get("advanced_config") or ""):
            continue
        npm_api("DELETE", f"/api/nginx/proxy-hosts/{host['id']}", token)
        print(f"Removed stale managed NPM proxy host for {primary_domain}")


def domain_matches_zone(domain: str, zone_name: str) -> bool:
    domain = domain.lower().rstrip(".")
    zone_name = zone_name.lower().rstrip(".")
    return domain == zone_name or domain.endswith(f".{zone_name}")


def cloudflare_controlled_zones() -> list[dict]:
    global CLOUDFLARE_ZONES_CACHE
    if CLOUDFLARE_ZONES_CACHE is not None:
        return CLOUDFLARE_ZONES_CACHE

    allowed = set(csv_env("DOKPLOY_CLOUDFLARE_DNS_ZONES"))
    zones: list[dict] = []
    page = 1
    while True:
        query = urllib.parse.urlencode({"status": "active", "per_page": "50", "page": str(page)})
        response = cloudflare_api("GET", f"/zones?{query}")
        for zone in response.get("result") or []:
            name = (zone.get("name") or "").lower().rstrip(".")
            if name and (not allowed or name in allowed):
                zones.append(zone)
        result_info = response.get("result_info") or {}
        total_pages = int(result_info.get("total_pages") or page)
        if page >= total_pages:
            break
        page += 1

    CLOUDFLARE_ZONES_CACHE = sorted(zones, key=lambda item: len(item.get("name") or ""), reverse=True)
    return CLOUDFLARE_ZONES_CACHE


def cloudflare_zone_for_domain(domain: str) -> dict | None:
    return next((zone for zone in cloudflare_controlled_zones() if domain_matches_zone(domain, zone.get("name") or "")), None)


def ensure_cloudflare_record(domain: str) -> None:
    target = env("DOKPLOY_CLOUDFLARE_DNS_TARGET")
    if not target:
        return
    zone = cloudflare_zone_for_domain(domain)
    if not zone:
        print(f"No controlled Cloudflare zone found for {domain}; skipping DNS")
        return

    record_type = dns_record_type(target)
    proxied = truthy(env("DOKPLOY_CLOUDFLARE_DNS_PROXIED", "false"))
    ttl = int(env("DOKPLOY_CLOUDFLARE_DNS_TTL", "1"))
    zone_id = zone["id"]
    query = urllib.parse.urlencode({"name": domain, "per_page": "1"})
    existing = cloudflare_api("GET", f"/zones/{zone_id}/dns_records?{query}").get("result") or []
    managed_record = next((record for record in existing if record.get("comment") == DNS_MANAGED_COMMENT), None)
    payload = {"type": record_type, "name": domain, "content": target, "ttl": ttl, "proxied": proxied, "comment": DNS_MANAGED_COMMENT}

    if managed_record:
        cloudflare_api("PUT", f"/zones/{zone_id}/dns_records/{managed_record['id']}", payload)
        print(f"Updated Cloudflare {record_type} record for {domain} -> {target}")
        return
    if existing:
        record = existing[0]
        if record.get("type") == record_type and record.get("content") == target and bool(record.get("proxied", False)) == proxied:
            cloudflare_api("PUT", f"/zones/{zone_id}/dns_records/{record['id']}", payload)
            print(f"Adopted existing Cloudflare {record_type} record for {domain} -> {target}")
        else:
            print(f"Cloudflare DNS record for {domain} exists but is not homelab-managed; leaving it untouched")
        return
    cloudflare_api("POST", f"/zones/{zone_id}/dns_records", payload)
    print(f"Created Cloudflare {record_type} record for {domain} -> {target}")


def managed_cloudflare_records() -> list[tuple[str, dict]]:
    records = []
    for zone in cloudflare_controlled_zones():
        zone_id = zone["id"]
        page = 1
        while True:
            query = urllib.parse.urlencode({"per_page": "100", "page": str(page)})
            response = cloudflare_api("GET", f"/zones/{zone_id}/dns_records?{query}")
            records.extend((zone_id, record) for record in response.get("result") or [] if record.get("comment") == DNS_MANAGED_COMMENT)
            result_info = response.get("result_info") or {}
            total_pages = int(result_info.get("total_pages") or page)
            if page >= total_pages:
                break
            page += 1
    return records


def sync_cloudflare(desired_domains: set[str]) -> None:
    for domain in sorted(desired_domains):
        ensure_cloudflare_record(domain)
    for zone_id, record in managed_cloudflare_records():
        domain = (record.get("name") or "").lower().rstrip(".")
        if not domain or domain in desired_domains:
            continue
        cloudflare_api("DELETE", f"/zones/{zone_id}/dns_records/{record['id']}")
        print(f"Removed stale managed Cloudflare DNS record for {domain}")


def main() -> int:
    required = ["DOKPLOY_API_TOKEN", "DOKPLOY_IP", "NPM_EMAIL", "NPM_PASSWORD"]
    missing = [name for name in required if not env(name)]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")

    desired_domains = dokploy_domains()
    token = npm_token()
    ensure_npm_hosts(token, desired_domains)
    if env("DOKPLOY_CLOUDFLARE_DNS_API_TOKEN") or env("CLOUDFLARE_DNS_API_TOKEN"):
        sync_cloudflare(desired_domains)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"sync-dokploy-npm-domains: {exc}", file=sys.stderr)
        raise SystemExit(1)
