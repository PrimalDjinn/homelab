# OpenPanel

This service contains integration assets for OpenPanel Community Edition and
keeps public client domains attached to Nginx Proxy Manager.

OpenPanel upstream explicitly does not support installation inside containers
or LXCs. The homelab installer creates a dedicated VM, selects a Debian/Ubuntu
ISO from Proxmox ISO storage, attaches a generated seed ISO, and then installs
OpenPanel over SSH once the OS is reachable.

If the selected installer ISO does not consume the generated unattended seed,
complete the OS install manually with the configured static IP and rerun
`setup-lxcs.sh`; it will continue from the SSH/OpenPanel install step.

Design:

- OpenAdmin stays internal-only.
- OpenPanel client login can be public through Nginx Proxy Manager.
- Hosted client domains are exposed only through Nginx Proxy Manager.
- Nginx Proxy Manager is the only public TLS/certificate layer.

The domain sync is intentionally conservative. It creates missing NPM proxy
hosts for domains reported by `opencli`, but it does not delete proxy hosts.
Certificates are left to NPM; automatic certificate creation can be enabled
with `OPENPANEL_NPM_AUTO_CERTS=true` after DNS behavior is verified.
