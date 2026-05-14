# Mail LXC

This LXC runs the full Chiba email-service production stack from:

- `https://github.com/ChibaLLC/email-service`

The homelab installer clones the repo into `/opt/email-service`, renders its
`.env`, adds a tiny override that publishes Stalwart HTTP on LXC port `8080`
for Nginx Proxy Manager, and starts the upstream production compose stack:

```sh
docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d
```

The Proxmox host forwards public mail protocol ports directly to the mail LXC:

- `25`, `587`, `465`, `143`, `993`, `110`, `995`, `4190`

Stalwart DNS-01 ACME uses `STALWART_ACME_DNS_CF_SECRET` when set. If it is
blank, the generated email-service `.env` falls back to
`CLOUDFLARE_DNS_API_TOKEN`.
