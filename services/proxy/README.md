# Nginx Proxy Manager

This LXC runs the official Nginx Proxy Manager Docker Compose stack.

Initial UI:

- `http://<proxy-lxc-ip>:81`
- The installer seeds the initial admin account with `NPM_ADMIN_EMAIL` and `NPM_PASSWORD` from the root `.env`.
- If `NPM_PASSWORD` is empty, the installer generates one under `/root/homelab/secrets/npm-admin-password`.

Recommended proxy hosts:

- `auth.<domain>` -> `http://<auth-lxc-ip>:9091`
- `headscale.<domain>` -> `http://<headscale-lxc-ip>:8080`
- `headplane.<domain>` -> `http://<headscale-lxc-ip>:3000`

Request Let's Encrypt certificates in the NPM UI after DNS points at the Proxmox host.
