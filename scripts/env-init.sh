#!/usr/bin/env bash
#
# Bootstrap every env file the stack needs, in one call:
#
#   - .env: copied from .env.example if missing, with OS2DISPLAY_SERVER_DOMAIN
#     prompted (default os2display.localhost for fast localhost-dev setup).
#   - .env.{php,nginx,mariadb,traefik}: copied from .env.{...}.example if
#     not already present (idempotent — operator-edited files are kept).
#   - .env.symfony: extracted from /app/.env in the pinned API image, with
#     APP_SECRET + JWT_PASSPHRASE replaced by random 32-byte hex and
#     DATABASE_URL serverVersion bumped to match the mariadb image pinned
#     in docker-compose.yml (otherwise the bundled value drifts behind the
#     stack and Doctrine picks the wrong SQL dialect).
#
# This is the single bootstrap entry point. `task install` / `task up` /
# `task update` precondition on `.env.symfony` existing — running this is
# the gate that unlocks them. Operators can hand-edit any of the produced
# files afterwards (ADMIN_*, CLIENT_*, OIDC_*, MARIADB credentials, etc.).
#
# Usage: scripts/env-init.sh
#        FORCE=1 scripts/env-init.sh   (overwrite existing .env.symfony)
#
# Requires: docker.

set -euo pipefail

# .env first — it's the gate to OS2DISPLAY_VERSION_API which we need for
# the API image pull.
if [ ! -f .env ]; then
  printf "Public domain to serve [os2display.localhost]: "
  read -r DOMAIN
  DOMAIN="${DOMAIN:-os2display.localhost}"

  cp .env.example .env
  sed -i.bak "s|^OS2DISPLAY_SERVER_DOMAIN=.*|OS2DISPLAY_SERVER_DOMAIN=${DOMAIN}|" .env
  rm -f .env.bak

  echo "Created .env with OS2DISPLAY_SERVER_DOMAIN=${DOMAIN}."
fi

# Source .env so OS2DISPLAY_VERSION_API (and friends) are in the env even
# when the file was just now created — Taskfile's `dotenv:` directive
# already ran (or skipped) before this script started.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

if [ -z "${OS2DISPLAY_VERSION_API:-}" ]; then
  echo "Error: OS2DISPLAY_VERSION_API unset in .env. Edit .env or restore from" >&2
  echo "       .env.example, then re-run." >&2
  exit 1
fi

# Per-service env files — fast and side-effect-free if already present.
for svc in php nginx mariadb traefik; do
  if [ ! -f ".env.$svc" ]; then
    echo "Created .env.$svc (from .env.$svc.example)"
    cp ".env.$svc.example" ".env.$svc"
  fi
done

if [ -f .env.symfony ] && [ "${FORCE:-0}" != "1" ]; then
  echo
  echo ".env.symfony already exists. Use 'task env:diff' to compare,"
  echo "or set FORCE=1 to overwrite. Per-service files above are up to date."
  exit 0
fi

IMAGE="ghcr.io/os2display/display-api-service:${OS2DISPLAY_VERSION_API}"

# Match the mariadb pin in docker-compose.yml; falls back to a sensible
# default if the line moves. Format expected: `image: mariadb:11.4.10`.
MARIADB_TAG=$(awk -F: '/^[[:space:]]+image:[[:space:]]+mariadb:/ {gsub(/ /,"",$NF); print $NF; exit}' docker-compose.yml)
MARIADB_TAG="${MARIADB_TAG:-11.4.10}"

docker pull "$IMAGE" >/dev/null
docker run --rm --entrypoint sh "$IMAGE" -c 'cat /app/.env' > .env.symfony

# Random secrets via the same alpine/openssl image task dev:cert uses.
APP_SECRET=$(docker run --rm alpine/openssl rand -hex 32)
JWT_PASS=$(docker run --rm alpine/openssl rand -hex 32)

sed -i.bak \
  -e "s|^APP_SECRET=.*|APP_SECRET=${APP_SECRET}|" \
  -e "s|^JWT_PASSPHRASE=.*|JWT_PASSPHRASE=${JWT_PASS}|" \
  -e "s|serverVersion=[0-9.]*-MariaDB|serverVersion=${MARIADB_TAG}-MariaDB|" \
  .env.symfony
rm -f .env.symfony.bak

echo
echo ".env.symfony created from $IMAGE."
echo "  APP_SECRET / JWT_PASSPHRASE: random 32-byte hex (auto-generated)"
echo "  DATABASE_URL serverVersion:  ${MARIADB_TAG}-MariaDB (matched to compose pin)"
echo
echo "Edit .env.symfony for any ADMIN_*, CLIENT_*, OIDC_*, or DATABASE_URL"
echo "credential overrides, then run 'task install'."
