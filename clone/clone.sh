#!/usr/bin/env bash
#
# Clone a running stack INTO this checkout and bring it up on another domain,
# sharing the source's running traefik. This directory (the stack root holding
# clone/) is the DESTINATION; the operator points SOURCE at the stack to clone.
# End to end:
#
#   1. Dump the SOURCE database (DATABASE_URL in SOURCE/.env.symfony).
#   2. Copy the source's operator state here — env files, ./media uploads and
#      the ./jwt keypair. Repo files (compose, Taskfile, scripts) are NOT
#      copied: this checkout already provides them.
#   3. Rewrite ./.env           : COMPOSE_PROJECT_NAME, OS2DISPLAY_SERVER_DOMAIN,
#                                 drop `traefik` from COMPOSE_PROFILES, and opt
#                                 into the shared-frontend override via
#                                 COMPOSE_FILE + OS2DISPLAY_FRONTEND_NETWORK.
#      Rewrite ./.env.symfony   : DATABASE_URL -> the clone's (separate) DB,
#                                 and every occurrence of the old domain -> new
#                                 (CORS, ADMIN_*, CLIENT_*, OIDC redirect URIs).
#      Rewrite ./docker-compose.yml : project-namespace the traefik router +
#                                 middleware names, so the clone's routes don't
#                                 collide with the source's behind the shared
#                                 traefik. (This dirties the checkout's git
#                                 status — `git diff` shows exactly what the
#                                 clone changed. The SOURCE is never modified.)
#   4. Bring the clone up on the shared frontend network — no second traefik;
#      the running one discovers the clone's nginx-api and routes the new domain.
#   5. Restore the dump into the clone's database.
#   6. Clear the clone's application cache.
#
# APP_SECRET, JWT_PASSPHRASE and the ./jwt keypair are copied verbatim, so the
# cloned data's existing user logins and screen tokens keep working. Only the
# domain, project name and DATABASE_URL change.
#
# Required (env vars):
#   SOURCE=../os2display                  the running stack to clone (its root —
#                                         the dir holding .env / .env.symfony)
#   DOMAIN=clone.example.com              public domain the clone serves
#   CLONE_DATABASE_URL=mysql://u:p@host:3306/clonedb?serverVersion=mariadb-11.4.10-MariaDB
#                                         the clone's database — MUST differ from
#                                         the source, or production gets clobbered
# Optional:
#   CLONE_PROJECT=<name>     compose project name (default: sanitised basename
#                            of this checkout's directory)
#   FRONTEND_NETWORK=<name>  shared external network (default: source's
#                            OS2DISPLAY_FRONTEND_NETWORK, else "frontend")
#
# Configuration is read from clone/.env.clone (copy clone/.env.clone.example),
# so repeat runs need no arguments. Variables set in the environment override
# the file, e.g.:  DOMAIN=other.example.com clone/clone.sh
#
# Repeat runs REFRESH the clone in place (new dump, env re-copied + rewritten)
# — allowed only when the existing ./.env carries the clone's own project name,
# so a configured non-clone stack in this directory is never clobbered.
#
# Run from this checkout's root (or via `task -t clone/Taskfile.yml clone`):
#   clone/clone.sh
#
# Requires: docker, rsync.

set -euo pipefail

# Resolve our own dir (for the lib + sibling scripts), then operate on the
# DESTINATION stack root — the checkout this clone/ directory lives in.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# shellcheck source=clone/lib-db-url.sh
. "$SCRIPT_DIR/lib-db-url.sh"

# -- Inputs ------------------------------------------------------------------

# Load clone/.env.clone as the baseline for repeat runs, but let any value
# already present in the environment win (one-off overrides). Snapshot the
# environment-provided values, source the file, then re-apply the snapshot.
CLONE_VARS="SOURCE DOMAIN CLONE_DATABASE_URL CLONE_PROJECT FRONTEND_NETWORK"
declare -A _env_override
for _v in $CLONE_VARS; do _env_override[$_v]="${!_v:-}"; done

if [ -f "$SCRIPT_DIR/.env.clone" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env.clone"
  set +a
fi

for _v in $CLONE_VARS; do
  [ -n "${_env_override[$_v]}" ] && printf -v "$_v" '%s' "${_env_override[$_v]}"
done

: "${SOURCE:?Set SOURCE in clone/.env.clone (or the environment) — the stack root to clone}"
: "${DOMAIN:?Set DOMAIN in clone/.env.clone (or the environment) — domain the clone serves}"
: "${CLONE_DATABASE_URL:?Set CLONE_DATABASE_URL in clone/.env.clone (or the environment)}"

command -v rsync >/dev/null 2>&1 || {
  echo "Error: rsync not found. Install it (e.g. 'apt-get install -y rsync')." >&2
  exit 1
}

# Resolve SOURCE (relative paths are taken from this stack root) and sanity-
# check it is a configured stack.
SOURCE="$(cd "$SOURCE" 2>/dev/null && pwd)" || {
  echo "Error: SOURCE directory not found." >&2
  exit 1
}
[ "$SOURCE" != "$PWD" ] || {
  echo "Error: SOURCE is this directory — point it at the stack to clone FROM." >&2
  exit 1
}
[ -f "$SOURCE/.env" ] || {
  echo "Error: $SOURCE/.env missing — is SOURCE a configured stack root?" >&2
  exit 1
}
[ -f "$SOURCE/.env.symfony" ] || {
  echo "Error: $SOURCE/.env.symfony missing — run 'task env:init' in the source first." >&2
  exit 1
}

SRC_DB_URL=$(read_database_url "$SOURCE/.env.symfony")
SRC_DOMAIN=$(grep -E '^OS2DISPLAY_SERVER_DOMAIN=' "$SOURCE/.env" | head -1 | cut -d= -f2-)
SRC_PROJECT=$(grep -E '^COMPOSE_PROJECT_NAME=' "$SOURCE/.env" | head -1 | cut -d= -f2-)
SRC_PROJECT="${SRC_PROJECT:-os2display}"

[ -n "$SRC_DOMAIN" ] || {
  echo "Error: OS2DISPLAY_SERVER_DOMAIN not set in $SOURCE/.env." >&2
  exit 1
}

# Clone project name: sanitise this checkout's basename to compose's [a-z0-9_-].
if [ -z "${CLONE_PROJECT:-}" ]; then
  CLONE_PROJECT=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//')
fi

# Shared frontend network the running traefik is on. Source's compose names
# its network after OS2DISPLAY_FRONTEND_NETWORK (default "frontend").
SRC_FE=$(grep -E '^OS2DISPLAY_FRONTEND_NETWORK=' "$SOURCE/.env" | head -1 | cut -d= -f2- || true)
FRONTEND_NETWORK="${FRONTEND_NETWORK:-${SRC_FE:-frontend}}"

# -- Safety guards -----------------------------------------------------------

if [ "$CLONE_DATABASE_URL" = "$SRC_DB_URL" ]; then
  echo "Error: CLONE_DATABASE_URL is identical to the source DATABASE_URL." >&2
  echo "       The clone MUST use a different database or you'll overwrite the source." >&2
  exit 1
fi
if [ "$DOMAIN" = "$SRC_DOMAIN" ]; then
  echo "Error: DOMAIN equals the source domain ($SRC_DOMAIN). Use a different URL." >&2
  exit 1
fi
if [ "$CLONE_PROJECT" = "$SRC_PROJECT" ]; then
  echo "Error: clone project name ($CLONE_PROJECT) equals the source ($SRC_PROJECT)." >&2
  echo "       Set CLONE_PROJECT=… to something distinct." >&2
  exit 1
fi
# This checkout already configured? Only proceed if it is OUR clone (project
# name matches what we'd write) — refreshing a previous run is fine, silently
# clobbering some other configured stack is not.
if [ -f .env ]; then
  EXISTING_PROJECT=$(compose_project)
  if [ "$EXISTING_PROJECT" != "$CLONE_PROJECT" ]; then
    echo "Error: this directory already has a configured .env (COMPOSE_PROJECT_NAME=" >&2
    echo "       ${EXISTING_PROJECT}) that is not this clone's (${CLONE_PROJECT})." >&2
    echo "       Refusing to overwrite — use a fresh checkout for the clone." >&2
    exit 1
  fi
  echo "Existing clone '$CLONE_PROJECT' detected — refreshing in place."
fi
if ! docker network ls --format '{{.Name}}' | grep -qx "$FRONTEND_NETWORK"; then
  echo "Error: shared frontend network '$FRONTEND_NETWORK' not found." >&2
  echo "       Bring the SOURCE stack up first (it creates this network), or set" >&2
  echo "       FRONTEND_NETWORK=… to the network the running traefik is attached to." >&2
  exit 1
fi

echo "Cloning '$SRC_PROJECT' ($SRC_DOMAIN) -> '$CLONE_PROJECT' ($DOMAIN)"
echo "  source            : $SOURCE"
echo "  clone database    : ${CLONE_DATABASE_URL%%\?*}"
echo "  shared network    : $FRONTEND_NETWORK"
echo

# Portable in-place sed (BSD/macOS + GNU/Linux).
sed_inplace() {
  sed -i.bak "$1" "$2"
  rm -f "$2.bak"
}

# -- 1. Dump the source DB ---------------------------------------------------

echo "==> [1/6] Dumping source database"
mkdir -p backup
DUMP_REL="backup/clone-${CLONE_PROJECT}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
# STACK_ROOT points the dump at the SOURCE stack (its DATABASE_URL, mariadb
# tag and app network); the absolute OUT path lands the file in OUR backup/.
STACK_ROOT="$SOURCE" "$SCRIPT_DIR/db-dump.sh" "$PWD/$DUMP_REL"

# -- 2. Copy the source's operator state here ----------------------------------

echo "==> [2/6] Copying source env files, media and jwt keypair"
# Anchored include-list: top-level env files (not the tracked *.example
# templates — the checkout has its own), the media uploads and the jwt
# keypair. Everything else (repo files, backups, the source's clone/ config)
# stays out — this checkout provides the code. First match wins.
rsync -a \
  --exclude='.env*.example' \
  --include='/.env' \
  --include='/.env.*' \
  --include='/media/***' \
  --include='/jwt/***' \
  --exclude='*' \
  "$SOURCE"/ ./

# -- 3. Rewrite the clone's env ----------------------------------------------

echo "==> [3/6] Rewriting clone env (domain, project, profiles, DATABASE_URL)"
ENV=".env"
SYM=".env.symfony"

if grep -qE '^COMPOSE_PROJECT_NAME=' "$ENV"; then
  sed_inplace "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${CLONE_PROJECT}|" "$ENV"
else
  printf '\nCOMPOSE_PROJECT_NAME=%s\n' "$CLONE_PROJECT" >>"$ENV"
fi
sed_inplace "s|^OS2DISPLAY_SERVER_DOMAIN=.*|OS2DISPLAY_SERVER_DOMAIN=${DOMAIN}|" "$ENV"

# Drop `traefik` from COMPOSE_PROFILES — the clone rides the source's traefik.
if grep -qE '^COMPOSE_PROFILES=' "$ENV"; then
  CUR=$(grep -E '^COMPOSE_PROFILES=' "$ENV" | head -1 | cut -d= -f2-)
  NEWP=$(printf '%s' "$CUR" | tr ',' '\n' | grep -vx 'traefik' | paste -sd, - || true)
  sed_inplace "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${NEWP}|" "$ENV"
fi

# Opt into the shared-frontend override (flips `frontend` to external) and
# point at the running traefik's network.
if grep -qE '^#?[[:space:]]*OS2DISPLAY_FRONTEND_NETWORK=' "$ENV"; then
  sed_inplace "s|^#\{0,1\}[[:space:]]*OS2DISPLAY_FRONTEND_NETWORK=.*|OS2DISPLAY_FRONTEND_NETWORK=${FRONTEND_NETWORK}|" "$ENV"
else
  printf '\nOS2DISPLAY_FRONTEND_NETWORK=%s\n' "$FRONTEND_NETWORK" >>"$ENV"
fi
if grep -qE '^COMPOSE_FILE=' "$ENV"; then
  sed_inplace "s|^COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:compose.shared-frontend.yml|" "$ENV"
else
  printf 'COMPOSE_FILE=docker-compose.yml:compose.shared-frontend.yml\n' >>"$ENV"
fi

# DATABASE_URL -> the clone's. Escape sed replacement metachars (& \ |).
DBREPL=$(printf '%s' "$CLONE_DATABASE_URL" | sed 's/[&|\\]/\\&/g')
sed_inplace "s|^DATABASE_URL=.*|DATABASE_URL=\"${DBREPL}\"|" "$SYM"

# Rewrite the old domain -> new everywhere in .env.symfony (CORS_ALLOW_ORIGIN,
# ADMIN_*, CLIENT_*, OIDC redirect URIs, API endpoints). Escape regex chars in
# the source domain so dots match literally.
ESC_SRC=$(printf '%s' "$SRC_DOMAIN" | sed 's/[.[\*^$/]/\\&/g')
sed_inplace "s/${ESC_SRC}/${DOMAIN}/g" "$SYM"

# Project-namespace the traefik router + middleware names in THIS checkout's
# docker-compose.yml. The shipped compose hardcodes `apios2display`,
# `redirect-to-https` and `redirect-to-admin`; behind a shared traefik those
# names would collide with the source stack's identical names. Baking the
# clone project in keeps each stack's routes distinct. The rewrite shows up
# in `git status` — that's intentional (reviewable); the SOURCE compose is
# never modified. Gated on the un-namespaced router name so a refresh run
# doesn't re-prefix the middleware names (`<proj>-redirect-to-https` still
# contains `redirect-to-https`); to re-namespace from a clean slate, run
# `git checkout docker-compose.yml` first.
DC="docker-compose.yml"
if grep -q 'apios2display' "$DC"; then
  sed_inplace "s/apios2display/${CLONE_PROJECT}-api/g" "$DC"
  sed_inplace "s/redirect-to-https/${CLONE_PROJECT}-redirect-to-https/g" "$DC"
  sed_inplace "s/redirect-to-admin/${CLONE_PROJECT}-redirect-to-admin/g" "$DC"
fi

# -- 4. Bring the clone up ----------------------------------------------------

echo "==> [4/6] Bringing the clone up (shared frontend, no second traefik)"
# COMPOSE_FILE / COMPOSE_PROFILES / COMPOSE_PROJECT_NAME come from ./.env
# (compose's default discovery); --env-file adds the substitution vars, same
# as the Taskfile's COMPOSE invocation.
docker compose --env-file .env --env-file .env.traefik up -d --wait

# -- 5. Restore the dump into the clone DB -----------------------------------

echo "==> [5/6] Restoring dump into the clone database"
"$SCRIPT_DIR/db-restore.sh" "$DUMP_REL"

# -- 6. Clear the clone cache -------------------------------------------------

echo "==> [6/6] Clearing the clone cache"
docker compose --env-file .env --env-file .env.traefik exec -T os2display bin/console cache:clear || true

echo
echo "===================================================="
echo "Clone is up."
echo "  Admin : https://${DOMAIN}/admin"
echo "  Screen: https://${DOMAIN}/client"
echo "===================================================="
echo "If this checkout's image pin added migrations since the dump was taken, run:"
echo "  docker compose --env-file .env --env-file .env.traefik \\"
echo "       exec --user deploy os2display bin/console app:update"
