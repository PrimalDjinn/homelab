# Authelia

This service is the auth and OIDC provider for the homelab.

It starts with a file-backed user database and one admin user. The installer renders:

- `config/configuration.yml`
- `config/users_database.yml`

Headscale and Headplane share the `headscale` OIDC client.
