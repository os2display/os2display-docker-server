#!/usr/bin/env bash
#
# Interactive setup for .env.traefik: prompts for domain, Let's Encrypt email,
# and dashboard credentials, generates an htpasswd entry, and updates the
# corresponding lines in .env.traefik in place.
#
# Runs from the project root (Taskfile.yml's directory).

set -euo pipefail

if [ ! -f .env.traefik ]; then
  echo ".env.traefik does not exist. Copying .env.traefik.production.example to .env.traefik..."
  cp .env.traefik.production.example .env.traefik
fi

# Ensure htpasswd is installed.
if ! command -v htpasswd >/dev/null 2>&1; then
  echo "Error: 'htpasswd' command not found." >&2
  echo "Install it (usually from the 'apache2-utils' or 'httpd-tools' package) and try again." >&2
  exit 1
fi

echo ""
echo "Configure Traefik environment"
echo "===================================================="
printf "Enter server domain (e.g. example.com): "
read -r SERVER_DOMAIN
printf "Enter email for Let's Encrypt (e.g. admin@example.com): "
read -r TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL
printf "Enter Traefik dashboard/admin username: "
read -r SERVER_DASHBOARD_USERNAME
printf "Enter Traefik dashboard/admin password: "
read -rs SERVER_DASHBOARD_PASSWORD
echo

# Generate htpasswd entry (username:hash).
HTPASSWD_RAW=$(htpasswd -nb "${SERVER_DASHBOARD_USERNAME}" "${SERVER_DASHBOARD_PASSWORD}")

# Escape characters that break sed/env ($, /, &).
HTPASSWD_ESCAPED=$(printf '%s\n' "$HTPASSWD_RAW" \
  | sed -e 's/[\/&]/\\&/g' -e 's/\$/\\$/g')

# Update variables in .env.traefik.
sed -i "s/^SERVER_DOMAIN=.*/SERVER_DOMAIN=${SERVER_DOMAIN}/" .env.traefik
sed -i "s/^TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL=.*/TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL=${TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL}/" .env.traefik
sed -i "s/^SERVER_DASHBOARD_AUTH=.*/SERVER_DASHBOARD_AUTH=${HTPASSWD_ESCAPED}/" .env.traefik

echo "===================================================="
echo ".env.traefik has been updated."
echo "Domain:   ${SERVER_DOMAIN}"
echo "Email:    ${TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL}"
echo "User:     ${SERVER_DASHBOARD_USERNAME}"
echo "Password: (hidden)"
echo "Auth:     (htpasswd line stored in SERVER_DASHBOARD_AUTH)"
echo "===================================================="
