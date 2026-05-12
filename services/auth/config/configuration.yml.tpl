server:
  address: tcp://0.0.0.0:9091/

log:
  level: info

theme: auto

identity_validation:
  reset_password:
    jwt_secret: "${AUTHELIA_JWT_SECRET}"

authentication_backend:
  file:
    path: /config/users_database.yml

access_control:
  default_policy: deny
  rules:
    - domain:
        - "${AUTH_DOMAIN}"
      policy: one_factor
    - domain:
        - "${HEADPLANE_DOMAIN}"
      policy: one_factor

session:
  secret: "${AUTHELIA_SESSION_SECRET}"
  cookies:
    - domain: "${DOMAIN}"
      authelia_url: "https://${AUTH_DOMAIN}"
      default_redirection_url: "https://${HEADPLANE_DOMAIN}"

regulation:
  max_retries: 5
  find_time: 2m
  ban_time: 10m

storage:
  encryption_key: "${AUTHELIA_STORAGE_KEY}"
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notification.txt

identity_providers:
  oidc:
    hmac_secret: "${AUTHELIA_OIDC_HMAC_SECRET}"
    jwks:
      - key: |
${AUTHELIA_OIDC_PRIVATE_KEY_INDENTED}
    claims_policies:
      headscale:
        id_token: ['email', 'groups']
    clients:
      - client_id: headscale
        client_name: Headscale and Headplane
        client_secret: "${HEADSCALE_OIDC_CLIENT_SECRET_HASH}"
        claims_policy: headscale
        public: false
        authorization_policy: one_factor
        require_pkce: true
        pkce_challenge_method: S256
        redirect_uris:
          - "https://${HEADSCALE_DOMAIN}/oidc/callback"
          - "https://${HEADPLANE_DOMAIN}/admin/oidc/callback"
        scopes:
          - openid
          - email
          - profile
          - groups
        response_types:
          - code
        grant_types:
          - authorization_code
        access_token_signed_response_alg: none
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
