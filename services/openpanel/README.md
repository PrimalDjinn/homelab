# OpenPanel

This service provisions an OpenPanel Community Edition LXC and keeps public
client domains attached to Nginx Proxy Manager.

Design:

- OpenAdmin stays internal-only.
- OpenPanel client login can be public through Nginx Proxy Manager.
- Hosted client domains are exposed only through Nginx Proxy Manager.
- Nginx Proxy Manager is the only public TLS/certificate layer.

The domain sync is intentionally conservative. It creates missing NPM proxy
hosts for domains reported by `opencli`, but it does not delete proxy hosts.
Certificates are left to NPM; automatic certificate creation can be enabled
with `OPENPANEL_NPM_AUTO_CERTS=true` after DNS behavior is verified.
