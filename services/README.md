# Services

These folders contain the service assets copied into Proxmox LXCs by `setup-lxcs.sh`.

- `proxy`: Nginx Proxy Manager, the UI reverse proxy.
- `auth`: Authelia, the homelab SSO/OIDC provider.
- `headscale`: Headscale and Headplane, based on the `mahede` config-init pattern.

Each service owns its own compose file, startup script, `.env.example`, and render script. Runtime secrets are generated on the Proxmox host under `/root/homelab/secrets`, and rendered service folders are staged under `/root/homelab/generated` before being copied into LXCs.

After `main.sh --all`, read `/root/homelab/access.txt` on the Proxmox host for DNS records, initial credentials, Nginx Proxy Manager routes, and the `tailscale up` command.
