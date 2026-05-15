# Services

These folders contain the service assets copied into Proxmox LXCs by `setup-lxcs.sh`.

- `proxy`: Nginx Proxy Manager, the UI reverse proxy.
- `auth`: Authelia, the homelab SSO/OIDC provider.
- `headscale`: Headscale and Headplane, based on the `mahede` config-init pattern.
- `mail`: email-service with Stalwart, webmail, Listmonk, Postal, and LibreDesk.
- `openpanel`: OpenPanel Community Edition plus OpenPanel-to-NPM domain sync.

The root `.env` is the source of truth. Service `.env.example` files document the variables each service consumes; render scripts produce runtime `.env` files under `/root/homelab/generated` before copying them into LXCs.

After `main.sh --all`, read `/root/homelab/access.txt` on the Proxmox host for DNS records, initial credentials, Nginx Proxy Manager routes, and the `tailscale up` command.
