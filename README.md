# Homelab

## Notes to self

1. **Proxmox** — First, set up Proxmox on a Debian VPS/VM/wherever — as long as the provider allows virtualisation, all should be well. The script supports Debian 13 Trixie / Proxmox VE 9 using the current deb822 repository flow from the [Proxmox VE on Debian 13 Trixie wiki](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie), while still keeping the Debian 12 Bookworm path for existing hosts.

2. **Subnet** — Then set up a subnet. Most providers will give a single IP, so subnetting for isolation and sharing is crucial.

3. **Reverse proxy** — Then set up a reverse proxy LXC using Nginx Proxy Manager for the UI. The Proxmox host forwards public `80`/`443` to this LXC; service ports stay on the internal bridge.

4. **Auth** — Then set up an auth LXC using Authentik as the OIDC provider.

5. **Headscale** — Next, set up Headscale and Headplane in their own LXC, using the config-init/shared-config pattern from [PrimalDjinn/mahede](https://github.com/PrimalDjinn/mahede).

6. **Dokploy** — Dokploy is provisioned as its own high-resource LXC and exposed through the internal Headscale/NPM path at `dokploy.<domain>`.

## Quick start

Copy `.env.example` to `.env`, set the real domain/IP choices, then run:

```sh
sudo ./main.sh --all
```

After provisioning, read `/root/homelab/access.txt` on the Proxmox host for initial credentials, DNS records, Nginx Proxy Manager routes, and the generated `tailscale up` command.

## Networking and access

### Headscale

Headscale keeps its public server URL as `https://headscale.<domain>`. Internal service-to-service traffic uses direct internal addresses — for example, Headplane talks to `http://headscale:8080` and the proxy LXC joins Headscale through `http://<headscale-lxc-ip>:8080`.

### Proxmox UI lockdown

The Proxmox web UI on port `8006` is closed to the public by default when `setup-subnet.sh` manages the Proxmox host firewall.

1. Keep `HOMELAB_PUBLIC_PROXMOX_8006=false`.
2. Join the Proxmox host to Headscale with `sudo ./setup-proxmox-tailnet.sh`.
3. Confirm tailnet access works.
4. Run `sudo ./lockdown-proxmox-8006.sh` to install explicit tailnet-only rules for `8006`.

`setup-proxmox-tailnet.sh` joins with `--accept-routes=false`. The proxy LXC
advertises `$HOMELAB_NETWORK_PREFIX.0/24` into the tailnet for remote clients;
if the Proxmox host accepts that route, return traffic for local LXCs is stolen
onto `tailscale0` and NAT/bridge connectivity breaks (LXCs can no longer reach
the gateway or the internet).

## Mail and Stalwart

The mail app starts with `EMAIL_PROVIDER=nodemailer` and placeholder SMTP credentials so its startup validation passes before the real Stalwart mailbox exists.

Mailbox addresses use `STALWART_DEFAULT_DOMAIN` (derived from `MAIL_DOMAIN` without the `mail.` prefix when unset), e.g. `noreply@heylomeet.com` for `MAIL_DOMAIN=mail.heylomeet.com`.

After a developer creates the sending account in Stalwart, wire the mail API SMTP from the Proxmox host:

```sh
# Account already exists in Stalwart with a known password:
sudo ./configure-mail-smtp.sh \
  --user noreply@heylomeet.com \
  --pass 'real-password' \
  --from noreply@heylomeet.com

# Or generate a password, then create the Stalwart mailbox to match:
sudo ./configure-mail-smtp.sh --user noreply@heylomeet.com --generate-pass
```

Inside the mail LXC the same step is:

```sh
sudo pct exec 113 -- bash -lc "/opt/email-service/update-smtp-credentials.sh \
  --user noreply@heylomeet.com \
  --pass 'real-password' \
  --from noreply@heylomeet.com"
```

Stalwart runs on the current `config.json` startup model. The homelab override ports ChibaLLC's env-driven Stalwart setup into:

- `/etc/stalwart/config.json`
- `/etc/stalwart/bootstrap.json`
- `/etc/stalwart/apply-plan.ndjson`

It persists `/etc/stalwart` and `/var/lib/stalwart`, and starts Stalwart with `--config /etc/stalwart/config.json`.

If Stalwart has stale or incomplete config after env changes, regenerate and restart it with:

```sh
sudo pct exec 113 -- bash -lc "/opt/email-service/regenerate-stalwart-config.sh"
```

> **TODO:** Investigate why the new way of generating configs may not work.

## Reset (testing)

During testing, reset managed service resources with:

```sh
sudo ./reset.sh --yes
```

- Add `--network` to remove the internal bridge/NAT/dnsmasq config.
- Add `--proxmox` to clear Proxmox setup markers and restore `/etc/hosts` from the setup backup.

`reset.sh` removes homelab-managed LXCs, state, firewall rules, and optionally the internal network, but it does **not** repair a broken Proxmox installation. Fix `pve-cluster`/`/etc/pve` first, then rerun `sudo ./main.sh --all`.

## Troubleshooting

### LXCs cannot ping gateway or the internet

Symptoms:

- `ping 10.10.10.1` and `ping 1.1.1.1` fail inside LXCs
- Host can still ping LXC IPs
- `tcpdump` shows replies leaving via `tailscale0` instead of `vmbr10`

Cause: the Proxmox host accepted the proxy's advertised `10.10.10.0/24` Tailscale
route (`RouteAll: true`), so local bridge return traffic is misrouted.

Fix on the Proxmox host:

```sh
sudo tailscale set --accept-routes=false
ip route get 10.10.10.40   # should show dev vmbr10, not tailscale0
sudo pct exec 113 -- ping -c2 1.1.1.1
```

Also ensure the host firewall trusts the internal bridge (`IN ACCEPT -i vmbr10`
from `setup-subnet.sh`).

This is **not** a Stalwart IP ban. Stalwart bans would still allow gateway/DNS
reachability.

### Proxmox installed but `/etc/pve` is unavailable

The scripts need Proxmox to be both installed and operational. A host can reach an inconsistent state where Proxmox packages are installed, so `setup-proxmox.sh` reports that Proxmox is already installed, but the Proxmox config filesystem is not mounted:

```text
Proxmox config filesystem is unavailable at /etc/pve/nodes
unable to open file '/etc/pve/nodes/<node>/lxc/<id>.conf.tmp...' - No such file or directory
```

This usually means `pve-cluster`/`pmxcfs` is not healthy. Do **not** create `/etc/pve/nodes` manually; Proxmox owns that filesystem.

Check the host:

```sh
sudo systemctl status pve-cluster --no-pager -l
sudo journalctl -u pve-cluster -n 120 --no-pager
ls -ld /etc/pve /etc/pve/nodes
hostname
hostname -f
getent hosts "$(hostname)"
cat /etc/hosts
```

Try restarting the Proxmox services:

```sh
sudo systemctl restart pve-cluster
sudo systemctl restart pvedaemon pveproxy pvestatd
ls -ld /etc/pve/nodes/$(hostname)/lxc
```

If `/etc/pve/nodes` still does not appear, complete or repair the Proxmox install before rerunning the homelab scripts:

```sh
sudo DEBIAN_FRONTEND=noninteractive apt install -y proxmox-ve postfix open-iscsi chrony
sudo systemctl enable --now pve-cluster pvedaemon pveproxy pvestatd
sudo systemctl restart pve-cluster
```

Also verify `/etc/hosts` maps the hostname to a real host IP. Proxmox services can fail when the node hostname cannot resolve cleanly.

### `DNS resolution error: no connections available`

This usually means a container resolved AAAA records, but the parent LXC still has no usable IPv6 route.

Test IPv6 on the Proxmox host:

```sh
ping -6 google.com
curl -6 https://google.com
```

Test IPv6 inside the affected LXC:

```sh
sudo pct enter 113
ping -6 google.com
curl -6 https://google.com
```

If the host has working IPv6 but the LXC reports `Network is unreachable`, leave IPv6 disabled for now. The homelab scripts now prefer IPv4 explicitly for LXC package installs and Docker/container DNS defaults.

After applying the updated scripts, restart the affected Docker stack so it picks up the IPv4-safe DNS settings:

```sh
sudo pct exec 113 -- bash -lc "cd /opt/email-service && docker compose -f ./docker-compose.prod.yml -f ./docker-compose.homelab.yml --env-file .env up -d --force-recreate"
```

## Managed NPM and DNS

Homelab-created Nginx Proxy Manager hosts are marked with `# homelab-managed` in `advanced_config` and tracked in a CSV inventory inside the proxy LXC.

Reruns reconcile those homelab hosts in place. If you want stale homelab-managed proxy hosts removed automatically, enable:

```sh
HOMELAB_PRUNE_MANAGED_NPM_HOSTS=true
```

Only hosts carrying the homelab managed marker are eligible for auto-removal. Unrelated NPM hosts are left untouched.

OpenPanel's domain sync keeps its own CSV inventory for both managed NPM proxy hosts and managed Cloudflare DNS records. That inventory is used to remove only resources previously created or adopted by the sync.

## Dokploy

Dokploy is installed in LXC `115` by default at `10.10.10.60`. It uses all host CPU cores by default and gets the remaining auto-calculated memory after reserving RAM for the host, core LXCs, mail, and a smaller OpenPanel VM budget.

The `dokploy.<domain>` route is internal/tailnet-oriented like `openadmin.<domain>`:

- Headscale DNS points `dokploy.<domain>` at the proxy tailnet IP.
- Nginx Proxy Manager forwards `dokploy.<domain>` to `http://10.10.10.60:3000`.
- The installer does not include `dokploy.<domain>` in the public Let's Encrypt SAN set by default.
