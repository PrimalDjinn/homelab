#!/bin/sh
# Rewrite baked-in email-service allow-lists to match ALLOWED_DOMAINS at runtime.
# Upstream client/server bundles ignore runtime env and ship defaults that include
# a typo (heilomeet.com). Patch once per container start from the image files.
set -eu

DOMAINS="${ALLOWED_DOMAINS:-${NUXT_PUBLIC_ALLOWED_DOMAINS:-}}"
[ -n "$DOMAINS" ] || {
  echo "ALLOWED_DOMAINS unset; skipping client/server domain patch"
  exit 0
}
DOMAINS="$(printf '%s' "$DOMAINS" | tr -d '[:space:]')"
[ -n "$DOMAINS" ] || exit 0

ROOT="${APP_ROOT:-/app}"
MARKER="$ROOT/.output/.homelab-allowed-domains-patched"
if [ -f "$MARKER" ]; then
  prev="$(cat "$MARKER" 2>/dev/null || true)"
  if [ "$prev" = "$DOMAINS" ]; then
    exit 0
  fi
  echo "error: allowed-domains already patched to '$prev'; recreate the app container to change it" >&2
  exit 1
fi

export ALLOWED_DOMAINS_PATCH="$DOMAINS"
export APP_ROOT_PATCH="$ROOT"

node <<'NODE'
const fs = require("fs");
const path = require("path");

const domains = process.env.ALLOWED_DOMAINS_PATCH;
const root = process.env.APP_ROOT_PATCH || "/app";
const parts = domains.split(",").map((d) => d.trim()).filter(Boolean);
const newCsv = parts.join(",");
const newArrSpaced = "[" + parts.map((d) => `"${d}"`).join(", ") + "]";
const newArrCompact = "[" + parts.map((d) => `"${d}"`).join(",") + "]";

const repls = [
  ['["ifkafin.com", "finueva.com", "heilomeet.com"]', newArrSpaced],
  ['["ifkafin.com","finueva.com","heilomeet.com"]', newArrCompact],
  ["ifkafin.com,finueva.com,heilomeet.com", newCsv],
];

function patchFile(file) {
  if (!fs.existsSync(file)) return false;
  let text = fs.readFileSync(file, "utf8");
  if (!text.includes("heilomeet.com") && !text.includes("ifkafin.com,finueva.com,heilomeet.com")) {
    return false;
  }
  let next = text;
  for (const [old, neu] of repls) next = next.split(old).join(neu);
  if (next !== text) {
    fs.writeFileSync(file, next);
    return true;
  }
  return false;
}

let changed = false;
const nitro = path.join(root, ".output/server/chunks/nitro/nitro.mjs");
if (patchFile(nitro)) changed = true;

const nuxtDir = path.join(root, ".output/public/_nuxt");
if (fs.existsSync(nuxtDir)) {
  for (const name of fs.readdirSync(nuxtDir)) {
    if (!name.endsWith(".js")) continue;
    if (patchFile(path.join(nuxtDir, name))) changed = true;
  }
}

if (changed) {
  fs.writeFileSync(path.join(root, ".output/.homelab-allowed-domains-patched"), domains + "\n");
  console.log("Patched allowed email domains to: " + domains);
} else {
  console.log("No upstream default domain strings found to patch");
}
NODE
