# Headscale + Headplane

Headscale and Headplane run together in this LXC with Docker Compose, following the same shape as `PrimalDjinn/mahede`.

The `config-init` service renders:

- `headscale_config.yml` -> shared `/shared/headscale_config.yaml`
- `headplane_config.yml` -> shared `/shared/headplane_config.yaml`

No lockfile is used. The init container is a tiny dependency-free Node script.

Nginx Proxy Manager should route:

- `headscale.<domain>` -> `http://<headscale-lxc-ip>:8080`
- `headplane.<domain>` -> `http://<headscale-lxc-ip>:3000`

Headscale also serves a tailnet-only DNS record for `openadmin.<domain>` via
`dns_records.json`. During provisioning, the setup queries Headscale for the
Nginx Proxy Manager node's assigned tailnet IPv4 and writes `openadmin.<domain>`
to that address so admin access works only for tailnet clients, while NPM
forwards the request to the OpenPanel VM. Use the tailnet IP rather than the
proxy LXC's `10.10.10.x` address because a subnet router may not reliably serve
its own LAN IP through the route it advertises. Do not publish a public DNS
record for `openadmin.<domain>` unless you intentionally want the OpenPanel admin
surface on the public internet.
