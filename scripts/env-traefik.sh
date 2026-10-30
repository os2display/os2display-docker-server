#!/usr/bin/env bash
#
# Interactive setup for .env.traefik: prompts for cert provider, domain,
# Let's Encrypt email, and dashboard credentials, then writes the
# corresponding lines into .env.traefik in place.
#
# No host openssl or apache2-utils dependency — htpasswd hashing happens
# inside a transient alpine/openssl container (the same image task dev:cert
# uses).
#
# Runs from the project root (Taskfile.yml's directory).

set -euo pipefail

if [ ! -f .env.traefik ]; then
  echo ".env.traefik does not exist. Copying .env.traefik.example to .env.traefik..."
  cp .env.traefik.example .env.traefik
fi

echo ""
echo "Configure Traefik environment"
echo "===================================================="
echo "Cert provider:"
echo "  1) letsencrypt   default; needs public DNS + reachable port 80"
echo "  2) cert-file     operator-supplied cert in traefik/ssl/ (also: task dev:cert for localhost dev)"
printf "Choose [1]: "
read -r CERT_CHOICE
case "${CERT_CHOICE:-1}" in
  2|cert-file) CERT_PROVIDER="cert-file" ;;
  *)           CERT_PROVIDER="letsencrypt" ;;
esac

printf "Enter server domain (e.g. example.com): "
read -r SERVER_DOMAIN

if [ "$CERT_PROVIDER" = "letsencrypt" ]; then
  printf "Enter email for Let's Encrypt (e.g. admin@example.com): "
  read -r LE_EMAIL
  CUSTOM_CERT_FILE=""
  CUSTOM_KEY_FILE=""
else
  LE_EMAIL=""
  printf "Custom cert filename in traefik/ssl/ [dev.crt]: "
  read -r CUSTOM_CERT_FILE
  CUSTOM_CERT_FILE="${CUSTOM_CERT_FILE:-dev.crt}"
  printf "Custom key filename in traefik/ssl/ [dev.key]: "
  read -r CUSTOM_KEY_FILE
  CUSTOM_KEY_FILE="${CUSTOM_KEY_FILE:-dev.key}"
fi

printf "Enter Traefik dashboard/admin username: "
read -r SERVER_DASHBOARD_USERNAME
printf "Enter Traefik dashboard/admin password: "
read -rs SERVER_DASHBOARD_PASSWORD
echo

# Hash via alpine/openssl `passwd -apr1 -stdin` — produces the same APR1
# format Apache htpasswd writes, no host dependency. Stdin-piped (vs argv)
# avoids ps-visible password leakage.
HASH=$(printf '%s' "${SERVER_DASHBOARD_PASSWORD}" \
  | docker run --rm -i alpine/openssl passwd -apr1 -stdin)
HTPASSWD_RAW="${SERVER_DASHBOARD_USERNAME}:${HASH}"

# Escape so the value survives both sed substitution and docker compose
# variable interpolation. `/` and `&` are sed-replacement special chars;
# each `$` must become `$$` because compose treats `$$` in env-file values
# as a literal `$` (otherwise `$apr1$...` from htpasswd is read as the
# env var `apr1` etc. and substituted to empty).
HTPASSWD_ESCAPED=$(printf '%s\n' "$HTPASSWD_RAW" \
  | sed -e 's/[\/&]/\\&/g' -e 's/\$/$$/g')

# Helper: in-place sed that's portable across BSD (macOS) and GNU (Linux).
# `-i.bak` creates a backup both honour; we remove it afterwards.
sed_inplace() {
  sed -i.bak "$1" .env.traefik
  rm -f .env.traefik.bak
}

sed_inplace "s/^SERVER_DOMAIN=.*/SERVER_DOMAIN=${SERVER_DOMAIN}/"
sed_inplace "s/^SERVER_DASHBOARD_AUTH=.*/SERVER_DASHBOARD_AUTH=${HTPASSWD_ESCAPED}/"
sed_inplace "s/^SERVER_CERT_PROVIDER=.*/SERVER_CERT_PROVIDER=${CERT_PROVIDER}/"

# Strip any previously-active SERVER_CUSTOM_*_FILE lines; the example file's
# documentation comments (with the `# ` leading-space form) stay intact.
sed_inplace '/^SERVER_CUSTOM_\(CERT\|KEY\)_FILE=/d'

if [ "$CERT_PROVIDER" = "letsencrypt" ]; then
  sed_inplace "s/^TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL=.*/TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL=${LE_EMAIL}/"
else
  # Append cert-file vars on their own; idempotent because the d-command
  # above stripped any previous active set.
  printf 'SERVER_CUSTOM_CERT_FILE=%s\nSERVER_CUSTOM_KEY_FILE=%s\n' \
    "$CUSTOM_CERT_FILE" "$CUSTOM_KEY_FILE" >> .env.traefik
fi

echo "===================================================="
echo ".env.traefik has been updated."
echo "Cert provider: ${CERT_PROVIDER}"
echo "Domain:        ${SERVER_DOMAIN}"
[ "$CERT_PROVIDER" = "letsencrypt" ] && echo "LE email:      ${LE_EMAIL}"
[ "$CERT_PROVIDER" = "cert-file" ]   && echo "Cert files:    traefik/ssl/${CUSTOM_CERT_FILE}, traefik/ssl/${CUSTOM_KEY_FILE}"
echo "Dashboard:     ${SERVER_DASHBOARD_USERNAME} / (hidden)"
echo "===================================================="
