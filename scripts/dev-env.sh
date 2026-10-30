#!/usr/bin/env bash
#
# Dev quick-start env bootstrap. Combines `task env:init` (non-interactive,
# with OS2DISPLAY_SERVER_DOMAIN=os2display.localhost) and the .env.traefik
# pieces of `task env:traefik` (cert-file mode + dev domains + dashboard
# auth), so a fresh checkout can reach `task install` in one step.
#
# Usage: scripts/dev-env.sh
#
# Overrides (all optional):
#   DOMAIN=...                  app hostname  (default: os2display.localhost)
#   DASH_DOMAIN=...             traefik dashboard hostname (default: traefik.localhost)
#   DEV_DASHBOARD_USER=...      dashboard basic-auth user (default: admin)
#   DEV_DASHBOARD_PASSWORD=...  dashboard basic-auth password (default: admin)
#   FORCE=1                     re-extract .env.symfony from the API image
#
# NOT FOR PRODUCTION. The dashboard password defaults to `admin`. Use
# `task env:init` + `task env:traefik` for any operator-facing install.
#
# Requires: docker.

set -euo pipefail

DOMAIN="${DOMAIN:-os2display.localhost}"
DASH_DOMAIN="${DASH_DOMAIN:-traefik.localhost}"
DEV_USER="${DEV_DASHBOARD_USER:-admin}"
DEV_PASS="${DEV_DASHBOARD_PASSWORD:-admin}"

# 1) env:init with the localhost defaults (no prompt — DOMAIN is exported).
DOMAIN="$DOMAIN" ./scripts/env-init.sh

# 2) .env.traefik dev configuration. Always rewrites SERVER_DOMAIN /
#    SERVER_DASHBOARD_AUTH / SERVER_CERT_PROVIDER and strips any previously
#    active SERVER_CUSTOM_*_FILE lines, then appends the dev.{crt,key}
#    filenames — same idempotent shape as env-traefik.sh.

# Hash the dashboard password via alpine/openssl `passwd -apr1 -stdin` —
# APR1 format, no host htpasswd / openssl needed. Stdin-piped to avoid
# ps-visible password leakage.
HASH=$(printf '%s' "${DEV_PASS}" \
  | docker run --rm -i alpine/openssl passwd -apr1 -stdin)
HTPASSWD_RAW="${DEV_USER}:${HASH}"

# Escape so the value survives both sed substitution and docker compose
# variable interpolation. `/` and `&` are sed-replacement special chars;
# each `$` must become `$$` because compose treats `$$` in env-file values
# as a literal `$` (otherwise `$apr1$...` from htpasswd is read as the
# env var `apr1` etc. and substituted to empty).
HTPASSWD_ESCAPED=$(printf '%s\n' "$HTPASSWD_RAW" \
  | sed -e 's/[\/&]/\\&/g' -e 's/\$/$$/g')

sed_inplace() {
  sed -i.bak "$1" .env.traefik
  rm -f .env.traefik.bak
}

sed_inplace "s/^SERVER_DOMAIN=.*/SERVER_DOMAIN=${DASH_DOMAIN}/"
sed_inplace "s/^SERVER_DASHBOARD_AUTH=.*/SERVER_DASHBOARD_AUTH=${HTPASSWD_ESCAPED}/"
sed_inplace "s/^SERVER_CERT_PROVIDER=.*/SERVER_CERT_PROVIDER=cert-file/"
sed_inplace '/^SERVER_CUSTOM_\(CERT\|KEY\)_FILE=/d'

printf 'SERVER_CUSTOM_CERT_FILE=dev.crt\nSERVER_CUSTOM_KEY_FILE=dev.key\n' >> .env.traefik

echo
echo "===================================================="
echo "Dev environment configured for localhost:"
echo "  App URL:      https://${DOMAIN}/admin"
echo "  Traefik UI:   https://${DASH_DOMAIN}/traefik/dashboard/"
echo "  Dashboard:    ${DEV_USER} / ${DEV_PASS}"
echo "  Cert mode:    cert-file (next: 'task dev:cert')"
echo "===================================================="
echo
echo "NOT FOR PRODUCTION. The dashboard password defaults to 'admin'."
echo "For an operator-facing install, use 'task env:init' + 'task env:traefik'."
