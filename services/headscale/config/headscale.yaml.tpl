server_url: "${SERVER_URL}"
listen_addr: "0.0.0.0:8080"
metrics_listen_addr: "127.0.0.1:9090"
grpc_listen_addr: "127.0.0.1:50443"
grpc_allow_insecure: false

noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
allocation: sequential

derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: true
  update_frequency: 3h

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true

log:
  level: info
  format: text

policy:
  mode: database

dns:
  magic_dns: true
  base_domain: ${DNS_BASE_DOMAIN}
  override_local_dns: true
  nameservers:
    global:
      - 1.1.1.1
      - 1.0.0.1
  search_domains: []
  extra_records_path: /etc/headscale/dns_records.json

unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"

oidc:
  only_start_if_oidc_is_available: false
  issuer: "https://${AUTH_DOMAIN}"
  client_id: "headscale"
  client_secret: "${HEADSCALE_OIDC_CLIENT_SECRET}"
  expiry: 180d
  scope: ["openid", "profile", "email", "groups"]
  email_verified_required: false
  allowed_groups:
    - headscale
  pkce:
    enabled: true
    method: S256

logtail:
  enabled: false

randomize_client_port: false
taildrop:
  enabled: true
