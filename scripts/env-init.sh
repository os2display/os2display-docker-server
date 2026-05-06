#!/usr/bin/env bash
#
# Bootstrap .env.symfony from the API image. Pulls the pinned image, extracts
# its bundled /app/.env, then post-processes:
#
#   - APP_SECRET   replaced with a random 32-byte hex
#   - JWT_PASSPHRASE replaced with a random 32-byte hex
#   - DATABASE_URL serverVersion bumped to match the mariadb image pinned in
#     docker-compose.yml (otherwise the bundled value drifts behind the stack
#     and Doctrine picks the wrong SQL dialect)
#
# Operators can hand-edit afterwards for ADMIN_*, CLIENT_*, OIDC_* etc.
#
# Usage: scripts/env-init.sh
#        FORCE=1 scripts/env-init.sh   (overwrite existing .env.symfony)
#
# Requires: docker. Reads OS2DISPLAY_VERSION_API from .env to pick the image
# tag, and the mariadb image tag from docker-compose.yml.

set -euo pipefail

if [ ! -f .env ]; then
  echo "Error: .env missing — copy .env.example to .env first." >&2
  exit 1
fi

if [ -f .env.symfony ] && [ "${FORCE:-0}" != "1" ]; then
  echo "Error: .env.symfony already exists. Use 'task env:diff' to compare," >&2
  echo "       or set FORCE=1 to overwrite." >&2
  exit 1
fi

VERSION=$(grep '^OS2DISPLAY_VERSION_API=' .env | cut -d= -f2)
IMAGE="ghcr.io/os2display/display-api-service:${VERSION}"

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

echo ".env.symfony created from $IMAGE."
echo "  APP_SECRET / JWT_PASSPHRASE: random 32-byte hex (auto-generated)"
echo "  DATABASE_URL serverVersion:  ${MARIADB_TAG}-MariaDB (matched to compose pin)"
echo
echo "Edit .env.symfony for any ADMIN_*, CLIENT_*, OIDC_*, or DATABASE_URL"
echo "credential overrides, then run 'task install'."
