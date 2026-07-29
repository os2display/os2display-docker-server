#!/usr/bin/env bash
#
# Generate a self-signed certificate for local-host development with
# SERVER_CERT_PROVIDER=cert-file. Writes traefik/ssl/dev.{crt,key} covering
# OS2DISPLAY_SERVER_DOMAIN and SERVER_DOMAIN as Subject Alternative Names,
# falling back to *.localhost when those env files don't exist yet.
#
# Usage: scripts/dev-cert.sh           (refuses if dev.crt already exists)
#        FORCE=1 scripts/dev-cert.sh   (overwrite)
#
# NOT FOR PRODUCTION. The output is RSA-2048, SHA-256, 365 days, untrusted
# CA. Production operators supply their own cert as docker.{crt,key} via
# the existing cert-file recipe; this script only writes dev.{crt,key} so
# it won't clobber a hand-supplied production cert.
#
# Requires: docker. Uses alpine/openssl in a transient container so no
# openssl is needed on the host.

set -euo pipefail

CERT_DIR="traefik/ssl"
CERT_FILE="$CERT_DIR/dev.crt"
KEY_FILE="$CERT_DIR/dev.key"

# Re-source env files defensively. Task's `dotenv:` snapshots .env /
# .env.traefik when the runner starts; chained tasks that mutate those
# files (e.g. `dev:install` → `dev:env` → `dev:cert`) would otherwise
# leave the runner's exported env stale and we'd generate a cert with
# the OLD domains. Sourcing here guarantees fresh values regardless of
# caller. Defaults still kick in when env files aren't bootstrapped yet.
set -a
# shellcheck disable=SC1091
[ -f .env ]         && . ./.env
# shellcheck disable=SC1091
[ -f .env.traefik ] && . ./.env.traefik
set +a

APP_DOMAIN="${OS2DISPLAY_SERVER_DOMAIN:-os2display.localhost}"
DASH_DOMAIN="${SERVER_DOMAIN:-traefik.localhost}"

if [ -f "$CERT_FILE" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "Error: $CERT_FILE already exists. Set FORCE=1 to overwrite." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"

docker run --rm -v "$PWD/$CERT_DIR:/out" alpine/openssl \
  req -x509 -newkey rsa:2048 -nodes \
      -keyout /out/dev.key \
      -out    /out/dev.crt \
      -days   365 \
      -subj   "/CN=${APP_DOMAIN}" \
      -addext "subjectAltName=DNS:${APP_DOMAIN},DNS:${DASH_DOMAIN},DNS:localhost,IP:127.0.0.1"

echo "Generated:"
echo "  $CERT_FILE   (covers: ${APP_DOMAIN}, ${DASH_DOMAIN}, localhost, 127.0.0.1)"
echo "  $KEY_FILE"
echo
echo "Next: configure cert-file mode in .env.traefik:"
echo "  SERVER_CERT_PROVIDER=cert-file"
echo "  SERVER_CUSTOM_CERT_FILE=dev.crt"
echo "  SERVER_CUSTOM_KEY_FILE=dev.key"
echo "Then: task install   (or task update if the stack is already running)"
