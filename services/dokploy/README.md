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
