# Dokploy

Dokploy is provisioned as a dedicated high-resource LXC.

Defaults:

- CTID: `115`
- IP: `10.10.10.60`
- Domain: `dokploy.<domain>`
- Port: `3000`
- Installer: `https://dokploy.com/install.sh`

The route is intended for internal/tailnet access, like `openadmin.<domain>`.
Headscale DNS points `dokploy.<domain>` to the proxy tailnet IP and Nginx Proxy
Manager forwards traffic to the Dokploy LXC.

When `DOKPLOY_API_TOKEN` is set from a Dokploy dashboard API key, the installer
also enables a periodic sync from Dokploy domains to Nginx Proxy Manager and
Cloudflare:

- Dokploy Application and Docker Compose domains are read through Dokploy's API.
- NPM proxy hosts are marked with `# homelab-dokploy-managed`.
- Cloudflare DNS records are marked with the `homelab-dokploy-managed` record comment.
- Stale NPM hosts and Cloudflare records are removed only when they carry those managed markers.

By default, synced NPM hosts forward to Dokploy's internal Traefik at
`http://<dokploy-ip>:80`. Override with `DOKPLOY_NPM_FORWARD_SCHEME` and
`DOKPLOY_NPM_FORWARD_PORT` if your Dokploy domain setup requires a different
internal route.
