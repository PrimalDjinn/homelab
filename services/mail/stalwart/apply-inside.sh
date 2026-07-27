#!/bin/sh
set -eu

apk add --no-cache ca-certificates curl jq >/dev/null
curl --proto "=https" --tlsv1.2 -LsSf \
  https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh >/dev/null

CLI=/root/.cargo/bin/stalwart-cli
URL=http://stalwart:8080
domain="${STALWART_DEFAULT_DOMAIN:?STALWART_DEFAULT_DOMAIN is required}"
hostname="${STALWART_HOSTNAME:?STALWART_HOSTNAME is required}"
plan_in="${PLAN_FILE:-/plan.ndjson}"

cli() {
  "$CLI" --url "$URL" --user "$STALWART_ADMIN_USER" --password "$STALWART_ADMIN_PASSWORD" --no-color "$@"
}

domain_id="$(
  cli query Domain --where "name=${domain}" --fields id,name --json 2>/dev/null \
    | jq -r 'if type == "array" then (.[0].id // empty) else (.id // empty) end'
)"

if [ -z "${domain_id}" ] || [ "${domain_id}" = "null" ]; then
  cli create Domain --json "$(jq -nc --arg name "$domain" '{name:$name, isEnabled:true}')" >/dev/null
  domain_id="$(
    cli query Domain --where "name=${domain}" --fields id --json \
      | jq -r 'if type == "array" then (.[0].id // empty) else (.id // empty) end'
  )"
fi

if [ -z "${domain_id}" ] || [ "${domain_id}" = "null" ]; then
  echo "error: failed to resolve Stalwart Domain id for ${domain}" >&2
  exit 1
fi

rewritten="$(mktemp)"
trap 'rm -f "$rewritten"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line" | jq -c \
    --arg hostname "$hostname" \
    --arg domain_id "$domain_id" '
      if .["@type"] == "update" and .object == "SystemSettings" then
        .value.defaultHostname = (.value.defaultHostname // $hostname) |
        .value.defaultDomainId = (
          if (.value.defaultDomainId | type) == "string" and
             ((.value.defaultDomainId | startswith("#")) or
              (.value.defaultDomainId | startswith("name:")))
          then $domain_id
          elif (.value.defaultDomainId | type) == "string" and
               (.value.defaultDomainId | length) > 0
          then .value.defaultDomainId
          else $domain_id
          end
        )
      else
        .
      end
    ' >> "$rewritten"
done < "$plan_in"

cat "$rewritten" > "$plan_in"
rm -f "$rewritten"
trap - EXIT

cli apply --file "$plan_in"
