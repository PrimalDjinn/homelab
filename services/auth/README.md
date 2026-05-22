# Authentik

This service is the auth and OIDC provider for the homelab.

The installer renders an Authentik Docker Compose stack with PostgreSQL and Redis.
It can seed the initial bootstrap user with:

- `AUTHENTIK_BOOTSTRAP_EMAIL`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_TOKEN`

The Authentik web UI listens on `9000` internally and is exposed through Nginx
Proxy Manager at `auth.<domain>`.

Headscale and Headplane expect an Authentik OAuth2/OpenID provider with slug
`headscale`, client ID `headscale`, and the generated shared client secret from
`/root/homelab/secrets/oidc-headscale-client-secret`. The issuer defaults to:

```text
https://auth.<domain>/application/o/headscale/
```
