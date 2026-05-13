# Nginx Proxy Manager

This LXC runs the official Nginx Proxy Manager Docker Compose stack.

Initial UI:

- `http://<proxy-lxc-ip>:81`
- NPM's upstream default first-run login is usually `admin@example.com` / `changeme`.
- The installer uses `NPM_ADMIN_EMAIL` and `NPM_DEFAULT_PASSWORD` from the root `.env` when trying to seed proxy hosts.
- Change the NPM admin account immediately after first login.

Recommended proxy hosts:

- `auth.<domain>` -> `http://<auth-lxc-ip>:9091`
- `headscale.<domain>` -> `http://<headscale-lxc-ip>:8080`
- `headplane.<domain>` -> `http://<headscale-lxc-ip>:3000`

Request Let's Encrypt certificates in the NPM UI after DNS points at the Proxmox host.
