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

The installer can bootstrap Dokploy API access for the sync. If
`DOKPLOY_API_TOKEN` is empty, it attempts the self-hosted first-run signup flow
with `DOKPLOY_ADMIN_EMAIL` and `DOKPLOY_ADMIN_PASSWORD`, signs in with those
credentials, creates an API key, and stores it under
`/root/homelab/secrets/dokploy-api-key`. If an owner already exists, the same
credentials must match that user so setup can sign in and create the API key.

When an API key is available, the installer enables a periodic sync from Dokploy
domains to Nginx Proxy Manager and Cloudflare:

- Dokploy Application and Docker Compose domains are read through Dokploy's API.
- NPM proxy hosts are marked with `# homelab-dokploy-managed`.
- Cloudflare DNS records are marked with the `homelab-dokploy-managed` record comment.
- Stale NPM hosts and Cloudflare records are removed only when they carry those managed markers.

Cloudflare sync requires `DOKPLOY_CLOUDFLARE_DNS_API_TOKEN` or a shared fallback
token. If the Dokploy-specific token is empty, setup uses `CLOUDFLARE_DNS_API_TOKEN`,
then `NPM_CLOUDFLARE_DNS_API_TOKEN`, then `STALWART_ACME_DNS_CF_SECRET`.

By default, synced NPM hosts forward to Dokploy's internal Traefik at
`http://<dokploy-ip>:80`. Override with `DOKPLOY_NPM_FORWARD_SCHEME` and
`DOKPLOY_NPM_FORWARD_PORT` if your Dokploy domain setup requires a different
internal route.
