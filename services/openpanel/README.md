# OpenPanel

This service contains integration assets for OpenPanel Community Edition and
keeps public client domains attached to Nginx Proxy Manager.

OpenPanel upstream explicitly does not support installation inside containers
or LXCs. The homelab installer creates a dedicated VM. By default it imports an
Ubuntu cloud image and uses Proxmox cloud-init for unattended SSH/network setup,
then installs OpenPanel over SSH once the OS is reachable.

The ISO path is still available with `OPENPANEL_VM_INSTALL_METHOD=iso`, but
Ubuntu live-server requires `autoinstall` on the installer kernel command line.

Design:

- OpenAdmin stays internal-only.
- OpenPanel client login can be public through Nginx Proxy Manager.
- Hosted client domains are exposed only through Nginx Proxy Manager.
- Nginx Proxy Manager is the only public TLS/certificate layer.

The domain sync is intentionally conservative. It creates missing NPM proxy
hosts for domains reported by `opencli`, but it does not delete proxy hosts.
It also requests and attaches per-domain NPM Let's Encrypt certificates by
default. Disable that with `OPENPANEL_NPM_AUTO_CERTS=false` if you want to
manage certificates manually.

When `OPENPANEL_CLOUDFLARE_DNS_API_TOKEN` (or the shared
`CLOUDFLARE_DNS_API_TOKEN`) is set, the same sync also attempts to create or
update Cloudflare DNS records for OpenPanel user domains. Each sync lists the
active zones visible to the token once, matches OpenPanel domains locally, and
only upserts records for matching zones. Domains outside controlled zones are
added to NPM but are not sent to Cloudflare as DNS record operations. Set
`OPENPANEL_CLOUDFLARE_DNS_ZONES` only when you want to restrict the token's
visible zones further. Records point to `OPENPANEL_CLOUDFLARE_DNS_TARGET`, or
the detected Proxmox public IP when that value is empty. The token needs
`Zone:Read` and `DNS:Edit` permissions.
