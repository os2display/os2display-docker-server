#!/usr/bin/env bash
#
# Create the clone's database on the source's EXTERNAL database server, then
# write the resulting CLONE_DATABASE_URL into clone/.env.clone so `clone.sh`
# can use it.
#
# The source DATABASE_URL is read from the first of SOURCE/.env.local,
# SOURCE/.env.docker.local (1.x layouts) or SOURCE/.env.symfony (v3 layout)
# that defines it — SOURCE comes from clone/.env.clone or the environment.
# It parses that URL for the server host/port and the application user,
# connects as a DB ADMIN (root by default — you are prompted for the
# password), and:
#   - CREATE DATABASE IF NOT EXISTS <clone-db>  (mirroring the source DB's
#     charset/collation),
#   - CREATE USER IF NOT EXISTS for the app user @'%' with the source password,
#   - GRANT ALL on the clone DB to that user.
#
# The clone reuses the source's application credentials — only the database
# (schema) name differs — so the generated CLONE_DATABASE_URL is the source
# URL with the database segment swapped. Production data is untouched: the
# clone is a separate schema on the same server.
#
# The database server is assumed EXTERNAL — reachable from this host over the
# network. The transient mariadb client runs on the default docker bridge; a
# docker-internal hostname (a bundled `host=mariadb` URL) won't resolve there.
#
# Run from this checkout's root (or via `task -t clone/Taskfile.yml create-db`):
#   clone/db-create.sh
#
# Variables:
#   SOURCE=<dir>              the source stack root (default: from clone/.env.clone)
#   CLONE_DB_NAME=<name>      clone database name (default: <source-db>_clone)
#   DB_ADMIN_USER=<user>      admin user to connect as (default: root)
#   DB_ADMIN_PASSWORD=<pw>    admin password (skips the prompt; for CI)
#
# Requires: docker, a DATABASE_URL in one of the SOURCE env files above.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# shellcheck source=clone/lib-db-url.sh
. "$SCRIPT_DIR/lib-db-url.sh"

# SOURCE from the environment wins; clone/.env.clone is the fallback. Relative
# paths are resolved from this stack root (we cd'd above).
if [ -z "${SOURCE:-}" ] && [ -f "$SCRIPT_DIR/.env.clone" ]; then
  SOURCE=$(grep -E '^SOURCE=' "$SCRIPT_DIR/.env.clone" | head -1 | cut -d= -f2-)
fi
: "${SOURCE:?Set SOURCE in clone/.env.clone (or the environment) — the stack root to clone}"
SOURCE="$(cd "$SOURCE" 2>/dev/null && pwd)" || {
  echo "Error: SOURCE directory not found." >&2
  exit 1
}
# Find the source DATABASE_URL. 1.x installs keep it in .env.local or
# .env.docker.local; the v3 layout in .env.symfony. First file that defines
# it wins — so this works whether the source is the old production layout or
# an already-migrated v3 stack.
SRC_ENV_FILE=""
for f in .env.local .env.docker.local .env.symfony; do
  if [ -f "$SOURCE/$f" ] && grep -qE '^DATABASE_URL=' "$SOURCE/$f"; then
    SRC_ENV_FILE="$SOURCE/$f"
    break
  fi
done
[ -n "$SRC_ENV_FILE" ] || {
  echo "Error: no DATABASE_URL found in $SOURCE/.env.local, .env.docker.local" >&2
  echo "       or .env.symfony — is SOURCE a configured stack root?" >&2
  exit 1
}
echo "Source DATABASE_URL from ${SRC_ENV_FILE}"

SRC_URL=$(read_database_url "$SRC_ENV_FILE")
db_url_parse "$SRC_URL" # sets DB_USER/DB_PASS/DB_HOST/DB_PORT/DB_NAME (query stripped)

# External-server assumption: the host must be reachable from this machine —
# a docker-internal name (bundled DB) won't resolve from the default bridge.
case "$DB_HOST" in
  *.*) ;;
  *)
    echo "Warning: source DB host '$DB_HOST' looks like a docker-internal name," >&2
    echo "         not an external server — this script assumes an EXTERNAL" >&2
    echo "         database reachable from this host. Continuing anyway." >&2
    ;;
esac

CLONE_DB_NAME="${CLONE_DB_NAME:-${DB_NAME}_clone}"
ADMIN_USER="${DB_ADMIN_USER:-root}"

# Identifiers go into backtick-quoted SQL; refuse a backtick in the name rather
# than try to escape our way out of an injection.
case "$CLONE_DB_NAME" in
  *'`'*)
    echo "Error: CLONE_DB_NAME must not contain a backtick." >&2
    exit 1
    ;;
esac
if [ "$CLONE_DB_NAME" = "$DB_NAME" ]; then
  echo "Error: clone DB name '$CLONE_DB_NAME' equals the source database." >&2
  echo "       Set CLONE_DB_NAME=… to something distinct." >&2
  exit 1
fi

# Client tag from THIS checkout's compose pin — the server is external, so
# there's no local container to match; any recent mariadb client will do.
# No --network: the default bridge has egress to the external host.
TAG=$(mariadb_tag)

# Build the clone URL: source URL with the database segment swapped, query
# (serverVersion=…) preserved verbatim, credentials untouched.
SRC_PREFIX="${SRC_URL%%\?*}"           # mysql://user:pass@host:port/dbname
SRC_QUERY=""
case "$SRC_URL" in *\?*) SRC_QUERY="?${SRC_URL#*\?}" ;; esac
SRC_BASE="${SRC_PREFIX%/*}"            # mysql://user:pass@host:port
CLONE_DATABASE_URL="${SRC_BASE}/${CLONE_DB_NAME}${SRC_QUERY}"

# Prompt for the admin password (unless provided via env). Read from the
# terminal so it works even when the task runner doesn't wire up stdin.
if [ -n "${DB_ADMIN_PASSWORD:-}" ]; then
  ADMIN_PW="$DB_ADMIN_PASSWORD"
elif [ -r /dev/tty ]; then
  printf "Password for DB admin user '%s'@%s: " "$ADMIN_USER" "$DB_HOST" >&2
  read -rs ADMIN_PW </dev/tty
  printf '\n' >&2
else
  echo "Error: no terminal available for the password prompt." >&2
  echo "       Set DB_ADMIN_PASSWORD=… to run non-interactively." >&2
  exit 1
fi
[ -n "$ADMIN_PW" ] || {
  echo "Error: empty admin password." >&2
  exit 1
}

echo "Creating database '${CLONE_DB_NAME}' on ${DB_HOST}:${DB_PORT}..."

# Mirror the source database's default charset/collation onto the clone, so
# any post-restore migration that creates a table without an explicit charset
# matches the source. -N -B → bare, tab-separated output.
read -r SRC_CS SRC_COLL < <(
  docker run -i --rm -e MYSQL_PWD="$ADMIN_PW" "mariadb:${TAG}" \
    mariadb --host="$DB_HOST" --port="$DB_PORT" --user="$ADMIN_USER" -N -B \
    -e "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';"
) || {
  echo "Error: could not query the source database charset (check admin credentials/host)." >&2
  exit 1
}

CREATE_SQL="CREATE DATABASE IF NOT EXISTS \`${CLONE_DB_NAME}\`"
[ -n "${SRC_CS:-}" ] && CREATE_SQL="${CREATE_SQL} CHARACTER SET ${SRC_CS}"
[ -n "${SRC_COLL:-}" ] && CREATE_SQL="${CREATE_SQL} COLLATE ${SRC_COLL}"

# Escape the app password for a single-quoted SQL string literal: double any
# backslash, then double any single quote (MariaDB default sql_mode).
ESC_APP_PW=$(printf '%s' "$DB_PASS" | sed -e 's/\\/\\\\/g' -e "s/'/''/g")

# CREATE USER IF NOT EXISTS makes the clone connectable as <user>@'%' even when
# the source granted the user only on a specific host. If the '%' account
# already exists it's a no-op (the password is not changed).
SQL="${CREATE_SQL};
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${ESC_APP_PW}';
GRANT ALL PRIVILEGES ON \`${CLONE_DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;"

printf '%s\n' "$SQL" | docker run -i --rm -e MYSQL_PWD="$ADMIN_PW" "mariadb:${TAG}" \
  mariadb --host="$DB_HOST" --port="$DB_PORT" --user="$ADMIN_USER"

# Write CLONE_DATABASE_URL into clone/.env.clone so the clone task picks it up.
sed_inplace() {
  sed -i.bak "$1" "$2"
  rm -f "$2.bak"
}
ENVCLONE="$SCRIPT_DIR/.env.clone"
[ -f "$ENVCLONE" ] || cp "$SCRIPT_DIR/.env.clone.example" "$ENVCLONE"
REPL=$(printf '%s' "$CLONE_DATABASE_URL" | sed 's/[&|\\]/\\&/g')
if grep -qE '^CLONE_DATABASE_URL=' "$ENVCLONE"; then
  sed_inplace "s|^CLONE_DATABASE_URL=.*|CLONE_DATABASE_URL=${REPL}|" "$ENVCLONE"
else
  printf 'CLONE_DATABASE_URL=%s\n' "$CLONE_DATABASE_URL" >>"$ENVCLONE"
fi

echo
echo "Database ready. Wrote CLONE_DATABASE_URL into clone/.env.clone:"
echo "  ${CLONE_DATABASE_URL}"
echo "Next: set DOMAIN in clone/.env.clone (if not already), then run:"
echo "  task -t clone/Taskfile.yml clone"
