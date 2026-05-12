users:
  ${AUTH_ADMIN_USER}:
    displayname: Homelab Admin
    password: "${AUTH_ADMIN_PASSWORD_HASH}"
    email: "${AUTH_ADMIN_EMAIL}"
    groups:
      - admins
      - headscale
