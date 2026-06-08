#!/usr/bin/env bash
#
# Clone a 1.x (v1 itk-dev) install INTO this checkout: replicate its database,
# uploads, JWT keypair and operator env 1:1, retargeted to a new domain and a
# separate database.
#
# This is a FAITHFUL v1 COPY — it does NOT convert anything to v3. Conversion
# is a separate, deliberate step using the v3 migration tooling that ships in
# this checkout (`task env:migrate` to turn .env.docker.local into
# .env.symfony, then `task install` / `task up` + `app:update` to migrate the
# database schema). Keeping clone and convert separate means the clone is an
# exact, re-runnable snapshot you can convert (and re-convert) at will.
#
# Steps:
#   1. Dump the SOURCE database (APP_DATABASE_URL in the v1 source).
#   2. Copy the source's operator state here 1:1 — env files (.env, .env.local,
#      .env.docker.local), ./media uploads and the ./jwt keypair.
#   3. Rewrite the copied v1 env: COMPOSE_PROJECT_NAME, COMPOSE_SERVER_DOMAIN,
#      APP_DATABASE_URL -> the clone DB, and every occurrence of the old domain
#      -> the new one (APP_API_ENDPOINT, CORS, OIDC redirect URIs, ...).
#   4. Restore the dump into the clone database.
#
# It does NOT bring a stack up: the copied config is v1 and this checkout is
# v3. Convert it next (see the closing notes the script prints), then bring it
# up with the normal v3 tasks.
#
# Required (env vars, or clone/.env.clone — copy clone/.env.clone.example):
#   SOURCE=/path/to/v1-install   the v1 stack root to clone (holds
#                                .env.docker.local with APP_DATABASE_URL)
#   DOMAIN=clone.example.com     public domain the converted clone will serve
#   CLONE_DATABASE_URL=mysql://u:p@host:3306/clonedb?...   the clone's database;
#                                MUST differ from the source. `task -t
#                                clone/Taskfile.yml create-db` provisions it and
#                                writes this value into clone/.env.clone.
# Optional:
#   CLONE_PROJECT=<name>   compose project name written into the clone's env
#                          (default: sanitised basename of this checkout's dir).
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
CLONE_VARS="SOURCE DOMAIN CLONE_DATABASE_URL CLONE_PROJECT"
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

: "${SOURCE:?Set SOURCE in clone/.env.clone (or the environment) — the v1 stack root to clone}"
: "${DOMAIN:?Set DOMAIN in clone/.env.clone (or the environment) — domain the clone serves}"
: "${CLONE_DATABASE_URL:?Set CLONE_DATABASE_URL in clone/.env.clone (or run create-db first)}"

command -v rsync >/dev/null 2>&1 || {
  echo "Error: rsync not found. Install it (e.g. 'apt-get install -y rsync')." >&2
  exit 1
}

# Resolve SOURCE (relative paths are taken from this stack root).
SOURCE="$(cd "$SOURCE" 2>/dev/null && pwd)" || {
  echo "Error: SOURCE directory not found." >&2
  exit 1
}
[ "$SOURCE" != "$PWD" ] || {
  echo "Error: SOURCE is this directory — point it at the stack to clone FROM." >&2
  exit 1
}

# The SOURCE is a 1.x itk-dev install: app config lives in .env.docker.local /
# .env.local as APP_DATABASE_URL, with the public domain in COMPOSE_SERVER_DOMAIN.
# (find_database_url also matches a v3 DATABASE_URL, but the rewrite below
# targets the v1 layout.)
SRC_DB_URL=$(find_database_url "$SOURCE") || {
  echo "Error: no APP_DATABASE_URL found under $SOURCE" >&2
  echo "       (looked in .env.local, .env.docker.local, .env.symfony)." >&2
  exit 1
}
SRC_DOMAIN=$(env_get "$SOURCE" COMPOSE_SERVER_DOMAIN || true)
[ -n "$SRC_DOMAIN" ] || SRC_DOMAIN=$(env_get "$SOURCE" OS2DISPLAY_SERVER_DOMAIN || true)
SRC_PROJECT=$(env_get "$SOURCE" COMPOSE_PROJECT_NAME || true)
SRC_PROJECT="${SRC_PROJECT:-os2display}"

[ -n "$SRC_DOMAIN" ] || {
  echo "Error: COMPOSE_SERVER_DOMAIN not set in $SOURCE." >&2
  exit 1
}

# Clone project name: sanitise this checkout's basename to compose's [a-z0-9_-].
if [ -z "${CLONE_PROJECT:-}" ]; then
  CLONE_PROJECT=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//')
fi

# -- Safety guards -----------------------------------------------------------

if [ "$CLONE_DATABASE_URL" = "$SRC_DB_URL" ]; then
  echo "Error: CLONE_DATABASE_URL is identical to the source database URL." >&2
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
# This checkout already configured for a different install? The clone's identity
# lives in its env's COMPOSE_PROJECT_NAME; refreshing our own clone is fine,
# clobbering some other configured stack is not.
EXISTING_PROJECT=$(env_get . COMPOSE_PROJECT_NAME || true)
if [ -n "$EXISTING_PROJECT" ] && [ "$EXISTING_PROJECT" != "$CLONE_PROJECT" ]; then
  echo "Error: this directory already carries env for COMPOSE_PROJECT_NAME=" >&2
  echo "       ${EXISTING_PROJECT}, which is not this clone's (${CLONE_PROJECT})." >&2
  echo "       Refusing to overwrite — use a fresh checkout for the clone." >&2
  exit 1
fi
[ -z "$EXISTING_PROJECT" ] || echo "Existing clone '$CLONE_PROJECT' detected — refreshing in place."

echo "Cloning v1 '$SRC_PROJECT' ($SRC_DOMAIN) -> '$CLONE_PROJECT' ($DOMAIN)"
echo "  source            : $SOURCE"
echo "  clone database    : ${CLONE_DATABASE_URL%%\?*}"
echo

# Portable in-place sed (BSD/macOS + GNU/Linux).
sed_inplace() {
  sed -i.bak "$1" "$2"
  rm -f "$2.bak"
}

# -- 1. Dump the source DB ---------------------------------------------------

echo "==> [1/4] Dumping source database"
mkdir -p backup
DUMP_REL="backup/clone-${CLONE_PROJECT}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
# STACK_ROOT points the dump at the SOURCE stack (its APP_DATABASE_URL); the
# absolute OUT path lands the file in OUR backup/.
STACK_ROOT="$SOURCE" "$SCRIPT_DIR/db-dump.sh" "$PWD/$DUMP_REL"

# -- 2. Copy the source's operator state here (1:1) --------------------------

echo "==> [2/4] Copying source env files, media and jwt keypair (1:1)"
# Anchored include-list: the v1 operator env files (NOT the tracked *.example
# templates), the media uploads and the jwt keypair. Repo files (compose,
# Taskfile, scripts) stay out — this checkout provides them. First match wins.
rsync -a \
  --exclude='.env*.example' \
  --include='/.env' \
  --include='/.env.local' \
  --include='/.env.docker.local' \
  --include='/media/***' \
  --include='/jwt/***' \
  --exclude='*' \
  "$SOURCE"/ ./

# -- 3. Retarget the copied v1 env -------------------------------------------

echo "==> [3/4] Retargeting clone env (domain, project, APP_DATABASE_URL)"
# Escape sed replacement metachars (& \ |) in the clone URL; escape regex chars
# in the source domain so dots match literally.
DBREPL=$(printf '%s' "$CLONE_DATABASE_URL" | sed 's/[&|\\]/\\&/g')
ESC_SRC=$(printf '%s' "$SRC_DOMAIN" | sed 's/[.[\*^$/]/\\&/g')

# Apply to whichever copied env files exist — v1 keeps everything in
# .env.docker.local, but a line in .env / .env.local is retargeted too. sed
# only touches matching lines, so applying to all is safe.
retarget_env() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed_inplace "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${CLONE_PROJECT}|" "$f"
  sed_inplace "s|^COMPOSE_SERVER_DOMAIN=.*|COMPOSE_SERVER_DOMAIN=${DOMAIN}|" "$f"
  sed_inplace "s|^APP_DATABASE_URL=.*|APP_DATABASE_URL=\"${DBREPL}\"|" "$f"
  # Old domain -> new everywhere else (APP_API_ENDPOINT, CORS, OIDC redirect…).
  sed_inplace "s/${ESC_SRC}/${DOMAIN}/g" "$f"
}
for f in .env .env.local .env.docker.local; do retarget_env "$f"; done

# -- 4. Restore the dump into the clone DB -----------------------------------

echo "==> [4/4] Restoring dump into the clone database"
# db-restore reads the clone's APP_DATABASE_URL (just rewritten) from this
# checkout's env.
"$SCRIPT_DIR/db-restore.sh" "$DUMP_REL"

echo
echo "===================================================="
echo "1:1 v1 clone complete in this checkout."
echo "  project           : $CLONE_PROJECT"
echo "  domain            : $DOMAIN"
echo "  database          : ${CLONE_DATABASE_URL%%\?*} (data restored)"
echo "===================================================="
echo "This is still a v1 install. Convert it to v3 next:"
echo
echo "  1. Env:      task env:migrate   # .env.docker.local -> .env.symfony.migrated"
echo "               #   review + apply the manual key renames (see UPGRADE.md), then:"
echo "               mv .env.symfony.migrated .env.symfony"
echo "               task env:init       # fill in any missing per-service env files"
echo "  2. Bring up: task up"
echo "  3. Schema:   task console -- doctrine:migrations:status   # inspect first"
echo "               #   The cloned DB carries the full 2.x migration history, which 3.0"
echo "               #   consolidated into a SINGLE migration. Running migrate / app:update"
echo "               #   now FAILS on the orphaned version rows — instead roll the version"
echo "               #   table up to the consolidated migration (rewrites bookkeeping, runs"
echo "               #   no SQL):"
echo "               task console -- doctrine:migrations:rollup --no-interaction"
echo "               #   (A fresh/empty clone DB with no 2.x history would use migrate"
echo "               #    via app:update instead — check the status output above.)"
echo "  4. Content:  task console -- app:update"
echo "               #   migrate is now a no-op; installs templates + screen layouts and"
echo "               #   flags deprecated feed sources for cleanup."
echo "See UPGRADE.md (and display-api-service/UPGRADE.md) for the full 1.x -> 3.x recipe."
