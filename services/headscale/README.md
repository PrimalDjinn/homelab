# Headscale + Headplane

Headscale and Headplane run together in this LXC with Docker Compose, following the same shape as `PrimalDjinn/mahede`.

The `config-init` service renders:

- `headscale_config.yml` -> shared `/shared/headscale_config.yaml`
- `headplane_config.yml` -> shared `/shared/headplane_config.yaml`

No lockfile is used. The init container is a tiny dependency-free Node script.

Nginx Proxy Manager should route:

- `headscale.<domain>` -> `http://<headscale-lxc-ip>:8080`
- `headplane.<domain>` -> `http://<headscale-lxc-ip>:3000`
