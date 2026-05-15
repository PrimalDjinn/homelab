server:
  host: "0.0.0.0"
  port: 3000
  base_url: "${HEADPLANE_SERVER__BASE_URL}"
  cookie_secret: "${HEADPLANE_SERVER__COOKIE_SECRET}"
  cookie_secure: true
  data_path: "/var/lib/headplane"
  info_secret: "${HEADPLANE_SERVER__INFO_SECRET}"

headscale:
  url: "${HEADSCALE_URL}"
  public_url: "${HEADSCALE_PUBLIC_URL}"
  config_path: "/shared/headscale_config.yaml"
  api_key: "${HEADSCALE_API_KEY}"
  config_strict: false
  dns_records_path: "/etc/headscale/dns_records.json"

integration:
  proc:
    enabled: false
  docker:
    enabled: true
    container_label: "me.tale.headplane.target=headscale"
    socket: "unix:///var/run/docker.sock"
  kubernetes:
    enabled: false
    pod_name: "headscale"
  agent:
    enabled: false
    pre_authkey: "${HEADPLANE_AGENT_PRE_AUTHKEY}"

oidc:
  enabled: true
  issuer: "https://${AUTH_DOMAIN}"
  headscale_api_key: "${HEADSCALE_API_KEY}"
  client_id: "headscale"
  client_secret: "${HEADSCALE_OIDC_CLIENT_SECRET}"
  use_pkce: true
  disable_api_key_login: false
  scope: "openid email profile groups"
